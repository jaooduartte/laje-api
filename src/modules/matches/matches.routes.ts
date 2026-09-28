import { Router, type Request } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import {
  optionalEnum,
  optionalInteger,
  optionalString,
  optionalUuid,
  parseDate,
  parsePagination,
  requireInteger,
  requireRecord,
  requireUuid,
} from "../../common/validation/common.schema.js";
import { database } from "../../database/index.js";
import type { DatabaseQueryExecutor, DatabaseRow } from "../../database/types.js";
import { createRequireAuthentication, requirePermission, type AuthenticatedRequest } from "../auth/auth.middleware.js";
import type { AuthService } from "../auth/auth.service.js";

const MATCH_STATUSES = ["SCHEDULED", "LIVE", "FINISHED"] as const;
const MATCH_NAIPES = ["MASCULINO", "FEMININO", "MISTO"] as const;
const TEAM_DIVISIONS = ["DIVISAO_PRINCIPAL", "DIVISAO_ACESSO"] as const;

interface MatchFilters {
  championshipId?: string;
  seasonYear?: number;
  statuses?: string[];
  sportId?: string;
  teamId?: string;
  naipe?: string;
  division?: string;
  location?: string;
  courtName?: string;
  from?: string;
  to?: string;
  matchIds?: string[];
  page: number;
  pageSize: number;
  offset: number;
  sort: "scheduledDate" | "queuePosition" | "createdAt";
  order: "asc" | "desc";
}

interface ScoreboardPatch {
  homeScore?: number;
  awayScore?: number;
  currentSetHomeScore?: number | null;
  currentSetAwayScore?: number | null;
  homeYellowCards?: number;
  homeRedCards?: number;
  homeBlueCards?: number;
  homeTwoMinutePenalties?: number;
  awayYellowCards?: number;
  awayRedCards?: number;
  awayBlueCards?: number;
  awayTwoMinutePenalties?: number;
  homePenaltyScore?: number | null;
  awayPenaltyScore?: number | null;
}

function readQueryValues(value: unknown): string[] | undefined {
  if (value == null) return undefined;
  if (Array.isArray(value)) return value.flatMap((item) => (typeof item == "string" ? [item] : []));
  if (typeof value == "string") return value.split(",").map((item) => item.trim()).filter(Boolean);
  return undefined;
}

function parseMatchFilters(request: Request): MatchFilters {
  const query = request.query as Record<string, unknown>;
  const pagination = parsePagination(query);
  const rawStatuses = readQueryValues(query.status);
  const statuses = rawStatuses?.map((status) => optionalEnum(status, "status", MATCH_STATUSES)!) ?? undefined;
  const rawMatchIds = readQueryValues(query.matchId ?? query.matchIds);
  const matchIds = rawMatchIds?.map((id) => requireUuid(id, "matchId"));
  const sort = optionalEnum(query.sort, "sort", ["scheduledDate", "queuePosition", "createdAt"] as const) ?? "scheduledDate";
  const order = optionalEnum(query.order, "order", ["asc", "desc"] as const) ?? "asc";
  const from = parseDate(query.from, "from");
  const to = parseDate(query.to, "to");
  if (from && to && from > to) throw new ApiError(422, "VALIDATION_ERROR", "O filtro from não pode ser posterior a to.");
  return {
    ...pagination,
    ...(optionalUuid(query.championshipId, "championshipId") ? { championshipId: optionalUuid(query.championshipId, "championshipId") } : {}),
    ...(optionalInteger(query.seasonYear, "seasonYear", { min: 2000, max: 2100 }) ? { seasonYear: optionalInteger(query.seasonYear, "seasonYear", { min: 2000, max: 2100 }) } : {}),
    ...(statuses && statuses.length > 0 ? { statuses } : {}),
    ...(optionalUuid(query.sportId, "sportId") ? { sportId: optionalUuid(query.sportId, "sportId") } : {}),
    ...(optionalUuid(query.teamId, "teamId") ? { teamId: optionalUuid(query.teamId, "teamId") } : {}),
    ...(optionalEnum(query.naipe, "naipe", MATCH_NAIPES) ? { naipe: optionalEnum(query.naipe, "naipe", MATCH_NAIPES) } : {}),
    ...(optionalEnum(query.division, "division", TEAM_DIVISIONS) ? { division: optionalEnum(query.division, "division", TEAM_DIVISIONS) } : {}),
    ...(optionalString(query.location, "location", 255) ? { location: optionalString(query.location, "location", 255) } : {}),
    ...(optionalString(query.courtName, "courtName", 255) ? { courtName: optionalString(query.courtName, "courtName", 255) } : {}),
    ...(from ? { from } : {}),
    ...(to ? { to } : {}),
    ...(matchIds && matchIds.length > 0 ? { matchIds } : {}),
    sort,
    order,
  } as MatchFilters;
}

