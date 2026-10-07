import { createHash } from "node:crypto";

import { ApiError } from "../../common/errors/api-error.js";
import type {
  DatabaseConnection,
  DatabaseQueryExecutor,
  DatabaseRow,
} from "../../database/types.js";

const ALGORITHM_VERSION = "aws-structural-v1";

type PreviewStatus =
  | "QUEUED"
  | "INITIALIZING"
  | "SCHEDULING"
  | "FINALIZING"
  | "COMPLETED"
  | "FAILED"
  | "CANCELLED"
  | "CONSUMED";

interface PreviewQueue {
  sendProcessJob(jobId: string, delaySeconds?: number): Promise<void>;
}

interface PreviewJobRow extends DatabaseRow {
  jobId: string;
  championshipId: string;
  seasonYear: number;
  status: PreviewStatus;
  stage: string;
  currentDate: string | null;
  progressPercentage: number;
  processedSlots: number;
  totalSlots: number;
  attemptCount: number;
  errorMessage: string | null;
  summary: Record<string, unknown> | null;
  diagnostics: Array<Record<string, unknown>>;
  payload: Record<string, unknown>;
  payloadSignature: string;
  dependencySignature: string;
  algorithmVersion: string;
  generationSignature: string | null;
  result: Record<string, unknown> | null;
  events: Array<Record<string, unknown>>;
  createdAt: string;
  startedAt: string | null;
  completedAt: string | null;
  expiresAt: string;
}

interface StructuralSlot {
  slot_key: string;
  date: string;
  start_time: string;
  end_time: string;
  duration_minutes: number;
  location_key: string;
  location_name: string;
  court_key: string;
  court_name: string;
  competition_key: string;
  sport_id: string;
  naipe: string;
  division: string | null;
  phase: string;
  phase_slot_number: number;
  match_kind: string;
  manual_final: boolean;
}

interface Competition {
  sport_id: string;
  naipe: string;
  division: string | null;
  groups: Array<{ group_number: number; team_ids: string[] }>;
}

interface ScheduledMatchDescriptor {
  competitionKey: string;
  sportId: string;
  naipe: string;
  division: string | null;
  phase: string;
  matchKind: string;
  groupNumber: number | null;
  roundNumber: number | null;
  homeTeamId: string | null;
  awayTeamId: string | null;
  manualFinal: boolean;
}

const JOB_SELECT = `
SELECT id AS "jobId", championship_id AS "championshipId", season_year AS "seasonYear",
       status, stage, current_preview_date::text AS "currentDate",
       progress_percentage::float8 AS "progressPercentage",
       processed_slots AS "processedSlots", total_slots AS "totalSlots",
       attempt_count AS "attemptCount", error_message AS "errorMessage",
       summary, diagnostics, payload, payload_signature AS "payloadSignature",
       dependency_signature AS "dependencySignature", algorithm_version AS "algorithmVersion",
       generation_signature AS "generationSignature", result, events,
       created_at::text AS "createdAt", started_at::text AS "startedAt",
       completed_at::text AS "completedAt", expires_at::text AS "expiresAt"
  FROM public.championship_bracket_preview_jobs
`;

function record(value: unknown): Record<string, unknown> {
  return value != null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function optionalText(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function numberValue(value: unknown, fallback = 0): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function stableValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stableValue);
  if (value != null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, nested]) => [key, stableValue(nested)]),
    );
  }
  return value;
}

function signature(value: unknown): string {
  return createHash("sha256")
    .update(JSON.stringify(stableValue(value)), "utf8")
    .digest("hex");
}

function competitionKey(competition: Competition): string {
  return [competition.sport_id, competition.naipe, competition.division ?? "WITHOUT_DIVISION"].join(
    "::",
  );
}

function parseCompetitions(payload: Record<string, unknown>): Competition[] {
  return array(payload.competitions).map((rawCompetition) => {
    const item = record(rawCompetition);
    return {
      sport_id: text(item.sport_id),
      naipe: text(item.naipe),
      division: optionalText(item.division),
      groups: array(item.groups).map((rawGroup) => {
        const group = record(rawGroup);
        return {
          group_number: numberValue(group.group_number),
          team_ids: array(group.team_ids).map(text).filter(Boolean),
        };
      }),
    };
  });
}

