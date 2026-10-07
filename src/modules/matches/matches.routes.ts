import { Router, type Request } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import {
  optionalBoolean,
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
import {
  createRequireAuthentication,
  requirePermission,
  type AuthenticatedRequest,
} from "../auth/auth.middleware.js";
import type { AuthService } from "../auth/auth.service.js";
import { recalculateCollectiveStandings } from "../standings/standings.repository.js";

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
  groupNumber?: number;
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

interface MatchSetInput {
  setNumber: number;
  homePoints: number;
  awayPoints: number;
}

interface ScoreboardPayload {
  patch: ScoreboardPatch;
  sets?: MatchSetInput[];
}

function readQueryValues(value: unknown): string[] | undefined {
  if (value == null) return undefined;
  if (Array.isArray(value)) {
    return value.flatMap((item) => (typeof item == "string" ? [item] : []));
  }
  if (typeof value == "string") {
    return value
      .split(",")
      .map((item) => item.trim())
      .filter(Boolean);
  }
  return undefined;
}

function parseMatchFilters(request: Request): MatchFilters {
  const query = request.query as Record<string, unknown>;
  const pagination = parsePagination(query);
  const rawStatuses = readQueryValues(query.status);
  const statuses = rawStatuses?.map((status) => optionalEnum(status, "status", MATCH_STATUSES));
  const rawMatchIds = readQueryValues(query.matchId ?? query.matchIds);
  const matchIds = rawMatchIds?.map((id) => requireUuid(id, "matchId"));
  const sort =
    optionalEnum(query.sort, "sort", ["scheduledDate", "queuePosition", "createdAt"] as const) ??
    "scheduledDate";
  const order = optionalEnum(query.order, "order", ["asc", "desc"] as const) ?? "asc";
  const from = parseDate(query.from, "from");
  const to = parseDate(query.to, "to");
  if (from && to && from > to) {
    throw new ApiError(422, "VALIDATION_ERROR", "O filtro from não pode ser posterior a to.");
  }

  const championshipId = optionalUuid(query.championshipId, "championshipId");
  const seasonYear = optionalInteger(query.seasonYear, "seasonYear", {
    min: 2000,
    max: 2100,
  });
  const sportId = optionalUuid(query.sportId, "sportId");
  const teamId = optionalUuid(query.teamId, "teamId");
  const naipe = optionalEnum(query.naipe, "naipe", MATCH_NAIPES);
  const division = optionalEnum(query.division, "division", TEAM_DIVISIONS);
  const groupNumber = optionalInteger(query.groupNumber, "groupNumber", {
    min: 1,
    max: 64,
  });
  const location = optionalString(query.location, "location", 255);
  const courtName = optionalString(query.courtName, "courtName", 255);

  return {
    ...pagination,
    ...(championshipId ? { championshipId } : {}),
    ...(seasonYear ? { seasonYear } : {}),
    ...(statuses && statuses.length > 0 ? { statuses } : {}),
    ...(sportId ? { sportId } : {}),
    ...(teamId ? { teamId } : {}),
    ...(naipe ? { naipe } : {}),
    ...(division ? { division } : {}),
    ...(groupNumber ? { groupNumber } : {}),
    ...(location ? { location } : {}),
    ...(courtName ? { courtName } : {}),
    ...(from ? { from } : {}),
    ...(to ? { to } : {}),
    ...(matchIds && matchIds.length > 0 ? { matchIds } : {}),
    sort,
    order,
  };
}

function nullableNonNegativeInteger(value: unknown, field: string): number | null | undefined {
  if (value === null) return null;
  if (value === undefined) return undefined;
  return requireInteger(value, field, { min: 0 });
}

function parseSets(value: unknown): MatchSetInput[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value)) {
    throw new ApiError(422, "VALIDATION_ERROR", "O campo sets deve ser uma lista.");
  }

  const seen = new Set<number>();
  return value.map((rawSet, index) => {
    const set = requireRecord(rawSet, `Set ${index + 1} inválido.`);
    const setNumber = requireInteger(set.setNumber, `sets[${index}].setNumber`, {
      min: 1,
      max: 20,
    });
    if (seen.has(setNumber)) {
      throw new ApiError(
        422,
        "VALIDATION_ERROR",
        `O set ${setNumber} foi informado mais de uma vez.`,
      );
    }
    seen.add(setNumber);
    return {
      setNumber,
      homePoints: requireInteger(set.homePoints, `sets[${index}].homePoints`, {
        min: 0,
      }),
      awayPoints: requireInteger(set.awayPoints, `sets[${index}].awayPoints`, {
        min: 0,
      }),
    };
  });
}

