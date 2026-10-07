import { ApiError } from "../../common/errors/api-error.js";
import type {
  DatabaseConnection,
  DatabaseQueryExecutor,
  DatabaseRow,
} from "../../database/types.js";

interface PreviewQueue {
  sendProcessJob(jobId: string, delaySeconds?: number): Promise<void>;
}

export type ExactPreviewJob = Record<string, unknown>;

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
    const job = await this.withIdentity(requestedBy, async (executor) => {
      const result = await executor.query(
        `SELECT public.start_championship_bracket_preview_job(
           $1::uuid,
           $2::jsonb
         ) AS job`,
        [championshipId, JSON.stringify(payload)],
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
    const stale = await this.database.query(
      `UPDATE championship_bracket_preview_private.jobs
          SET heartbeat_at=now(), updated_at=now()
        WHERE id IN (
          SELECT id
          FROM championship_bracket_preview_private.jobs
          WHERE status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING')
            AND (heartbeat_at IS NULL OR heartbeat_at < now() - interval '90 seconds')
            AND expires_at > now()
          ORDER BY created_at
          LIMIT 20
          FOR UPDATE SKIP LOCKED
        )
        RETURNING id::text AS id`,
    );

    let published = 0;
    for (const row of stale.rows) {
      if (typeof row.id !== "string") continue;
      await this.queue.sendProcessJob(row.id);
      published += 1;
    }

    await this.database.query(
      `DELETE FROM championship_bracket_preview_private.jobs
        WHERE expires_at < now()
          AND status IN ('COMPLETED','FAILED','CANCELLED','CONSUMED')`,
    );

    return published;
  }
}

export function exactPreviewJobStatus(job: ExactPreviewJob): string {
  return jobStatus(job);
}