function parseStructuralSlots(payload: Record<string, unknown>): StructuralSlot[] {
  return array(payload.structural_schedule_slots).map((rawSlot) => {
    const slot = record(rawSlot);
    return {
      slot_key: text(slot.slot_key),
      date: text(slot.date),
      start_time: text(slot.start_time),
      end_time: text(slot.end_time),
      duration_minutes: numberValue(slot.duration_minutes),
      location_key: text(slot.location_key),
      location_name: text(slot.location_name),
      court_key: text(slot.court_key),
      court_name: text(slot.court_name),
      competition_key: text(slot.competition_key),
      sport_id: text(slot.sport_id),
      naipe: text(slot.naipe),
      division: optionalText(slot.division),
      phase: text(slot.phase),
      phase_slot_number: numberValue(slot.phase_slot_number),
      match_kind: text(slot.match_kind),
      manual_final: slot.manual_final === true,
    };
  });
}

function generateGroupMatches(competition: Competition): ScheduledMatchDescriptor[] {
  const descriptors: ScheduledMatchDescriptor[] = [];
  for (const group of competition.groups) {
    let round = 1;
    for (let homeIndex = 0; homeIndex < group.team_ids.length - 1; homeIndex += 1) {
      for (let awayIndex = homeIndex + 1; awayIndex < group.team_ids.length; awayIndex += 1) {
        descriptors.push({
          competitionKey: competitionKey(competition),
          sportId: competition.sport_id,
          naipe: competition.naipe,
          division: competition.division,
          phase: "GROUP_STAGE",
          matchKind: "GROUP_STAGE",
          groupNumber: group.group_number,
          roundNumber: round,
          homeTeamId: group.team_ids[homeIndex] ?? null,
          awayTeamId: group.team_ids[awayIndex] ?? null,
          manualFinal: false,
        });
        round += 1;
      }
    }
  }
  return descriptors;
}

function phaseLabel(phase: string): string {
  const labels: Record<string, string> = {
    GROUP_STAGE: "Fase de grupos",
    ROUND_OF_32: "16 avos de final",
    ROUND_OF_16: "Oitavas de final",
    QUARTERFINAL: "Quartas de final",
    SEMIFINAL: "Semifinal",
    FINAL: "Final",
  };
  return labels[phase] ?? phase;
}

function minutesBetween(startTime: string, endTime: string): number {
  const parse = (value: string) => {
    const parts = value.split(":");
    const hours = Number(parts[0] ?? "");
    const minutes = Number(parts[1] ?? "");
    return Number.isFinite(hours) && Number.isFinite(minutes) ? hours * 60 + minutes : 0;
  };
  return Math.max(0, parse(endTime) - parse(startTime));
}

function asJob(row: DatabaseRow | undefined): PreviewJobRow | null {
  if (!row) return null;
  return row as PreviewJobRow;
}

async function buildDependencySignature(
  executor: DatabaseQueryExecutor,
  championshipId: string,
): Promise<string> {
  const result = await executor.query(
    `SELECT jsonb_build_object(
       'championship', jsonb_build_object(
         'id', c.id,
         'status', c.status,
         'current_season_year', c.current_season_year,
         'default_location', c.default_location
       ),
       'teams_count', (SELECT count(*) FROM public.teams WHERE is_active),
       'sports_count', (SELECT count(*) FROM public.championship_sports WHERE championship_id = c.id)
     ) AS dependency
     FROM public.championships c
     WHERE c.id = $1`,
    [championshipId],
  );
  if (!result.rows[0]) {
    throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
  }
  return signature(result.rows[0].dependency);
}