function parseScoreboardPayload(body: unknown, requireMutation = true): ScoreboardPayload {
  const payload = requireRecord(body);
  const patch: ScoreboardPatch = {};
  const numericFields: Array<[keyof ScoreboardPatch, string]> = [
    ["homeScore", "homeScore"],
    ["awayScore", "awayScore"],
    ["homeYellowCards", "homeYellowCards"],
    ["homeRedCards", "homeRedCards"],
    ["homeBlueCards", "homeBlueCards"],
    ["homeTwoMinutePenalties", "homeTwoMinutePenalties"],
    ["awayYellowCards", "awayYellowCards"],
    ["awayRedCards", "awayRedCards"],
    ["awayBlueCards", "awayBlueCards"],
    ["awayTwoMinutePenalties", "awayTwoMinutePenalties"],
  ];
  for (const [property, field] of numericFields) {
    if (payload[field] !== undefined) {
      patch[property] = requireInteger(payload[field], field, { min: 0 });
    }
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

  const sets = parseSets(payload.sets);
  if (sets && sets.length > 0 && patch.homeScore === undefined && patch.awayScore === undefined) {
    patch.homeScore = sets.filter((set) => set.homePoints > set.awayPoints).length;
    patch.awayScore = sets.filter((set) => set.awayPoints > set.homePoints).length;
  }

  if (requireMutation && Object.keys(patch).length === 0 && sets === undefined) {
    throw new ApiError(
      422,
      "VALIDATION_ERROR",
      "Informe ao menos um campo de placar ou a lista de sets para atualização.",
    );
  }

  return { patch, ...(sets !== undefined ? { sets } : {}) };
}

const MATCH_COLUMNS = `
  m.id,
  m.championship_id AS "championshipId",
  m.season_year AS "seasonYear",
  m.division,
  m.naipe,
  m.supports_cards AS "supportsCards",
  cs.result_rule AS "resultRule",
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
  m.disqualification_id AS "disqualificationId",
  m.resolved_tie_breaker_rule AS "resolvedTieBreakerRule",
  m.resolved_tie_break_winner_team_id AS "resolvedTieBreakWinnerTeamId",
  m.is_manual_schedule_override AS "isManualScheduleOverride",
  m.manual_representation_mode AS "manualRepresentationMode",
  m.is_pending_manual_relocation AS "isPendingManualRelocation",
  m.is_score_sheet_reviewed AS "isScoreSheetReviewed",
  m.created_at::text AS "createdAt",
  bg.group_number AS "groupNumber",
  jsonb_build_object(
    'id', c.id,
    'code', c.code,
    'name', c.name,
    'status', c.status,
    'currentSeasonYear', c.current_season_year,
    'usesDivisions', c.uses_divisions,
    'defaultLocation', c.default_location
  ) AS championship,
  jsonb_build_object('id', s.id, 'name', s.name, 'code', s.code) AS sport,
  jsonb_build_object(
    'id', ht.id, 'name', ht.name, 'city', ht.city, 'division', ht.division
  ) AS "homeTeam",
  jsonb_build_object(
    'id', at.id, 'name', at.name, 'city', at.city, 'division', at.division
  ) AS "awayTeam",
  COALESCE(
    (
      SELECT jsonb_agg(
        jsonb_build_object(
          'id', ms.id,
          'setNumber', ms.set_number,
          'homePoints', ms.home_points,
          'awayPoints', ms.away_points
        ) ORDER BY ms.set_number
      )
      FROM public.match_sets ms
      WHERE ms.match_id = m.id
    ),
    '[]'::jsonb
  ) AS "matchSets"`;

const MATCH_FROM = `
  FROM public.matches m
  JOIN public.championships c ON c.id = m.championship_id
  JOIN public.sports s ON s.id = m.sport_id
  JOIN public.teams ht ON ht.id = m.home_team_id
  JOIN public.teams at ON at.id = m.away_team_id
  LEFT JOIN public.championship_sports cs
    ON cs.championship_id = m.championship_id AND cs.sport_id = m.sport_id
  LEFT JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
  LEFT JOIN public.championship_bracket_groups bg ON bg.id = bm.group_id`;

async function getMatch(executor: DatabaseQueryExecutor, matchId: string) {
  const result = await executor.query(`SELECT ${MATCH_COLUMNS}${MATCH_FROM} WHERE m.id = $1`, [
    matchId,
  ]);
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
      (actor_user_id, actor_email, actor_role, action_type, resource_table,
       record_id, description, old_data, new_data, metadata, actor_name)
     VALUES ($1, $2, $3::public.app_role, 'UPDATE', 'matches', $4, $5,
       $6::jsonb, $7::jsonb,
       '{"source":"laje-api","task":"LAJE-86"}'::jsonb, $8)`,
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

  const add = (conditionFactory: (parameter: string) => string, value: unknown) => {
    parameters.push(value);
    conditions.push(conditionFactory(`$${parameters.length}`));
  };

  if (filters.championshipId) {
    add((parameter) => `m.championship_id = ${parameter}`, filters.championshipId);
  }
  if (filters.seasonYear) {
    add((parameter) => `m.season_year = ${parameter}`, filters.seasonYear);
  }
  if (filters.statuses) {
    add((parameter) => `m.status = ANY(${parameter}::public.match_status[])`, filters.statuses);
  }
  if (filters.sportId) {
    add((parameter) => `m.sport_id = ${parameter}`, filters.sportId);
  }
  if (filters.teamId) {
    add(
      (parameter) => `(m.home_team_id = ${parameter}::uuid OR m.away_team_id = ${parameter}::uuid)`,
      filters.teamId,
    );
  }
  if (filters.naipe) {
    add((parameter) => `m.naipe = ${parameter}::public.match_naipe`, filters.naipe);
  }
  if (filters.division) {
    add((parameter) => `m.division = ${parameter}::public.team_division`, filters.division);
  }
  if (filters.groupNumber) {
    add((parameter) => `bg.group_number = ${parameter}`, filters.groupNumber);
  }
  if (filters.location) {
    add((parameter) => `m.location = ${parameter}`, filters.location);
  }
  if (filters.courtName) {
    add((parameter) => `m.court_name = ${parameter}`, filters.courtName);
  }
  if (filters.from) {
    add((parameter) => `m.scheduled_date >= ${parameter}::date`, filters.from);
  }
  if (filters.to) {
    add((parameter) => `m.scheduled_date <= ${parameter}::date`, filters.to);
  }
  if (filters.matchIds) {
    add((parameter) => `m.id = ANY(${parameter}::uuid[])`, filters.matchIds);
  }

  const orderColumn =
    filters.sort === "queuePosition"
      ? "m.queue_position"
      : filters.sort === "createdAt"
        ? "m.created_at"
        : "m.scheduled_date";
  const order = filters.order.toUpperCase();
  const where = conditions.length > 0 ? ` WHERE ${conditions.join(" AND ")}` : "";
  parameters.push(filters.pageSize, filters.offset);
  const limitParameter = `$${parameters.length - 1}`;
  const offsetParameter = `$${parameters.length}`;

  return {
    statement: `SELECT ${MATCH_COLUMNS}, count(*) OVER()::int AS "totalCount"${MATCH_FROM}${where}
      ORDER BY ${orderColumn} ${order} NULLS LAST,
        m.queue_position ${order} NULLS LAST,
        m.scheduled_slot ${order} NULLS LAST,
        m.id ASC
      LIMIT ${limitParameter} OFFSET ${offsetParameter}`,
    parameters,
  };
}

async function persistMatchSets(
  executor: DatabaseQueryExecutor,
  matchId: string,
  sets: readonly MatchSetInput[] | undefined,
): Promise<void> {
  if (sets === undefined) return;
  await executor.query("DELETE FROM public.match_sets WHERE match_id = $1", [matchId]);
  for (const set of sets) {
    await executor.query(
      `INSERT INTO public.match_sets
        (match_id, set_number, home_points, away_points)
       VALUES ($1, $2, $3, $4)`,
      [matchId, set.setNumber, set.homePoints, set.awayPoints],
    );
  }
}

async function persistScoreboardPatch(
  executor: DatabaseQueryExecutor,
  matchId: string,
  patch: ScoreboardPatch,
  expectedStatus: "LIVE" | "SCHEDULED",
): Promise<void> {
  const columnByProperty: Record<keyof ScoreboardPatch, string> = {
    homeScore: "home_score",
    awayScore: "away_score",
    currentSetHomeScore: "current_set_home_score",
    currentSetAwayScore: "current_set_away_score",
    homeYellowCards: "home_yellow_cards",
    homeRedCards: "home_red_cards",
    homeBlueCards: "home_blue_cards",
    homeTwoMinutePenalties: "home_two_minute_penalties",
    awayYellowCards: "away_yellow_cards",
    awayRedCards: "away_red_cards",
    awayBlueCards: "away_blue_cards",
    awayTwoMinutePenalties: "away_two_minute_penalties",
    homePenaltyScore: "home_penalty_score",
    awayPenaltyScore: "away_penalty_score",
  };
  const entries = Object.entries(patch) as Array<
    [keyof ScoreboardPatch, ScoreboardPatch[keyof ScoreboardPatch]]
  >;
  if (entries.length === 0) return;
  const assignments = entries.map(
    ([property], index) => `${columnByProperty[property]} = $${index + 2}`,
  );
  const result = await executor.query(
    `UPDATE public.matches SET ${assignments.join(", ")}, updated_at = now()
     WHERE id = $1 AND status = $${entries.length + 2}::public.match_status
     RETURNING id`,
    [matchId, ...entries.map(([, value]) => value), expectedStatus],
  );
  if (result.rows.length === 0) {
    throw new ApiError(409, "MATCH_UPDATE_CONFLICT", "O jogo foi alterado concorrentemente.");
  }
}


interface ScoreSheetSelectionInput {
  playerId?: string;
  playerName?: string;
}

interface ScoreSheetSavePayload {
  homeGoalScorers: ScoreSheetSelectionInput[];
  awayGoalScorers: ScoreSheetSelectionInput[];
  homeYellowCardPlayers: ScoreSheetSelectionInput[];
  awayYellowCardPlayers: ScoreSheetSelectionInput[];
  homeRedCardPlayers: ScoreSheetSelectionInput[];
  awayRedCardPlayers: ScoreSheetSelectionInput[];
  homeBlueCardPlayers: ScoreSheetSelectionInput[];
  awayBlueCardPlayers: ScoreSheetSelectionInput[];
}

function parseScoreSheetSelections(value: unknown, field: string): ScoreSheetSelectionInput[] {
  if (value == null) return [];
  if (!Array.isArray(value)) {
    throw new ApiError(422, "VALIDATION_ERROR", `O campo ${field} deve ser uma lista.`);
  }

  return value.map((rawSelection, index) => {
    const selection = requireRecord(rawSelection, `${field}[${index}] inválido.`);
    const playerId =
      selection.playerId == null ? undefined : requireUuid(selection.playerId, `${field}[${index}].playerId`);
    const playerName =
      selection.playerName == null
        ? undefined
        : optionalString(selection.playerName, `${field}[${index}].playerName`, 180);

    if (!playerId && !playerName) {
      throw new ApiError(
        422,
        "VALIDATION_ERROR",
        `Informe playerId ou playerName em ${field}[${index}].`,
      );
    }

    return {
      ...(playerId ? { playerId } : {}),
      ...(playerName ? { playerName } : {}),
    };
  });
}

function parseScoreSheetSavePayload(body: unknown): ScoreSheetSavePayload {
  const payload = requireRecord(body);
  return {
    homeGoalScorers: parseScoreSheetSelections(payload.homeGoalScorers, "homeGoalScorers"),
    awayGoalScorers: parseScoreSheetSelections(payload.awayGoalScorers, "awayGoalScorers"),
    homeYellowCardPlayers: parseScoreSheetSelections(
      payload.homeYellowCardPlayers,
      "homeYellowCardPlayers",
    ),
    awayYellowCardPlayers: parseScoreSheetSelections(
      payload.awayYellowCardPlayers,
      "awayYellowCardPlayers",
    ),
    homeRedCardPlayers: parseScoreSheetSelections(payload.homeRedCardPlayers, "homeRedCardPlayers"),
    awayRedCardPlayers: parseScoreSheetSelections(payload.awayRedCardPlayers, "awayRedCardPlayers"),
    homeBlueCardPlayers: parseScoreSheetSelections(
      payload.homeBlueCardPlayers,
      "homeBlueCardPlayers",
    ),
    awayBlueCardPlayers: parseScoreSheetSelections(
      payload.awayBlueCardPlayers,
      "awayBlueCardPlayers",
    ),
  };
}

function normalizeAwardPlayerName(value: string): string {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .trim()
    .replace(/\s+/g, " ")
    .toLocaleLowerCase("pt-BR");
}

async function resolveScoreSheetPlayerId(
  executor: DatabaseQueryExecutor,
  selection: ScoreSheetSelectionInput,
  scope: {
    championshipId: string;
    seasonYear: number;
    sportId: string;
    teamId: string;
    naipe: string;
    division: string | null;
  },
): Promise<string> {
  if (selection.playerId) {
    const existing = await executor.query(
      `SELECT id
       FROM public.championship_award_players
       WHERE id = $1
         AND championship_id = $2
         AND season_year = $3
         AND sport_id = $4
         AND team_id = $5
         AND naipe = $6::public.match_naipe
         AND division IS NOT DISTINCT FROM $7::public.team_division
       LIMIT 1`,
      [
        selection.playerId,
        scope.championshipId,
        scope.seasonYear,
        scope.sportId,
        scope.teamId,
        scope.naipe,
        scope.division,
      ],
    );

    if (existing.rows[0]?.id) return String(existing.rows[0].id);
    throw new ApiError(422, "INVALID_SCORE_SHEET_PLAYER", "Atleta inválido para esta súmula.");
  }

  const name = selection.playerName?.trim() ?? "";
  if (!name) {
    throw new ApiError(422, "INVALID_SCORE_SHEET_PLAYER", "Nome do atleta não informado.");
  }
  const normalizedName = normalizeAwardPlayerName(name);

  const findPlayer = async () =>
    executor.query(
      `SELECT id
       FROM public.championship_award_players
       WHERE championship_id = $1
         AND season_year = $2
         AND sport_id = $3
         AND team_id = $4
         AND naipe = $5::public.match_naipe
         AND division IS NOT DISTINCT FROM $6::public.team_division
         AND normalized_name = $7
       LIMIT 1`,
      [
        scope.championshipId,
        scope.seasonYear,
        scope.sportId,
        scope.teamId,
        scope.naipe,
        scope.division,
        normalizedName,
      ],
    );

  const existing = await findPlayer();
  if (existing.rows[0]?.id) return String(existing.rows[0].id);

  await executor.query(
    `INSERT INTO public.championship_award_players
       (championship_id, season_year, sport_id, team_id, naipe, division, name, normalized_name)
     VALUES ($1, $2, $3, $4, $5::public.match_naipe, $6::public.team_division, $7, $8)
     ON CONFLICT DO NOTHING`,
    [
      scope.championshipId,
      scope.seasonYear,
      scope.sportId,
      scope.teamId,
      scope.naipe,
      scope.division,
      name,
      normalizedName,
    ],
  );

  const createdOrExisting = await findPlayer();
  if (!createdOrExisting.rows[0]?.id) {
    throw new ApiError(500, "SCORE_SHEET_PLAYER_SAVE_FAILED", "Não foi possível salvar o atleta.");
  }
  return String(createdOrExisting.rows[0].id);
}

async function getScoreSheetAwardsContext(executor: DatabaseQueryExecutor, matchId: string) {
  const result = await executor.query(
    `WITH match_context AS (
       SELECT
         m.*,
         c.code AS championship_code,
         s.name AS sport_name,
         COALESCE(m.supports_cards, false) OR COALESCE(cs.supports_cards, false) AS supports_cards,
         (
           c.code = 'SOCIETY'::public.championship_code
           AND COALESCE(cs.supports_individual_awards, false)
           AND lower(trim(s.name)) = 'futebol society'
         ) AS requires_goal_scorers
       FROM public.matches m
       JOIN public.championships c ON c.id = m.championship_id
       JOIN public.sports s ON s.id = m.sport_id
       JOIN public.championship_sports cs
         ON cs.championship_id = m.championship_id AND cs.sport_id = m.sport_id
       WHERE m.id = $1
       LIMIT 1
     )
     SELECT jsonb_build_object(
       'match_id', mc.id,
       'home_team_id', mc.home_team_id,
       'away_team_id', mc.away_team_id,
       'requires_goal_scorers', mc.requires_goal_scorers,
       'required_home_goals', CASE WHEN mc.requires_goal_scorers THEN COALESCE(mc.home_score, 0) ELSE 0 END,
       'required_away_goals', CASE WHEN mc.requires_goal_scorers THEN COALESCE(mc.away_score, 0) ELSE 0 END,
       'required_home_yellow_cards', CASE WHEN mc.supports_cards THEN COALESCE(mc.home_yellow_cards, 0) ELSE 0 END,
       'required_away_yellow_cards', CASE WHEN mc.supports_cards THEN COALESCE(mc.away_yellow_cards, 0) ELSE 0 END,
       'required_home_red_cards', CASE WHEN mc.supports_cards THEN COALESCE(mc.home_red_cards, 0) ELSE 0 END,
       'required_away_red_cards', CASE WHEN mc.supports_cards THEN COALESCE(mc.away_red_cards, 0) ELSE 0 END,
       'required_home_blue_cards', CASE WHEN mc.supports_cards THEN COALESCE(mc.home_blue_cards, 0) ELSE 0 END,
       'required_away_blue_cards', CASE WHEN mc.supports_cards THEN COALESCE(mc.away_blue_cards, 0) ELSE 0 END,
       'supports_cards', mc.supports_cards,
       'is_walkover', COALESCE(mc.is_walkover, false),
       'home_players', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) ORDER BY p.name)
         FROM public.championship_award_players p
         WHERE p.championship_id = mc.championship_id
           AND p.season_year = mc.season_year
           AND p.sport_id = mc.sport_id
           AND p.team_id = mc.home_team_id
           AND p.naipe = mc.naipe
           AND p.division IS NOT DISTINCT FROM mc.division
       ), '[]'::jsonb),
       'away_players', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) ORDER BY p.name)
         FROM public.championship_award_players p
         WHERE p.championship_id = mc.championship_id
           AND p.season_year = mc.season_year
           AND p.sport_id = mc.sport_id
           AND p.team_id = mc.away_team_id
           AND p.naipe = mc.naipe
           AND p.division IS NOT DISTINCT FROM mc.division
       ), '[]'::jsonb),
       'home_goals', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('player_id', r.player_id, 'player_name', p.name) ORDER BY r.goal_order)
         FROM public.match_award_goal_scorers r
         JOIN public.championship_award_players p ON p.id = r.player_id
         WHERE r.match_id = mc.id AND r.team_id = mc.home_team_id
       ), '[]'::jsonb),
       'away_goals', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('player_id', r.player_id, 'player_name', p.name) ORDER BY r.goal_order)
         FROM public.match_award_goal_scorers r
         JOIN public.championship_award_players p ON p.id = r.player_id
         WHERE r.match_id = mc.id AND r.team_id = mc.away_team_id
       ), '[]'::jsonb),
       'home_yellow_cards', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('player_id', r.player_id, 'player_name', p.name) ORDER BY r.card_order)
         FROM public.match_yellow_card_players r
         JOIN public.championship_award_players p ON p.id = r.player_id
         WHERE r.match_id = mc.id AND r.team_id = mc.home_team_id
       ), '[]'::jsonb),
       'away_yellow_cards', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('player_id', r.player_id, 'player_name', p.name) ORDER BY r.card_order)
         FROM public.match_yellow_card_players r
         JOIN public.championship_award_players p ON p.id = r.player_id
         WHERE r.match_id = mc.id AND r.team_id = mc.away_team_id
       ), '[]'::jsonb),
       'home_red_cards', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('player_id', r.player_id, 'player_name', p.name) ORDER BY r.card_order)
         FROM public.match_red_card_players r
         JOIN public.championship_award_players p ON p.id = r.player_id
         WHERE r.match_id = mc.id AND r.team_id = mc.home_team_id
       ), '[]'::jsonb),
       'away_red_cards', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('player_id', r.player_id, 'player_name', p.name) ORDER BY r.card_order)
         FROM public.match_red_card_players r
         JOIN public.championship_award_players p ON p.id = r.player_id
         WHERE r.match_id = mc.id AND r.team_id = mc.away_team_id
       ), '[]'::jsonb),
       'home_blue_cards', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('player_id', r.player_id, 'player_name', p.name) ORDER BY r.card_order)
         FROM public.match_blue_card_players r
         JOIN public.championship_award_players p ON p.id = r.player_id
         WHERE r.match_id = mc.id AND r.team_id = mc.home_team_id
       ), '[]'::jsonb),
       'away_blue_cards', COALESCE((
         SELECT jsonb_agg(jsonb_build_object('player_id', r.player_id, 'player_name', p.name) ORDER BY r.card_order)
         FROM public.match_blue_card_players r
         JOIN public.championship_award_players p ON p.id = r.player_id
         WHERE r.match_id = mc.id AND r.team_id = mc.away_team_id
       ), '[]'::jsonb)
     ) AS context
     FROM match_context mc`,
    [matchId],
  );
  return result.rows[0]?.context ?? null;
}

export function createMatchesRouter(authService: AuthService): Router {
  const router = Router();
  const requireAuthentication = createRequireAuthentication(authService);
  const requireControlView = [requireAuthentication, requirePermission("control", "VIEW")] as const;
  const requireControlEdit = [requireAuthentication, requirePermission("control", "EDIT")] as const;
  const requireScoreSheetReviewView = [
    requireAuthentication,
    requirePermission("score_sheet_review", "VIEW"),
  ] as const;
  const requireScoreSheetReviewEdit = [
    requireAuthentication,
    requirePermission("score_sheet_review", "EDIT"),
  ] as const;

  router.get("/operational-queue-state", ...requireControlView, async (request, response, next) => {
    try {
      const championshipId = requireUuid(request.query.championshipId, "championshipId");
      const seasonYear = requireInteger(request.query.seasonYear, "seasonYear", {
        min: 2000,
        max: 2100,
      });

      const result = await database.query(
        `WITH scheduled_matches AS (
           SELECT
             m.id,
             row_number() OVER (
               PARTITION BY m.location, COALESCE(m.court_name, '')
               ORDER BY
                 COALESCE(m.scheduled_start_time, m.start_time) ASC NULLS LAST,
                 COALESCE(m.scheduled_slot, m.queue_position) ASC NULLS LAST,
                 COALESCE(m.queue_position, m.scheduled_slot) ASC NULLS LAST,
                 m.created_at ASC,
                 m.id ASC
             ) AS queue_position
           FROM public.matches m
           WHERE m.championship_id = $1
             AND m.season_year = $2
             AND m.status = 'SCHEDULED'
             AND m.scheduled_date = timezone('America/Sao_Paulo', now())::date
             AND m.is_pending_manual_relocation = false
         ),
         scheduled_sessions AS (
           SELECT
             s.id,
             row_number() OVER (
               PARTITION BY COALESCE(s.location_name, ''), COALESCE(s.court_name, '')
               ORDER BY s.start_time ASC NULLS LAST, s.created_at ASC, s.id ASC
             ) AS queue_position
           FROM public.championship_individual_sessions s
           WHERE s.championship_id = $1
             AND s.season_year = $2
             AND s.status = 'SCHEDULED'
             AND s.scheduled_date = timezone('America/Sao_Paulo', now())::date
         ),
         operational_queue AS (
           SELECT 'MATCH'::text AS item_type, m.id AS item_id
           FROM public.matches m
           WHERE m.championship_id = $1
             AND m.season_year = $2
             AND m.status = 'LIVE'
             AND m.is_pending_manual_relocation = false

           UNION ALL

           SELECT 'MATCH'::text, sm.id
           FROM scheduled_matches sm
           WHERE sm.queue_position <= 1

           UNION ALL

           SELECT 'INDIVIDUAL_SESSION'::text, s.id
           FROM public.championship_individual_sessions s
           WHERE s.championship_id = $1
             AND s.season_year = $2
             AND s.status = 'LIVE'

           UNION ALL

           SELECT 'INDIVIDUAL_SESSION'::text, ss.id
           FROM scheduled_sessions ss
           WHERE ss.queue_position = 1
         )
         SELECT
           COALESCE(
             array_agg(item_id) FILTER (WHERE item_type = 'MATCH'),
             ARRAY[]::uuid[]
           ) AS "matchIds",
           COALESCE(
             array_agg(item_id) FILTER (WHERE item_type = 'INDIVIDUAL_SESSION'),
             ARRAY[]::uuid[]
           ) AS "individualSessionIds",
           (
             SELECT count(*)::bigint
             FROM public.matches m
             WHERE m.championship_id = $1
               AND m.season_year = $2
               AND m.is_pending_manual_relocation = false
               AND m.status IN ('SCHEDULED', 'LIVE')
           ) + (
             SELECT count(*)::bigint
             FROM public.championship_individual_sessions s
             WHERE s.championship_id = $1
               AND s.season_year = $2
               AND s.status IN ('DRAFT', 'SCHEDULED', 'LIVE', 'FINISHED')
           ) AS "fullQueueItemsCount"
         FROM operational_queue`,
        [championshipId, seasonYear],
      );

      const row = result.rows[0] ?? {};
      response.status(200).json({
        data: {
          matchIds: row.matchIds ?? [],
          individualSessionIds: row.individualSessionIds ?? [],
          fullQueueItemsCount: Number(row.fullQueueItemsCount ?? 0),
        },
      });
    } catch (error) {
      next(error);
    }
  });

  router.get(
    "/:matchId/score-sheet-awards",
    ...requireScoreSheetReviewView,
    async (request, response, next) => {
      try {
        const matchId = requireUuid(request.params.matchId, "matchId");
        const context = await getScoreSheetAwardsContext(database, matchId);
        if (!context) {
          throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        }
        response.status(200).json({ data: context });
      } catch (error) {
        next(error);
      }
    },
  );

  router.put(
    "/:matchId/score-sheet-awards",
    ...requireScoreSheetReviewEdit,
    async (request, response, next) => {
      try {
        const matchId = requireUuid(request.params.matchId, "matchId");
        const payload = parseScoreSheetSavePayload(request.body);

        const data = await database.transaction(async (transaction) => {
          const matchResult = await transaction.query(
            `SELECT
               m.id,
               m.championship_id AS "championshipId",
               m.season_year AS "seasonYear",
               m.sport_id AS "sportId",
               m.home_team_id AS "homeTeamId",
               m.away_team_id AS "awayTeamId",
               m.naipe,
               m.division,
               m.status,
               m.home_score AS "homeScore",
               m.away_score AS "awayScore",
               m.home_yellow_cards AS "homeYellowCards",
               m.away_yellow_cards AS "awayYellowCards",
               m.home_red_cards AS "homeRedCards",
               m.away_red_cards AS "awayRedCards",
               m.home_blue_cards AS "homeBlueCards",
               m.away_blue_cards AS "awayBlueCards",
               m.is_walkover AS "isWalkover",
               c.code AS "championshipCode",
               s.name AS "sportName",
               cs.supports_individual_awards AS "supportsIndividualAwards",
               (COALESCE(m.supports_cards, false) OR COALESCE(cs.supports_cards, false)) AS "supportsCards"
             FROM public.matches m
             JOIN public.championships c ON c.id = m.championship_id
             JOIN public.sports s ON s.id = m.sport_id
             JOIN public.championship_sports cs
               ON cs.championship_id = m.championship_id AND cs.sport_id = m.sport_id
             WHERE m.id = $1
             LIMIT 1
             FOR UPDATE OF m`,
            [matchId],
          );
          const match = matchResult.rows[0];
          if (!match) throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
          if (match.status !== "FINISHED") {
            throw new ApiError(
              409,
              "MATCH_STATE_CONFLICT",
              "Só é possível revisar súmulas de jogos encerrados.",
            );
          }

          const requiresGoalScorers =
            match.championshipCode === "SOCIETY" &&
            match.supportsIndividualAwards === true &&
            String(match.sportName).trim().toLocaleLowerCase("pt-BR") === "futebol society";
          const supportsCards = match.supportsCards === true;

          if (match.isWalkover === true) {
            await Promise.all([
              transaction.query("DELETE FROM public.match_award_goal_scorers WHERE match_id = $1", [matchId]),
              transaction.query("DELETE FROM public.match_yellow_card_players WHERE match_id = $1", [matchId]),
              transaction.query("DELETE FROM public.match_red_card_players WHERE match_id = $1", [matchId]),
              transaction.query("DELETE FROM public.match_blue_card_players WHERE match_id = $1", [matchId]),
            ]);
            await transaction.query(
              "UPDATE public.matches SET is_score_sheet_reviewed = true, updated_at = now() WHERE id = $1",
              [matchId],
            );
            return { match_id: matchId, is_walkover: true, is_score_sheet_reviewed: true };
          }

          if (requiresGoalScorers && payload.homeGoalScorers.length !== Number(match.homeScore ?? 0)) {
            throw new ApiError(422, "INVALID_SCORE_SHEET", "A soma de gols da casa precisa ser igual ao placar final.");
          }
          if (requiresGoalScorers && payload.awayGoalScorers.length !== Number(match.awayScore ?? 0)) {
            throw new ApiError(422, "INVALID_SCORE_SHEET", "A soma de gols do visitante precisa ser igual ao placar final.");
          }

          const disciplineChecks: Array<[number, number, string]> = [
            [payload.homeYellowCardPlayers.length, Number(match.homeYellowCards ?? 0), "cartões amarelos da casa"],
            [payload.awayYellowCardPlayers.length, Number(match.awayYellowCards ?? 0), "cartões amarelos do visitante"],
            [payload.homeRedCardPlayers.length, Number(match.homeRedCards ?? 0), "cartões vermelhos da casa"],
            [payload.awayRedCardPlayers.length, Number(match.awayRedCards ?? 0), "cartões vermelhos do visitante"],
            [payload.homeBlueCardPlayers.length, Number(match.homeBlueCards ?? 0), "cartões azuis da casa"],
            [payload.awayBlueCardPlayers.length, Number(match.awayBlueCards ?? 0), "cartões azuis do visitante"],
          ];

          if (!supportsCards && disciplineChecks.some(([actual]) => actual > 0)) {
            throw new ApiError(422, "INVALID_SCORE_SHEET", "Esta modalidade não utiliza cartões.");
          }
          if (supportsCards) {
            const mismatch = disciplineChecks.find(([actual, expected]) => actual !== expected);
            if (mismatch) {
              throw new ApiError(
                422,
                "INVALID_SCORE_SHEET",
                `A quantidade de ${mismatch[2]} precisa corresponder à súmula.`,
              );
            }
          }

          const baseScope = {
            championshipId: String(match.championshipId),
            seasonYear: Number(match.seasonYear),
            sportId: String(match.sportId),
            naipe: String(match.naipe),
            division: match.division == null ? null : String(match.division),
          };
          const resolveSelections = async (
            selections: ScoreSheetSelectionInput[],
            teamId: string,
          ) =>
            Promise.all(
              selections.map((selection) =>
                resolveScoreSheetPlayerId(transaction, selection, { ...baseScope, teamId }),
              ),
            );

          const [
            homeGoals,
            awayGoals,
            homeYellow,
            awayYellow,
            homeRed,
            awayRed,
            homeBlue,
            awayBlue,
          ] = await Promise.all([
            resolveSelections(payload.homeGoalScorers, String(match.homeTeamId)),
            resolveSelections(payload.awayGoalScorers, String(match.awayTeamId)),
            resolveSelections(payload.homeYellowCardPlayers, String(match.homeTeamId)),
            resolveSelections(payload.awayYellowCardPlayers, String(match.awayTeamId)),
            resolveSelections(payload.homeRedCardPlayers, String(match.homeTeamId)),
            resolveSelections(payload.awayRedCardPlayers, String(match.awayTeamId)),
            resolveSelections(payload.homeBlueCardPlayers, String(match.homeTeamId)),
            resolveSelections(payload.awayBlueCardPlayers, String(match.awayTeamId)),
          ]);

          await Promise.all([
            transaction.query("DELETE FROM public.match_award_goal_scorers WHERE match_id = $1", [matchId]),
            transaction.query("DELETE FROM public.match_yellow_card_players WHERE match_id = $1", [matchId]),
            transaction.query("DELETE FROM public.match_red_card_players WHERE match_id = $1", [matchId]),
            transaction.query("DELETE FROM public.match_blue_card_players WHERE match_id = $1", [matchId]),
          ]);

          const insertOrdered = async (
            table: string,
            orderColumn: string,
            teamId: string,
            playerIds: string[],
          ) => {
            for (const [index, playerId] of playerIds.entries()) {
              await transaction.query(
                `INSERT INTO public.${table} (match_id, team_id, player_id, ${orderColumn})
                 VALUES ($1, $2, $3, $4)`,
                [matchId, teamId, playerId, index + 1],
              );
            }
          };

          await insertOrdered("match_award_goal_scorers", "goal_order", String(match.homeTeamId), homeGoals);
          await insertOrdered("match_award_goal_scorers", "goal_order", String(match.awayTeamId), awayGoals);
          await insertOrdered("match_yellow_card_players", "card_order", String(match.homeTeamId), homeYellow);
          await insertOrdered("match_yellow_card_players", "card_order", String(match.awayTeamId), awayYellow);
          await insertOrdered("match_red_card_players", "card_order", String(match.homeTeamId), homeRed);
          await insertOrdered("match_red_card_players", "card_order", String(match.awayTeamId), awayRed);
          await insertOrdered("match_blue_card_players", "card_order", String(match.homeTeamId), homeBlue);
          await insertOrdered("match_blue_card_players", "card_order", String(match.awayTeamId), awayBlue);

          await transaction.query(
            "UPDATE public.matches SET is_score_sheet_reviewed = true, updated_at = now() WHERE id = $1",
            [matchId],
          );

          return { match_id: matchId, is_walkover: false, is_score_sheet_reviewed: true };
        });

        response.status(200).json({ data });
      } catch (error) {
        next(error);
      }
    },
  );

  router.patch(
    "/score-sheet-review-state",
    ...requireScoreSheetReviewEdit,
    async (request, response, next) => {
      try {
        const payload = requireRecord(request.body);
        if (!Array.isArray(payload.matchIds) || payload.matchIds.length === 0) {
          throw new ApiError(422, "VALIDATION_ERROR", "Informe ao menos um jogo.");
        }
        if (payload.matchIds.length > 500) {
          throw new ApiError(422, "VALIDATION_ERROR", "O limite é de 500 jogos por atualização.");
        }
        const matchIds = payload.matchIds.map((matchId, index) =>
          requireUuid(matchId, `matchIds[${index}]`),
        );
        if (typeof payload.reviewed !== "boolean") {
          throw new ApiError(422, "VALIDATION_ERROR", "O campo reviewed deve ser booleano.");
        }

        const result = await database.query(
          `UPDATE public.matches
           SET is_score_sheet_reviewed = $1, updated_at = now()
           WHERE id = ANY($2::uuid[])
           RETURNING id`,
          [payload.reviewed, matchIds],
        );

        response.status(200).json({
          data: {
            updatedMatchIds: result.rows.map((row) => String(row.id)),
            reviewed: payload.reviewed,
          },
        });
      } catch (error) {
        next(error);
      }
    },
  );

  router.get("/", async (request, response, next) => {
    try {
      const filters = parseMatchFilters(request);
      const { statement, parameters } = buildListStatement(filters);
      const result = await database.query(statement, parameters);
      const total = Number(result.rows[0]?.totalCount ?? 0);
      const data = result.rows.map(({ totalCount: _totalCount, ...row }) => row);
      response.status(200).json({
        data,
        meta: {
          page: filters.page,
          pageSize: filters.pageSize,
          total,
          totalPages: Math.ceil(total / filters.pageSize),
        },
      });
    } catch (error) {
      next(error);
    }
  });

  router.get("/:matchId", async (request, response, next) => {
    try {
      const matchId = requireUuid(request.params.matchId, "matchId");
      const match = await getMatch(database, matchId);
      if (!match) {
        throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
      }
      response.status(200).json({ data: match });
    } catch (error) {
      next(error);
    }
  });

  router.post("/:matchId/start", ...requireControlEdit, async (request, response, next) => {
    try {
      const matchId = requireUuid(request.params.matchId, "matchId");
      const updated = await database.transaction(async (transaction) => {
        const oldMatch = await getMatch(transaction, matchId);
        if (!oldMatch) {
          throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        }
        if (oldMatch.status !== "SCHEDULED") {
          throw new ApiError(
            409,
            "MATCH_STATE_CONFLICT",
            "Somente jogos agendados podem ser iniciados.",
          );
        }
        const result = await transaction.query(
          `UPDATE public.matches
             SET status = 'LIVE', start_time = COALESCE(start_time, now()), updated_at = now()
             WHERE id = $1 AND status = 'SCHEDULED'
             RETURNING id`,
          [matchId],
        );
        if (result.rows.length === 0) {
          throw new ApiError(409, "MATCH_UPDATE_CONFLICT", "O jogo foi alterado concorrentemente.");
        }
        const newMatch = await getMatch(transaction, matchId);
        if (!newMatch) {
          throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        }
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          matchId,
          "Jogo iniciado via laje-api.",
          oldMatch,
          newMatch,
        );
        return newMatch;
      });
      response.status(200).json({ data: updated });
    } catch (error) {
      next(error);
    }
  });

  router.patch("/:matchId/scoreboard", ...requireControlEdit, async (request, response, next) => {
    try {
      const matchId = requireUuid(request.params.matchId, "matchId");
      const payload = parseScoreboardPayload(request.body);
      const updated = await database.transaction(async (transaction) => {
        const oldMatch = await getMatch(transaction, matchId);
        if (!oldMatch) {
          throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        }
        if (oldMatch.status !== "LIVE") {
          throw new ApiError(
            409,
            "MATCH_STATE_CONFLICT",
            "O placar operacional só pode ser alterado enquanto o jogo estiver ao vivo.",
          );
        }
        await persistScoreboardPatch(transaction, matchId, payload.patch, "LIVE");
        await persistMatchSets(transaction, matchId, payload.sets);
        const newMatch = await getMatch(transaction, matchId);
        if (!newMatch) {
          throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        }
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          matchId,
          "Placar atualizado via laje-api.",
          oldMatch,
          newMatch,
        );
        return newMatch;
      });
      response.status(200).json({ data: updated });
    } catch (error) {
      next(error);
    }
  });

  router.post("/:matchId/finish", ...requireControlEdit, async (request, response, next) => {
    try {
      const matchId = requireUuid(request.params.matchId, "matchId");
      const rawPayload = request.body == null ? {} : requireRecord(request.body);
      const scoreboardPayload = Object.fromEntries(
        Object.entries(rawPayload).filter(
          ([key]) =>
            ![
              "isWalkover",
              "walkoverLoserTeamId",
              "isDoubleWalkover",
              "resolvedTieBreakerRule",
              "resolvedTieBreakWinnerTeamId",
            ].includes(key),
        ),
      );
      const scoreboard = parseScoreboardPayload(scoreboardPayload, false);
      const isWalkover = optionalBoolean(rawPayload.isWalkover, "isWalkover");
      const isDoubleWalkover = optionalBoolean(rawPayload.isDoubleWalkover, "isDoubleWalkover");
      const walkoverLoserTeamId =
        rawPayload.walkoverLoserTeamId === null
          ? null
          : optionalUuid(rawPayload.walkoverLoserTeamId, "walkoverLoserTeamId");
      const resolvedTieBreakerRule =
        rawPayload.resolvedTieBreakerRule === null
          ? null
          : optionalString(rawPayload.resolvedTieBreakerRule, "resolvedTieBreakerRule", 80);
      const resolvedTieBreakWinnerTeamId =
        rawPayload.resolvedTieBreakWinnerTeamId === null
          ? null
          : optionalUuid(rawPayload.resolvedTieBreakWinnerTeamId, "resolvedTieBreakWinnerTeamId");

      const updated = await database.transaction(async (transaction) => {
        const oldMatch = await getMatch(transaction, matchId);
        if (!oldMatch) {
          throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        }
        const isScheduledWalkover = oldMatch.status === "SCHEDULED" && isWalkover === true;
        if (oldMatch.status !== "LIVE" && !isScheduledWalkover) {
          throw new ApiError(
            409,
            "MATCH_STATE_CONFLICT",
            "Somente jogos ao vivo podem ser encerrados.",
          );
        }

        await persistScoreboardPatch(
          transaction,
          matchId,
          scoreboard.patch,
          oldMatch.status === "SCHEDULED" ? "SCHEDULED" : "LIVE",
        );
        await persistMatchSets(transaction, matchId, scoreboard.sets);

        const assignments = [
          "status = 'FINISHED'",
          oldMatch.status === "SCHEDULED"
            ? "start_time = COALESCE(start_time, now())"
            : "end_time = COALESCE(end_time, now())",
          "updated_at = now()",
        ];
        const parameters: unknown[] = [matchId];
        if (isWalkover !== undefined) {
          parameters.push(isWalkover);
          assignments.push(`is_walkover = $${parameters.length}`);
        }
        if (isDoubleWalkover !== undefined) {
          parameters.push(isDoubleWalkover);
          assignments.push(`is_double_walkover = $${parameters.length}`);
        }
        if (walkoverLoserTeamId !== undefined || rawPayload.walkoverLoserTeamId === null) {
          parameters.push(walkoverLoserTeamId ?? null);
          assignments.push(`walkover_loser_team_id = $${parameters.length}`);
        }
        if (resolvedTieBreakerRule !== undefined || rawPayload.resolvedTieBreakerRule === null) {
          parameters.push(resolvedTieBreakerRule ?? null);
          assignments.push(`resolved_tie_breaker_rule = $${parameters.length}`);
        }
        if (
          resolvedTieBreakWinnerTeamId !== undefined ||
          rawPayload.resolvedTieBreakWinnerTeamId === null
        ) {
          parameters.push(resolvedTieBreakWinnerTeamId ?? null);
          assignments.push(`resolved_tie_break_winner_team_id = $${parameters.length}`);
        }
        const finishResult = await transaction.query(
          `UPDATE public.matches SET ${assignments.join(", ")}
             WHERE id = $1 AND status = $${parameters.length + 1}::public.match_status RETURNING id`,
          [...parameters, oldMatch.status],
        );
        if (finishResult.rows.length === 0) {
          throw new ApiError(409, "MATCH_UPDATE_CONFLICT", "O jogo foi alterado concorrentemente.");
        }

        const newMatch = await getMatch(transaction, matchId);
        if (!newMatch) {
          throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
        }

        await recalculateCollectiveStandings(transaction, {
          championshipId: String(newMatch.championshipId),
          seasonYear: Number(newMatch.seasonYear),
          sportId: String(newMatch.sportId),
          naipe: String(newMatch.naipe),
          division: typeof newMatch.division == "string" ? newMatch.division : null,
        });

        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          matchId,
          "Jogo encerrado e classificação consolidada via laje-api.",
          oldMatch,
          newMatch,
        );
        return newMatch;
      });
      response.status(200).json({ data: updated });
    } catch (error) {
      next(error);
    }
  });

  router.post(
    "/:matchId/return-to-scheduled",
    ...requireControlEdit,
    async (request, response, next) => {
      try {
        const matchId = requireUuid(request.params.matchId, "matchId");
        const updated = await database.transaction(async (transaction) => {
          const oldMatch = await getMatch(transaction, matchId);
          if (!oldMatch) {
            throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
          }
          if (oldMatch.status === "SCHEDULED") {
            throw new ApiError(409, "MATCH_STATE_CONFLICT", "O jogo já está agendado.");
          }

          const result = await transaction.query(
            `UPDATE public.matches SET
              status = 'SCHEDULED',
              scheduled_start_time = COALESCE(scheduled_start_time, start_time),
              start_time = NULL,
              end_time = NULL,
              home_score = 0,
              away_score = 0,
              current_set_home_score = NULL,
              current_set_away_score = NULL,
              home_yellow_cards = 0,
              home_red_cards = 0,
              home_blue_cards = 0,
              home_two_minute_penalties = 0,
              away_yellow_cards = 0,
              away_red_cards = 0,
              away_blue_cards = 0,
              away_two_minute_penalties = 0,
              home_penalty_score = NULL,
              away_penalty_score = NULL,
              resolved_tie_breaker_rule = NULL,
              resolved_tie_break_winner_team_id = NULL,
              is_walkover = false,
              is_double_walkover = false,
              walkover_loser_team_id = NULL,
              updated_at = now()
             WHERE id = $1 AND status = $2::public.match_status
             RETURNING id`,
            [matchId, oldMatch.status],
          );
          if (result.rows.length === 0) {
            throw new ApiError(
              409,
              "MATCH_UPDATE_CONFLICT",
              "O jogo foi alterado concorrentemente.",
            );
          }

          await transaction.query("DELETE FROM public.match_sets WHERE match_id = $1", [matchId]);

          const newMatch = await getMatch(transaction, matchId);
          if (!newMatch) {
            throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
          }
          await recalculateCollectiveStandings(transaction, {
            championshipId: String(newMatch.championshipId),
            seasonYear: Number(newMatch.seasonYear),
            sportId: String(newMatch.sportId),
            naipe: String(newMatch.naipe),
            division: typeof newMatch.division == "string" ? newMatch.division : null,
          });
          await insertAudit(
            transaction,
            request as AuthenticatedRequest,
            matchId,
            "Jogo retornado ao agendamento via laje-api.",
            oldMatch,
            newMatch,
          );
          return newMatch;
        });
        response.status(200).json({ data: updated });
      } catch (error) {
        next(error);
      }
    },
  );

  return router;
}
