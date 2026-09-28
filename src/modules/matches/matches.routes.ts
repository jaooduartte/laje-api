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
  const statuses = rawStatuses?.map((status) =>
    optionalEnum(status, "status", MATCH_STATUSES),
  );
  const rawMatchIds = readQueryValues(query.matchId ?? query.matchIds);
  const matchIds = rawMatchIds?.map((id) => requireUuid(id, "matchId"));
  const sort =
    optionalEnum(
      query.sort,
      "sort",
      ["scheduledDate", "queuePosition", "createdAt"] as const,
    ) ?? "scheduledDate";
  const order =
    optionalEnum(query.order, "order", ["asc", "desc"] as const) ?? "asc";
  const from = parseDate(query.from, "from");
  const to = parseDate(query.to, "to");
  if (from && to && from > to) {
    throw new ApiError(
      422,
      "VALIDATION_ERROR",
      "O filtro from não pode ser posterior a to.",
    );
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

function nullableNonNegativeInteger(
  value: unknown,
  field: string,
): number | null | undefined {
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
  if (
    sets &&
    sets.length > 0 &&
    patch.homeScore === undefined &&
    patch.awayScore === undefined
  ) {
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
  const result = await executor.query(
    `SELECT ${MATCH_COLUMNS}${MATCH_FROM} WHERE m.id = $1`,
    [matchId],
  );
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
    add(
      (parameter) => `m.status = ANY(${parameter}::public.match_status[])`,
      filters.statuses,
    );
  }
  if (filters.sportId) {
    add((parameter) => `m.sport_id = ${parameter}`, filters.sportId);
  }
  if (filters.teamId) {
    add(
      (parameter) =>
        `(m.home_team_id = ${parameter}::uuid OR m.away_team_id = ${parameter}::uuid)`,
      filters.teamId,
    );
  }
  if (filters.naipe) {
    add(
      (parameter) => `m.naipe = ${parameter}::public.match_naipe`,
      filters.naipe,
    );
  }
  if (filters.division) {
    add(
      (parameter) => `m.division = ${parameter}::public.team_division`,
      filters.division,
    );
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
  expectedStatus: "LIVE",
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
    throw new ApiError(
      409,
      "MATCH_UPDATE_CONFLICT",
      "O jogo foi alterado concorrentemente.",
    );
  }
}

export function createMatchesRouter(authService: AuthService): Router {
  const router = Router();
  const requireAuthentication = createRequireAuthentication(authService);
  const requireControlEdit = [
    requireAuthentication,
    requirePermission("control", "EDIT"),
  ] as const;

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

  router.post(
    "/:matchId/start",
    ...requireControlEdit,
    async (request, response, next) => {
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
            throw new ApiError(
              409,
              "MATCH_UPDATE_CONFLICT",
              "O jogo foi alterado concorrentemente.",
            );
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
    },
  );

  router.patch(
    "/:matchId/scoreboard",
    ...requireControlEdit,
    async (request, response, next) => {
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
          await persistScoreboardPatch(
            transaction,
            matchId,
            payload.patch,
            "LIVE",
          );
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
    },
  );

  router.post(
    "/:matchId/finish",
    ...requireControlEdit,
    async (request, response, next) => {
      try {
        const matchId = requireUuid(request.params.matchId, "matchId");
        const rawPayload = request.body == null ? {} : requireRecord(request.body);
        const scoreboardPayload = Object.fromEntries(
          Object.entries(rawPayload).filter(
            ([key]) =>
              !["isWalkover", "walkoverLoserTeamId", "isDoubleWalkover"].includes(
                key,
              ),
          ),
        );
        const scoreboard = parseScoreboardPayload(scoreboardPayload, false);
        const isWalkover = optionalBoolean(rawPayload.isWalkover, "isWalkover");
        const isDoubleWalkover = optionalBoolean(
          rawPayload.isDoubleWalkover,
          "isDoubleWalkover",
        );
        const walkoverLoserTeamId =
          rawPayload.walkoverLoserTeamId === null
            ? null
            : optionalUuid(rawPayload.walkoverLoserTeamId, "walkoverLoserTeamId");

        const updated = await database.transaction(async (transaction) => {
          const oldMatch = await getMatch(transaction, matchId);
          if (!oldMatch) {
            throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
          }
          if (oldMatch.status !== "LIVE") {
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
            "LIVE",
          );
          await persistMatchSets(transaction, matchId, scoreboard.sets);

          const assignments = [
            "status = 'FINISHED'",
            "end_time = COALESCE(end_time, now())",
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
          if (
            walkoverLoserTeamId !== undefined ||
            rawPayload.walkoverLoserTeamId === null
          ) {
            parameters.push(walkoverLoserTeamId ?? null);
            assignments.push(`walkover_loser_team_id = $${parameters.length}`);
          }
          const finishResult = await transaction.query(
            `UPDATE public.matches SET ${assignments.join(", ")}
             WHERE id = $1 AND status = 'LIVE' RETURNING id`,
            parameters,
          );
          if (finishResult.rows.length === 0) {
            throw new ApiError(
              409,
              "MATCH_UPDATE_CONFLICT",
              "O jogo foi alterado concorrentemente.",
            );
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
            division:
              typeof newMatch.division == "string" ? newMatch.division : null,
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
    },
  );

  return router;
}