function nullableNonNegativeInteger(value: unknown, field: string): number | null | undefined {
  if (value === null) return null;
  if (value === undefined) return undefined;
  return requireInteger(value, field, { min: 0 });
}

function parseScoreboardPatch(body: unknown): ScoreboardPatch {
  const payload = requireRecord(body);
  const patch: ScoreboardPatch = {};
  const numericFields: Array<[keyof ScoreboardPatch, string]> = [
    ["homeScore", "homeScore"], ["awayScore", "awayScore"],
    ["homeYellowCards", "homeYellowCards"], ["homeRedCards", "homeRedCards"],
    ["homeBlueCards", "homeBlueCards"], ["homeTwoMinutePenalties", "homeTwoMinutePenalties"],
    ["awayYellowCards", "awayYellowCards"], ["awayRedCards", "awayRedCards"],
    ["awayBlueCards", "awayBlueCards"], ["awayTwoMinutePenalties", "awayTwoMinutePenalties"],
  ];
  for (const [property, field] of numericFields) {
    if (payload[field] !== undefined) patch[property] = requireInteger(payload[field], field, { min: 0 });
  }
  for (const [property, field] of [
    ["currentSetHomeScore", "currentSetHomeScore"],
    ["currentSetAwayScore", "currentSetAwayScore"],
    ["homePenaltyScore", "homePenaltyScore"],
    ["awayPenaltyScore", "awayPenaltyScore"],
  ] as const) {
    const value = nullableNonNegativeInteger(payload[field], field);
    if (value !== undefined) patch[property] = value;
  }
  if (Object.keys(patch).length === 0) throw new ApiError(422, "VALIDATION_ERROR", "Informe ao menos um campo de placar para atualização.");
  return patch;
}

const MATCH_SELECT = `
  SELECT
    m.id,
    m.championship_id AS "championshipId",
    m.season_year AS "seasonYear",
    m.division,
    m.naipe,
    m.supports_cards AS "supportsCards",
    m.sport_id AS "sportId",
    m.home_team_id AS "homeTeamId",
    m.away_team_id AS "awayTeamId",
    m.location,
    m.court_name AS "courtName",
    m.scheduled_date::text AS "scheduledDate",
    m.queue_position AS "queuePosition",
    m.scheduled_slot AS "scheduledSlot",
    m.scheduled_start_time::text AS "scheduledStartTime",
    m.start_time::text AS "startTime",
    m.end_time::text AS "endTime",
    m.status,
    m.home_score AS "homeScore",
    m.away_score AS "awayScore",
    m.current_set_home_score AS "currentSetHomeScore",
    m.current_set_away_score AS "currentSetAwayScore",
    m.home_penalty_score AS "homePenaltyScore",
    m.away_penalty_score AS "awayPenaltyScore",
    m.home_yellow_cards AS "homeYellowCards",
    m.home_red_cards AS "homeRedCards",
    m.home_blue_cards AS "homeBlueCards",
    m.home_two_minute_penalties AS "homeTwoMinutePenalties",
    m.away_yellow_cards AS "awayYellowCards",
    m.away_red_cards AS "awayRedCards",
    m.away_blue_cards AS "awayBlueCards",
    m.away_two_minute_penalties AS "awayTwoMinutePenalties",
    m.is_walkover AS "isWalkover",
    m.walkover_loser_team_id AS "walkoverLoserTeamId",
    m.is_double_walkover AS "isDoubleWalkover",
    m.resolved_tie_breaker_rule AS "resolvedTieBreakerRule",
    m.resolved_tie_break_winner_team_id AS "resolvedTieBreakWinnerTeamId",
    m.is_manual_schedule_override AS "isManualScheduleOverride",
    m.manual_representation_mode AS "manualRepresentationMode",
    m.is_pending_manual_relocation AS "isPendingManualRelocation",
    m.is_score_sheet_reviewed AS "isScoreSheetReviewed",
    m.created_at::text AS "createdAt",
    jsonb_build_object('id', s.id, 'name', s.name, 'code', s.code) AS sport,
    jsonb_build_object('id', ht.id, 'name', ht.name, 'city', ht.city, 'division', ht.division) AS "homeTeam",
    jsonb_build_object('id', at.id, 'name', at.name, 'city', at.city, 'division', at.division) AS "awayTeam",
    COALESCE((SELECT jsonb_agg(jsonb_build_object('id', ms.id, 'setNumber', ms.set_number, 'homePoints', ms.home_points, 'awayPoints', ms.away_points) ORDER BY ms.set_number) FROM public.match_sets ms WHERE ms.match_id = m.id), '[]'::jsonb) AS "matchSets"
  FROM public.matches m
  JOIN public.sports s ON s.id = m.sport_id
  JOIN public.teams ht ON ht.id = m.home_team_id
  JOIN public.teams at ON at.id = m.away_team_id`;