async function loadNames(
  executor: DatabaseQueryExecutor,
  payload: Record<string, unknown>,
): Promise<{ teamNames: Map<string, string>; sportNames: Map<string, string> }> {
  const competitions = parseCompetitions(payload);
  const teamIds = [
    ...new Set(
      competitions.flatMap((competition) => competition.groups.flatMap((group) => group.team_ids)),
    ),
  ];
  const sportIds = [
    ...new Set(competitions.map((competition) => competition.sport_id).filter(Boolean)),
  ];

  const teamNames = new Map<string, string>();
  const sportNames = new Map<string, string>();

  if (teamIds.length > 0) {
    const teams = await executor.query(
      "SELECT id, name FROM public.teams WHERE id = ANY($1::uuid[])",
      [teamIds],
    );
    teams.rows.forEach((team) => teamNames.set(String(team.id), String(team.name)));
  }

  if (sportIds.length > 0) {
    const sports = await executor.query(
      "SELECT id, name FROM public.sports WHERE id = ANY($1::uuid[])",
      [sportIds],
    );
    sports.rows.forEach((sport) => sportNames.set(String(sport.id), String(sport.name)));
  }

  return { teamNames, sportNames };
}

export function buildBracketPreviewResult(
  payload: Record<string, unknown>,
  teamNames: Map<string, string>,
  sportNames: Map<string, string>,
) {
  const competitions = parseCompetitions(payload);
  const slots = parseStructuralSlots(payload).sort((left, right) =>
    [left.date, left.start_time, left.location_name, left.court_name, left.phase_slot_number]
      .join("|")
      .localeCompare(
        [
          right.date,
          right.start_time,
          right.location_name,
          right.court_name,
          right.phase_slot_number,
        ].join("|"),
      ),
  );
  if (slots.length === 0) {
    throw new ApiError(
      422,
      "PREVIEW_STRUCTURAL_SLOTS_REQUIRED",
      "A prévia AWS exige os slots estruturais calculados pelo assistente de chaveamento.",
    );
  }

  const matchQueues = new Map<string, ScheduledMatchDescriptor[]>();
  for (const competition of competitions) {
    matchQueues.set(competitionKey(competition), generateGroupMatches(competition));
  }

  const diagnostics: Array<Record<string, unknown>> = [];
  const matchCursor = new Map<string, number>();
  const days = new Map<string, Record<string, unknown>>();
  let matchNumber = 1;
  let groupStageMatches = 0;
  let knockoutMatches = 0;
  let occupiedMinutes = 0;

  const scheduleDays = new Map(
    array(payload.schedule_days).map((rawDay) => {
      const day = record(rawDay);
      return [text(day.date), day] as const;
    }),
  );

  for (const slot of slots) {
    const dayConfig = scheduleDays.get(slot.date) ?? {};
    let day = days.get(slot.date);
    if (!day) {
      const breakStart = optionalText(dayConfig.break_start_time);
      const breakEnd = optionalText(dayConfig.break_end_time);
      day = {
        date: slot.date,
        start_time: text(dayConfig.start_time) || slot.start_time,
        end_time: text(dayConfig.end_time) || slot.end_time,
        occupied_minutes: 0,
        available_minutes: 0,
        utilization_percentage: 0,
        free_windows: 0,
        breaks: breakStart && breakEnd ? [{ start_time: breakStart, end_time: breakEnd }] : [],
        locations: [],
      };
      days.set(slot.date, day);
    }

    const locations = day.locations as Array<Record<string, unknown>>;
    let location = locations.find((item) => item.location_key === slot.location_key);
    if (!location) {
      location = {
        location_key: slot.location_key,
        location_name: slot.location_name,
        courts: [],
      };
      locations.push(location);
    }

    const courts = location.courts as Array<Record<string, unknown>>;
    let court = courts.find((item) => item.court_key === slot.court_key);
    if (!court) {
      court = {
        court_key: slot.court_key,
        court_name: slot.court_name,
        occupied_minutes: 0,
        available_minutes: 0,
        utilization_percentage: 0,
        free_windows: 0,
        entries: [],
      };
      courts.push(court);
    }

    let descriptor: ScheduledMatchDescriptor | null;
    if (slot.phase === "GROUP_STAGE") {
      const queue = matchQueues.get(slot.competition_key) ?? [];
      const cursor = matchCursor.get(slot.competition_key) ?? 0;
      descriptor = queue[cursor] ?? null;
      matchCursor.set(slot.competition_key, cursor + 1);
      if (descriptor) groupStageMatches += 1;
    } else {
      descriptor = {
        competitionKey: slot.competition_key,
        sportId: slot.sport_id,
        naipe: slot.naipe,
        division: slot.division,
        phase: slot.phase,
        matchKind: slot.match_kind || "KNOCKOUT",
        groupNumber: null,
        roundNumber: slot.phase_slot_number,
        homeTeamId: null,
        awayTeamId: null,
        manualFinal: slot.manual_final,
      };
      knockoutMatches += 1;
    }

    if (!descriptor) {
      diagnostics.push({
        code: "UNRESOLVED_STRUCTURAL_SLOT",
        severity: "ERROR",
        message: "Não foi possível associar o slot estrutural a uma partida da competição.",
        reason_code: "GROUP_MATCH_SLOT_OVERFLOW",
        match_id: null,
        date: slot.date,
        location_name: slot.location_name,
        court_name: slot.court_name,
        sport_id: slot.sport_id,
        sport_name: sportNames.get(slot.sport_id) ?? null,
        naipe: slot.naipe,
        division: slot.division,
        phase: slot.phase,
        group_number: null,
        round_number: null,
      });
      continue;
    }

    const duration = slot.duration_minutes || minutesBetween(slot.start_time, slot.end_time);
    occupiedMinutes += duration;
    day.occupied_minutes = numberValue(day.occupied_minutes) + duration;
    court.occupied_minutes = numberValue(court.occupied_minutes) + duration;

    (court.entries as Array<Record<string, unknown>>).push({
      type: "MATCH",
      start_time: slot.start_time,
      end_time: slot.end_time,
      duration_minutes: duration,
      match_kind: descriptor.matchKind,
      match_number: matchNumber,
      sport_id: descriptor.sportId,
      sport_name: sportNames.get(descriptor.sportId) ?? "Modalidade",
      naipe: descriptor.naipe,
      division: descriptor.division,
      phase: descriptor.phase,
      phase_label: phaseLabel(descriptor.phase),
      group_number: descriptor.groupNumber,
      round_number: descriptor.roundNumber,
      home_team_id: descriptor.homeTeamId,
      home_team_name: descriptor.homeTeamId
        ? (teamNames.get(descriptor.homeTeamId) ?? "Atlética")
        : null,
      away_team_id: descriptor.awayTeamId,
      away_team_name: descriptor.awayTeamId
        ? (teamNames.get(descriptor.awayTeamId) ?? "Atlética")
        : null,
      home_source_match_number: null,
      away_source_match_number: null,
      projected: descriptor.phase !== "GROUP_STAGE",
      manual_final: descriptor.manualFinal,
      reason_code: null,
      reason: null,
    });
    matchNumber += 1;
  }

  for (const competition of competitions) {
    const expected = matchQueues.get(competitionKey(competition))?.length ?? 0;
    const assigned = matchCursor.get(competitionKey(competition)) ?? 0;
    if (assigned < expected) {
      diagnostics.push({
        code: "MISSING_GROUP_STAGE_SLOTS",
        severity: "ERROR",
        message: `A configuração estrutural possui ${expected - assigned} jogo(s) de grupos sem slot.`,
        reason_code: "INSUFFICIENT_STRUCTURAL_CAPACITY",
        match_id: null,
        date: null,
        location_name: null,
        court_name: null,
        sport_id: competition.sport_id,
        sport_name: sportNames.get(competition.sport_id) ?? null,
        naipe: competition.naipe,
        division: competition.division,
        phase: "GROUP_STAGE",
        group_number: null,
        round_number: null,
      });
    }
  }

  for (const day of days.values()) {
    const dayStart = text(day.start_time);
    const dayEnd = text(day.end_time);
    const baseMinutes = minutesBetween(dayStart, dayEnd);
    const breaks = day.breaks as Array<Record<string, unknown>>;
    const breakMinutes = breaks.reduce(
      (sum, item) => sum + minutesBetween(text(item.start_time), text(item.end_time)),
      0,
    );
    const courts = (day.locations as Array<Record<string, unknown>>).flatMap(
      (location) => location.courts as Array<Record<string, unknown>>,
    );
    const totalAvailable = Math.max(0, baseMinutes - breakMinutes) * Math.max(1, courts.length);
    day.available_minutes = totalAvailable;
    day.utilization_percentage =
      totalAvailable > 0
        ? Math.min(
            100,
            Math.round((numberValue(day.occupied_minutes) / totalAvailable) * 10000) / 100,
          )
        : 0;
    day.free_windows = Math.max(
      0,
      courts.length - courts.filter((court) => numberValue(court.occupied_minutes) > 0).length,
    );

    for (const court of courts) {
      const courtAvailable = Math.max(0, baseMinutes - breakMinutes);
      court.available_minutes = courtAvailable;
      court.utilization_percentage =
        courtAvailable > 0
          ? Math.min(
              100,
              Math.round((numberValue(court.occupied_minutes) / courtAvailable) * 10000) / 100,
            )
          : 0;
      court.free_windows = numberValue(court.occupied_minutes) < courtAvailable ? 1 : 0;
    }
  }

  const dayList = [...days.values()].sort((left, right) =>
    String(left.date).localeCompare(String(right.date)),
  );
  const totalMatches = groupStageMatches + knockoutMatches;
  const availableMinutes = dayList.reduce(
    (sum, day) => sum + numberValue(day.available_minutes),
    0,
  );
  const summary = {
    total_matches: totalMatches,
    group_stage_matches: groupStageMatches,
    knockout_matches: knockoutMatches,
    scheduled_matches: totalMatches,
    occupied_minutes: occupiedMinutes,
    available_minutes: availableMinutes,
    utilization_percentage:
      availableMinutes > 0
        ? Math.min(100, Math.round((occupiedMinutes / availableMinutes) * 10000) / 100)
        : 0,
    free_windows: dayList.reduce((sum, day) => sum + numberValue(day.free_windows), 0),
    conflict_count: diagnostics.filter((item) => item.severity === "ERROR").length,
    warning_count: diagnostics.filter((item) => item.severity === "WARNING").length,
    games_by_day: dayList.map((day) => ({
      date: day.date,
      matches: (day.locations as Array<Record<string, unknown>>)
        .flatMap((location) => location.courts as Array<Record<string, unknown>>)
        .reduce((sum, court) => sum + (court.entries as Array<Record<string, unknown>>).length, 0),
    })),
  };

  return {
    ok: diagnostics.every((item) => item.severity !== "ERROR"),
    message: diagnostics.some((item) => item.severity === "ERROR")
      ? "A prévia estrutural possui pendências impeditivas."
      : null,
    server_payload_signature: signature(payload),
    generation_signature: "",
    match_numbering_mode: text(payload.match_numbering_mode) || "COURT",
    summary,
    days: dayList,
    diagnostics,
  };
}

