import { ApiError } from "../../common/errors/api-error.js";
import type { DatabaseConnection, DatabaseQueryExecutor } from "../../database/types.js";

interface PreviewQueue {
  sendProcessJob(jobId: string, delaySeconds?: number): Promise<void>;
}

export type ExactPreviewJob = Record<string, unknown>;

const MAX_PREVIEW_PAYLOAD_BYTES = 2 * 1024 * 1024;
const PREVIEW_CLEANUP_BATCH_SIZE = 25;

function asRecord(value: unknown): Record<string, unknown> | null {
  return value != null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function requireJob(value: unknown): ExactPreviewJob {
  const job = asRecord(value);
  if (!job || typeof job.job_id !== "string") {
    throw new Error("Resposta inválida do motor de prévia exata.");
  }
  return job;
}

function jobStatus(job: ExactPreviewJob): string {
  return typeof job.status === "string" ? job.status : "";
}

function jobChampionshipId(job: ExactPreviewJob): string | null {
  return typeof job.championship_id === "string" ? job.championship_id : null;
}

function activeStatus(status: string): boolean {
  return ["QUEUED", "INITIALIZING", "SCHEDULING", "FINALIZING"].includes(status);
}

export class BracketPreviewService {
  constructor(
    private readonly database: DatabaseConnection,
    private readonly queue: PreviewQueue,
  ) {}

  private async withIdentity<T>(
    userId: string,
    work: (executor: DatabaseQueryExecutor) => Promise<T>,
  ): Promise<T> {
    return this.database.transaction(async (executor) => {
      await executor.query("SELECT set_config('laje.request_user_id', $1, true)", [userId]);
      return work(executor);
    });
  }

  async start(
    championshipId: string,
    payload: Record<string, unknown>,
    requestedBy: string,
  ): Promise<ExactPreviewJob> {
    const serializedPayload = JSON.stringify(payload);
    if (Buffer.byteLength(serializedPayload, "utf8") > MAX_PREVIEW_PAYLOAD_BYTES) {
      throw new ApiError(
        413,
        "PREVIEW_PAYLOAD_TOO_LARGE",
        "A configuração da prévia excede o limite seguro de 2 MiB.",
      );
    }

    const job = await this.withIdentity(requestedBy, async (executor) => {
      const result = await executor.query(
        `SELECT public.start_championship_bracket_preview_job(
           $1::uuid,
           $2::jsonb
         ) AS job`,
        [championshipId, serializedPayload],
      );
      return requireJob(result.rows[0]?.job);
    });

    if (!activeStatus(jobStatus(job))) {
      return job;
    }

    const jobId = String(job.job_id);
    try {
      await this.queue.sendProcessJob(jobId);
    } catch (error) {
      const message =
        error instanceof Error ? error.message : "Não foi possível publicar o job na fila SQS.";
      await this.database.query(
        `UPDATE championship_bracket_preview_private.jobs
            SET status='FAILED',
                stage='Falha ao enfileirar',
                error_message=$2,
                completed_at=now(),
                heartbeat_at=now(),
                updated_at=now()
          WHERE id=$1::uuid
            AND status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING')`,
        [jobId, message],
      );
      throw new ApiError(
        503,
        "PREVIEW_QUEUE_UNAVAILABLE",
        "Não foi possível enfileirar a prévia exata.",
      );
    }

    return job;
  }

  async get(jobId: string, requestedBy: string): Promise<ExactPreviewJob> {
    return this.withIdentity(requestedBy, async (executor) => {
      const result = await executor.query(
        "SELECT public.get_championship_bracket_preview_job_status($1::uuid) AS job",
        [jobId],
      );
      return requireJob(result.rows[0]?.job);
    });
  }

  async getForChampionship(
    jobId: string,
    championshipId: string,
    requestedBy: string,
  ): Promise<ExactPreviewJob> {
    const job = await this.get(jobId, requestedBy);
    if (jobChampionshipId(job) !== championshipId) {
      throw new ApiError(404, "PREVIEW_JOB_NOT_FOUND", "Prévia não encontrada.");
    }
    return job;
  }

  async getDay(
    jobId: string,
    date: string,
    requestedBy: string,
  ): Promise<Record<string, unknown> | null> {
    return this.withIdentity(requestedBy, async (executor) => {
      const result = await executor.query(
        "SELECT public.get_championship_bracket_preview_job_day($1::uuid, $2::date) AS day",
        [jobId, date],
      );
      const value = result.rows[0]?.day;
      return value == null ? null : asRecord(value);
    });
  }

  async cancel(jobId: string, requestedBy: string): Promise<ExactPreviewJob> {
    return this.withIdentity(requestedBy, async (executor) => {
      const result = await executor.query(
        "SELECT public.cancel_championship_bracket_preview_job($1::uuid) AS job",
        [jobId],
      );
      return requireJob(result.rows[0]?.job);
    });
  }

  async createBracket(
    jobId: string,
    championshipId: string,
    payload: Record<string, unknown>,
    requestedBy: string,
  ): Promise<string> {
    return this.withIdentity(requestedBy, async (executor) => {
      const result = await executor.query(
        `SELECT public.create_championship_bracket_from_preview_job(
           $1::uuid,
           $2::uuid,
           $3::jsonb
         )::text AS edition_id`,
        [jobId, championshipId, JSON.stringify(payload)],
      );
      const editionId = result.rows[0]?.edition_id;
      if (typeof editionId !== "string" || !editionId) {
        throw new Error("O motor exato não retornou a edição criada.");
      }
      return editionId;
    });
  }

  async heartbeat(jobId: string): Promise<void> {
    await this.database.query(
      `UPDATE championship_bracket_preview_private.jobs
          SET heartbeat_at=now(), updated_at=now()
        WHERE id=$1::uuid
          AND status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING')`,
      [jobId],
    );
  }

  async process(jobId: string): Promise<{ continue: boolean; delaySeconds: number }> {
    const result = await this.database.query(
      "SELECT championship_bracket_preview_private.process_job($1::uuid) AS result",
      [jobId],
    );
    const processResult = asRecord(result.rows[0]?.result) ?? {};
    const shouldContinue = processResult.continue === true;
    const rawDelay = Number(processResult.delay ?? 0);
    const delaySeconds = Number.isFinite(rawDelay)
      ? Math.max(0, Math.min(900, Math.floor(rawDelay)))
      : 0;

    if (shouldContinue) {
      await this.queue.sendProcessJob(jobId, delaySeconds);
    }

    return { continue: shouldContinue, delaySeconds };
  }

  async recoverAndCleanup(): Promise<number> {
    const cleanup = await this.database.query(
      `WITH removable AS (
         SELECT id
         FROM championship_bracket_preview_private.jobs
         WHERE (
             status = 'CONSUMED'
             AND consumed_at IS NOT NULL
             AND consumed_at < now() - interval '1 hour'
           )
           OR (
             status IN ('COMPLETED','FAILED','CANCELLED')
             AND expires_at < now()
           )
         ORDER BY COALESCE(consumed_at, completed_at, expires_at, created_at)
         LIMIT ${PREVIEW_CLEANUP_BATCH_SIZE}
         FOR UPDATE SKIP LOCKED
       )
       DELETE FROM championship_bracket_preview_private.jobs AS jobs
       USING removable
       WHERE jobs.id = removable.id
       RETURNING jobs.id`,
    );

    if (cleanup.rows.length > 0) {
      console.log(`Bracket preview cleanup removed ${cleanup.rows.length} terminal job(s).`);
    }

    // SQS already provides durable redelivery after the visibility timeout.
    // Maintenance must not publish duplicate PROCESS_PREVIEW messages.
    return 0;
  }
}

export function exactPreviewJobStatus(job: ExactPreviewJob): string {
  return jobStatus(job);
}