async function getMatch(executor: DatabaseQueryExecutor, matchId: string) {
  const result = await executor.query(`${MATCH_SELECT} WHERE m.id = $1`, [matchId]);
  return result.rows[0] ?? null;
}

async function insertAudit(
  executor: DatabaseQueryExecutor,
  request: AuthenticatedRequest,
  recordId: string,
  description: string,
  oldData: DatabaseRow,
  newData: DatabaseRow,
): Promise<void> {
  const principal = request.authPrincipal;
  await executor.query(
    `INSERT INTO public.admin_action_logs
      (actor_user_id, actor_email, actor_role, action_type, resource_table, record_id, description, old_data, new_data, metadata, actor_name)
     VALUES ($1, $2, $3::public.app_role, 'UPDATE', 'matches', $4, $5, $6::jsonb, $7::jsonb, '{"source":"laje-api","task":"LAJE-86"}'::jsonb, $8)`,
    [
      principal?.userId ?? null,
      principal?.user.email ?? null,
      principal?.user.role ?? null,
      recordId,
      description,
      JSON.stringify(oldData),
      JSON.stringify(newData),
      principal?.user.profile?.name ?? null,
    ],
  );
}

function buildListStatement(filters: MatchFilters) {
  const conditions: string[] = [];
  const parameters: unknown[] = [];
  const add = (condition: string, value: unknown) => {
    parameters.push(value);
    conditions.push(condition.replace("?", `$${parameters.length}`));
  };
  if (filters.championshipId) add("m.championship_id = ?", filters.championshipId);
  if (filters.seasonYear) add("m.season_year = ?", filters.seasonYear);
  if (filters.statuses) add("m.status = ANY(?::public.match_status[])", filters.statuses);
  if (filters.sportId) add("m.sport_id = ?", filters.sportId);
  if (filters.teamId) add("(m.home_team_id = ? OR m.away_team_id = ?)", filters.teamId);
  if (filters.teamId) parameters.push(filters.teamId);
  if (filters.naipe) add("m.naipe = ?::public.match_naipe", filters.naipe);
  if (filters.division) add("m.division = ?::public.team_division", filters.division);
  if (filters.location) add("m.location = ?", filters.location);
  if (filters.courtName) add("m.court_name = ?", filters.courtName);
  if (filters.from) add("m.scheduled_date >= ?::date", filters.from);
  if (filters.to) add("m.scheduled_date <= ?::date", filters.to);
  if (filters.matchIds) add("m.id = ANY(?::uuid[])", filters.matchIds);
  const orderColumn = filters.sort === "queuePosition" ? "m.queue_position" : filters.sort === "createdAt" ? "m.created_at" : "m.scheduled_date";
  const order = filters.order.toUpperCase();
  parameters.push(filters.pageSize, filters.offset);
  const limitParam = `$${parameters.length - 1}`;
  const offsetParam = `$${parameters.length}`;
  const where = conditions.length > 0 ? ` WHERE ${conditions.join(" AND ")}` : "";
  return {
    statement: `${MATCH_SELECT}, count(*) OVER()::int AS "totalCount"${where} ORDER BY ${orderColumn} ${order} NULLS LAST, m.queue_position ${order}, m.id ASC LIMIT ${limitParam} OFFSET ${offsetParam}`,
    parameters,
  };
}