export class BracketPreviewService {
  constructor(
    private readonly database: DatabaseConnection,
    private readonly queue: PreviewQueue,
  ) {}

  async start(
    championshipId: string,
    payload: Record<string, unknown>,
    requestedBy: string | null,
  ): Promise<PreviewJobRow> {
    if (parseStructuralSlots(payload).length === 0) {
      throw new ApiError(
        422,
        "PREVIEW_STRUCTURAL_SLOTS_REQUIRED",
        "Calcule a agenda estrutural antes de iniciar a prévia exata.",
      );
    }

    const championship = await this.database.query(
      `SELECT id, current_season_year AS "seasonYear", status
         FROM public.championships WHERE id = $1`,
      [championshipId],
    );
    const row = championship.rows[0];
    if (!row) throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
    if (!["UPCOMING", "PLANNING"].includes(String(row.status))) {
      throw new ApiError(
        409,
        "CHAMPIONSHIP_PREVIEW_NOT_ALLOWED",
        "A prévia só pode ser gerada durante o planejamento do campeonato.",
      );
    }

    const seasonYear = Number(row.seasonYear);
    const payloadSignature = signature(payload);
    const dependencySignature = await buildDependencySignature(this.database, championshipId);

    const existing = await this.database.query(
      `${JOB_SELECT}
       WHERE championship_id = $1
         AND season_year = $2
         AND requested_by IS NOT DISTINCT FROM $3::uuid
         AND payload_signature = $4
         AND dependency_signature = $5
         AND algorithm_version = $6
         AND expires_at > now()
         AND status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING','COMPLETED')
       ORDER BY created_at DESC
       LIMIT 1`,
      [
        championshipId,
        seasonYear,
        requestedBy,
        payloadSignature,
        dependencySignature,
        ALGORITHM_VERSION,
      ],
    );
    const reusable = asJob(existing.rows[0]);
    if (reusable) return reusable;

    await this.database.query(
      `UPDATE public.championship_bracket_preview_jobs
          SET status = 'CANCELLED', stage = 'Cancelado', completed_at = now(), updated_at = now()
        WHERE championship_id = $1
          AND requested_by IS NOT DISTINCT FROM $2::uuid
          AND status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING')`,
      [championshipId, requestedBy],
    );

    const totalSlots = parseStructuralSlots(payload).length;
    const created = await this.database.query(
      `INSERT INTO public.championship_bracket_preview_jobs
        (championship_id, season_year, requested_by, payload, payload_signature,
         dependency_signature, algorithm_version, total_slots, heartbeat_at)
       VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7, $8, now())
       RETURNING id AS "jobId", championship_id AS "championshipId", season_year AS "seasonYear",
         status, stage, current_preview_date::text AS "currentDate",
         progress_percentage::float8 AS "progressPercentage", processed_slots AS "processedSlots",
         total_slots AS "totalSlots", attempt_count AS "attemptCount", error_message AS "errorMessage",
         summary, diagnostics, payload, payload_signature AS "payloadSignature",
         dependency_signature AS "dependencySignature", algorithm_version AS "algorithmVersion",
         generation_signature AS "generationSignature", result, events,
         created_at::text AS "createdAt", started_at::text AS "startedAt",
         completed_at::text AS "completedAt", expires_at::text AS "expiresAt"`,
      [
        championshipId,
        seasonYear,
        requestedBy,
        JSON.stringify(payload),
        payloadSignature,
        dependencySignature,
        ALGORITHM_VERSION,
        totalSlots,
      ],
    );
    const job = asJob(created.rows[0]);
    if (!job) throw new Error("Failed to create bracket preview job.");

    try {
      await this.queue.sendProcessJob(job.jobId);
    } catch (error) {
      await this.database.query(
        `UPDATE public.championship_bracket_preview_jobs
            SET status='FAILED', stage='Falha', error_message=$2, completed_at=now(), updated_at=now()
          WHERE id=$1`,
        [job.jobId, error instanceof Error ? error.message : "Falha ao enfileirar prévia."],
      );
      throw new ApiError(503, "PREVIEW_QUEUE_UNAVAILABLE", "Não foi possível enfileirar a prévia.");
    }

    return job;
  }

  async get(jobId: string): Promise<PreviewJobRow> {
    const result = await this.database.query(`${JOB_SELECT} WHERE id = $1`, [jobId]);
    const job = asJob(result.rows[0]);
    if (!job) throw new ApiError(404, "PREVIEW_JOB_NOT_FOUND", "Prévia não encontrada.");
    return job;
  }

  async getDay(jobId: string, date: string): Promise<Record<string, unknown> | null> {
    const job = await this.get(jobId);
    const result = job.result;
    const days = array(result?.days);
    return (
      (days.find((rawDay) => text(record(rawDay).date) === date) as Record<string, unknown>) ?? null
    );
  }

  async cancel(jobId: string): Promise<PreviewJobRow> {
    await this.database.query(
      `UPDATE public.championship_bracket_preview_jobs
          SET status='CANCELLED', stage='Cancelado', completed_at=now(), updated_at=now()
        WHERE id=$1 AND status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING')`,
      [jobId],
    );
    return this.get(jobId);
  }

  async process(jobId: string): Promise<void> {
    const claimed = await this.database.query(
      `UPDATE public.championship_bracket_preview_jobs
          SET status='INITIALIZING', stage='Preparando prévia', started_at=COALESCE(started_at, now()),
              heartbeat_at=now(), attempt_count=attempt_count+1, updated_at=now()
        WHERE id=$1 AND status='QUEUED'
        RETURNING payload`,
      [jobId],
    );
    if (!claimed.rows[0]) return;

    try {
      const payload = record(claimed.rows[0].payload);
      await this.database.query(
        `UPDATE public.championship_bracket_preview_jobs
            SET status='SCHEDULING', stage='Montando agenda', progress_percentage=20,
                heartbeat_at=now(), updated_at=now()
          WHERE id=$1`,
        [jobId],
      );

      const names = await loadNames(this.database, payload);
      const result = buildBracketPreviewResult(payload, names.teamNames, names.sportNames);
      const generationSignature = signature(result.days);
      result.generation_signature = generationSignature;

      await this.database.query(
        `UPDATE public.championship_bracket_preview_jobs
            SET status='FINALIZING', stage='Finalizando', progress_percentage=90,
                processed_slots=total_slots, heartbeat_at=now(), updated_at=now()
          WHERE id=$1`,
        [jobId],
      );

      const completed = await this.database.query(
        `UPDATE public.championship_bracket_preview_jobs
            SET status='COMPLETED', stage='Concluído', progress_percentage=100,
                summary=$2::jsonb, diagnostics=$3::jsonb, result=$4::jsonb,
                generation_signature=$5, completed_at=now(), heartbeat_at=now(), updated_at=now()
          WHERE id=$1 AND status='FINALIZING'
          RETURNING id`,
        [
          jobId,
          JSON.stringify(result.summary),
          JSON.stringify(result.diagnostics),
          JSON.stringify(result),
          generationSignature,
        ],
      );
      if (!completed.rows[0]) return;
    } catch (error) {
      const message = error instanceof Error ? error.message : "Falha ao processar a prévia.";
      await this.database.query(
        `UPDATE public.championship_bracket_preview_jobs
            SET status='FAILED', stage='Falha', error_message=$2,
                completed_at=now(), heartbeat_at=now(), updated_at=now()
          WHERE id=$1 AND status IN ('INITIALIZING','SCHEDULING','FINALIZING')`,
        [jobId, message],
      );
      throw error;
    }
  }