export function createMatchesRouter(authService: AuthService): Router {
  const router = Router();
  const requireAuthentication = createRequireAuthentication(authService);
  const requireControlEdit = [requireAuthentication, requirePermission("control", "EDIT")] as const;

  router.get("/", async (request, response, next) => {
    try {
      const filters = parseMatchFilters(request);
      const { statement, parameters } = buildListStatement(filters);
      const result = await database.query(statement, parameters);
      const total = Number(result.rows[0]?.totalCount ?? 0);
      const data = result.rows.map(({ totalCount: _totalCount, ...row }) => row);
      response.status(200).json({ data, meta: { page: filters.page, pageSize: filters.pageSize, total, totalPages: Math.ceil(total / filters.pageSize) } });
    } catch (error) { next(error); }
  });

  router.get("/:matchId", async (request, response, next) => {
    try {
      const matchId = requireUuid(request.params.matchId, "matchId");
      const match = await getMatch(database, matchId);
      if (!match) throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
      response.status(200).json({ data: match });
    } catch (error) { next(error); }
  });

  router.post("/:matchId/start", ...requireControlEdit, async (request, response, next) => {
    try {
      const matchId = requireUuid(request.params.matchId, "matchId");
      const updated = await database.transaction(async (tx) => {
        const oldMatch = await getMatch(tx, matchId);
        if (!oldMatch) throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        if (oldMatch.status !== "SCHEDULED") throw new ApiError(409, "MATCH_STATE_CONFLICT", "Somente jogos agendados podem ser iniciados.");
        await tx.query("UPDATE public.matches SET status = 'LIVE', start_time = COALESCE(start_time, now()) WHERE id = $1 AND status = 'SCHEDULED'", [matchId]);
        const newMatch = await getMatch(tx, matchId);
        if (!newMatch || newMatch.status !== "LIVE") throw new ApiError(409, "MATCH_UPDATE_CONFLICT", "O jogo foi alterado concorrentemente.");
        await insertAudit(tx, request as AuthenticatedRequest, matchId, "Jogo iniciado via laje-api.", oldMatch, newMatch);
        return newMatch;
      });
      response.status(200).json({ data: updated });
    } catch (error) { next(error); }
  });

  router.patch("/:matchId/scoreboard", ...requireControlEdit, async (request, response, next) => {
    try {
      const matchId = requireUuid(request.params.matchId, "matchId");
      const patch = parseScoreboardPatch(request.body);
      const columnByProperty: Record<string, string> = {
        homeScore: "home_score", awayScore: "away_score", currentSetHomeScore: "current_set_home_score", currentSetAwayScore: "current_set_away_score",
        homeYellowCards: "home_yellow_cards", homeRedCards: "home_red_cards", homeBlueCards: "home_blue_cards", homeTwoMinutePenalties: "home_two_minute_penalties",
        awayYellowCards: "away_yellow_cards", awayRedCards: "away_red_cards", awayBlueCards: "away_blue_cards", awayTwoMinutePenalties: "away_two_minute_penalties",
        homePenaltyScore: "home_penalty_score", awayPenaltyScore: "away_penalty_score",
      };
      const updated = await database.transaction(async (tx) => {
        const oldMatch = await getMatch(tx, matchId);
        if (!oldMatch) throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        if (oldMatch.status !== "LIVE") throw new ApiError(409, "MATCH_STATE_CONFLICT", "O placar operacional só pode ser alterado enquanto o jogo estiver ao vivo.");
        const entries = Object.entries(patch);
        const assignments = entries.map(([property], index) => `${columnByProperty[property]} = $${index + 2}`).join(", ");
        await tx.query(`UPDATE public.matches SET ${assignments} WHERE id = $1 AND status = 'LIVE'`, [matchId, ...entries.map(([, value]) => value)]);
        const newMatch = await getMatch(tx, matchId);
        if (!newMatch) throw new ApiError(409, "MATCH_UPDATE_CONFLICT", "Não foi possível persistir o placar.");
        await insertAudit(tx, request as AuthenticatedRequest, matchId, "Placar atualizado via laje-api.", oldMatch, newMatch);
        return newMatch;
      });
      response.status(200).json({ data: updated });
    } catch (error) { next(error); }
  });

  router.post("/:matchId/finish", ...requireControlEdit, async (request, response, next) => {
    try {
      const matchId = requireUuid(request.params.matchId, "matchId");
      const payload = request.body == null ? {} : requireRecord(request.body);
      const scoreboardPayload = Object.fromEntries(Object.entries(payload).filter(([key]) => !["isWalkover", "walkoverLoserTeamId", "isDoubleWalkover"].includes(key)));
      const patch = Object.keys(scoreboardPayload).length > 0 ? parseScoreboardPatch(scoreboardPayload) : {};
      const isWalkover = payload.isWalkover === undefined ? undefined : Boolean(payload.isWalkover);
      const isDoubleWalkover = payload.isDoubleWalkover === undefined ? undefined : Boolean(payload.isDoubleWalkover);
      const walkoverLoserTeamId = payload.walkoverLoserTeamId === null ? null : optionalUuid(payload.walkoverLoserTeamId, "walkoverLoserTeamId");
      const columnByProperty: Record<string, string> = {
        homeScore: "home_score", awayScore: "away_score", currentSetHomeScore: "current_set_home_score", currentSetAwayScore: "current_set_away_score",
        homeYellowCards: "home_yellow_cards", homeRedCards: "home_red_cards", homeBlueCards: "home_blue_cards", homeTwoMinutePenalties: "home_two_minute_penalties",
        awayYellowCards: "away_yellow_cards", awayRedCards: "away_red_cards", awayBlueCards: "away_blue_cards", awayTwoMinutePenalties: "away_two_minute_penalties",
        homePenaltyScore: "home_penalty_score", awayPenaltyScore: "away_penalty_score",
      };
      const updated = await database.transaction(async (tx) => {
        const oldMatch = await getMatch(tx, matchId);
        if (!oldMatch) throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        if (oldMatch.status !== "LIVE") throw new ApiError(409, "MATCH_STATE_CONFLICT", "Somente jogos ao vivo podem ser encerrados.");
        const entries = Object.entries(patch);
        const parameters: unknown[] = [matchId, ...entries.map(([, value]) => value)];
        const assignments = entries.map(([property], index) => `${columnByProperty[property]} = $${index + 2}`);
        if (isWalkover !== undefined) { parameters.push(isWalkover); assignments.push(`is_walkover = $${parameters.length}`); }
        if (isDoubleWalkover !== undefined) { parameters.push(isDoubleWalkover); assignments.push(`is_double_walkover = $${parameters.length}`); }
        if (walkoverLoserTeamId !== undefined || payload.walkoverLoserTeamId === null) { parameters.push(walkoverLoserTeamId ?? null); assignments.push(`walkover_loser_team_id = $${parameters.length}`); }
        assignments.push("status = 'FINISHED'", "end_time = COALESCE(end_time, now())");
        await tx.query(`UPDATE public.matches SET ${assignments.join(", ")} WHERE id = $1 AND status = 'LIVE'`, parameters);
        const newMatch = await getMatch(tx, matchId);
        if (!newMatch || newMatch.status !== "FINISHED") throw new ApiError(409, "MATCH_UPDATE_CONFLICT", "O jogo foi alterado concorrentemente.");
        await insertAudit(tx, request as AuthenticatedRequest, matchId, "Jogo encerrado via laje-api.", oldMatch, newMatch);
        return newMatch;
      });
      response.status(200).json({ data: updated });
    } catch (error) { next(error); }
  });

  return router;
}