  async recoverAndCleanup(): Promise<number> {
    const stale = await this.database.query(
      `UPDATE public.championship_bracket_preview_jobs
          SET status='QUEUED', stage='Na fila', heartbeat_at=now(), updated_at=now()
        WHERE status IN ('INITIALIZING','SCHEDULING','FINALIZING')
          AND COALESCE(heartbeat_at, updated_at) < now() - interval '90 seconds'
          AND expires_at > now()
        RETURNING id`,
    );

    const queued = await this.database.query(
      `SELECT id FROM public.championship_bracket_preview_jobs
        WHERE status='QUEUED' AND expires_at > now()
        ORDER BY created_at
        LIMIT 20`,
    );
    const ids = [...new Set([...stale.rows, ...queued.rows].map((row) => String(row.id)))];
    for (const id of ids) {
      await this.queue.sendProcessJob(id);
    }

    await this.database.query(
      `DELETE FROM public.championship_bracket_preview_jobs
        WHERE expires_at < now()
          AND status IN ('COMPLETED','FAILED','CANCELLED','CONSUMED')`,
    );
    return ids.length;
  }
}

export function serializePreviewJob(job: PreviewJobRow): Record<string, unknown> {
  return {
    job_id: job.jobId,
    championship_id: job.championshipId,
    season_year: job.seasonYear,
    status: job.status,
    stage: job.stage,
    current_date: job.currentDate,
    progress_percentage: job.progressPercentage,
    processed_slots: job.processedSlots,
    total_slots: job.totalSlots,
    attempt_count: job.attemptCount,
    error_message: job.errorMessage,
    summary: job.summary,
    diagnostics: job.diagnostics ?? [],
    payload_signature: job.payloadSignature,
    dependency_signature: job.dependencySignature,
    algorithm_version: job.algorithmVersion,
    generation_signature: job.generationSignature,
    created_at: job.createdAt,
    started_at: job.startedAt,
    completed_at: job.completedAt,
    expires_at: job.expiresAt,
    is_valid_for_creation:
      job.status === "COMPLETED" &&
      !array(job.diagnostics).some((item) => record(item).severity === "ERROR"),
    events: job.events ?? [],
  };
}
