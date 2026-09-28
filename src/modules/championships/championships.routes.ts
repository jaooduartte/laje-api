import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import {
  optionalBoolean,
  optionalEnum,
  optionalInteger,
  optionalString,
  optionalUuid,
  parseDate,
  parsePagination,
  requireEnum,
  requireInteger,
  requireRecord,
  requireString,
  requireUuid,
} from "../../common/validation/common.schema.js";
import { database } from "../../database/index.js";
import type { DatabaseQueryExecutor, DatabaseRow } from "../../database/types.js";
import { createRequireAuthentication, requirePermission, type AuthenticatedRequest } from "../auth/auth.middleware.js";
import type { AuthService } from "../auth/auth.service.js";
import { createBracketRouter } from "../brackets/brackets.routes.js";
import { createStandingsRouter } from "../standings/standings.routes.js";

const CHAMPIONSHIP_CODES = ["CLV", "SOCIETY", "INTERLAJE"] as const;
const CHAMPIONSHIP_STATUSES = ["PLANNING", "UPCOMING", "REVIEW", "IN_PROGRESS", "FINISHED"] as const;
const DIVISION_FORMATS = ["SEPARATED", "UNIFIED"] as const;
const SETTLEMENT_MODES = ["NONE", "PROMOTION_RELEGATION", "TOP_N_TO_PRINCIPAL"] as const;
const MATCH_NAIPES = ["MASCULINO", "FEMININO", "MISTO"] as const;
const TEAM_DIVISIONS = ["DIVISAO_PRINCIPAL", "DIVISAO_ACESSO"] as const;

const CHAMPIONSHIP_SELECT = `SELECT id, code, name, status, current_season_year AS "currentSeasonYear", uses_divisions AS "usesDivisions", default_location AS "defaultLocation", created_at::text AS "createdAt" FROM public.championships`;

async function getChampionship(executor: DatabaseQueryExecutor, championshipId: string) {
  const result = await executor.query(`${CHAMPIONSHIP_SELECT} WHERE id = $1`, [championshipId]);
  return result.rows[0] ?? null;
}

async function insertAudit(
  executor: DatabaseQueryExecutor,
  request: AuthenticatedRequest,
  actionType: "INSERT" | "UPDATE",
  resourceTable: string,
  recordId: string,
  description: string,
  oldData: DatabaseRow | null,
  newData: DatabaseRow,
): Promise<void> {
  const principal = request.authPrincipal;
  await executor.query(
    `INSERT INTO public.admin_action_logs
      (actor_user_id, actor_email, actor_role, action_type, resource_table, record_id, description, old_data, new_data, metadata, actor_name)
     VALUES ($1, $2, $3::public.app_role, $4::public.admin_action_type, $5, $6, $7, $8::jsonb, $9::jsonb, '{"source":"laje-api","task":"LAJE-86"}'::jsonb, $10)`,
    [
      principal?.userId ?? null,
      principal?.user.email ?? null,
      principal?.user.role ?? null,
      actionType,
      resourceTable,
      recordId,
      description,
      oldData ? JSON.stringify(oldData) : null,
      JSON.stringify(newData),
      principal?.user.profile?.name ?? null,
    ],
  );
}

function parseChampionshipCreate(body: unknown) {
  const payload = requireRecord(body);
  return {
    code: requireEnum(payload.code, "code", CHAMPIONSHIP_CODES),
    name: requireString(payload.name, "name", 160),
    status: optionalEnum(payload.status, "status", CHAMPIONSHIP_STATUSES) ?? "UPCOMING",
    currentSeasonYear: optionalInteger(payload.currentSeasonYear, "currentSeasonYear", { min: 2000, max: 2100 }) ?? new Date().getFullYear(),
    usesDivisions: optionalBoolean(payload.usesDivisions, "usesDivisions") ?? false,
    defaultLocation: payload.defaultLocation === null ? null : optionalString(payload.defaultLocation, "defaultLocation", 255) ?? null,
  };
}

function parseSeasonSettings(body: unknown, championshipId: string, seasonYear: number) {
  const payload = requireRecord(body);
  return {
    championshipId,
    seasonYear,
    divisionFormat: optionalEnum(payload.divisionFormat, "divisionFormat", DIVISION_FORMATS) ?? "UNIFIED",
    divisionSettlementMode: optionalEnum(payload.divisionSettlementMode, "divisionSettlementMode", SETTLEMENT_MODES) ?? "NONE",
    principalSlotsCount: payload.principalSlotsCount === null ? null : optionalInteger(payload.principalSlotsCount, "principalSlotsCount", { min: 1, max: 100 }) ?? null,
    principalRelegationCount: payload.principalRelegationCount === null ? null : optionalInteger(payload.principalRelegationCount, "principalRelegationCount", { min: 0, max: 100 }) ?? null,
    accessPromotionCount: payload.accessPromotionCount === null ? null : optionalInteger(payload.accessPromotionCount, "accessPromotionCount", { min: 0, max: 100 }) ?? null,
    yellowCardResetPhase: optionalString(payload.yellowCardResetPhase, "yellowCardResetPhase", 80) ?? "NONE",
  };
}

export function createChampionshipsRouter(authService: AuthService): Router {
  const router = Router();
  const requireAuthentication = createRequireAuthentication(authService);
  const requireSettingsEdit = [requireAuthentication, requirePermission("settings", "EDIT")] as const;

  router.get("/", async (request, response, next) => {
    try {
      const status = optionalEnum(request.query.status, "status", CHAMPIONSHIP_STATUSES);
      const code = optionalEnum(request.query.code, "code", CHAMPIONSHIP_CODES);
      const parameters: unknown[] = [];
      const conditions: string[] = [];
      if (status) { parameters.push(status); conditions.push(`status = $${parameters.length}::public.championship_status`); }
      if (code) { parameters.push(code); conditions.push(`code = $${parameters.length}::public.championship_code`); }
      const where = conditions.length > 0 ? ` WHERE ${conditions.join(" AND ")}` : "";
      const result = await database.query(`${CHAMPIONSHIP_SELECT}${where} ORDER BY CASE code WHEN 'CLV' THEN 1 WHEN 'SOCIETY' THEN 2 WHEN 'INTERLAJE' THEN 3 ELSE 4 END, name`, parameters);
      response.status(200).json({ data: result.rows });
    } catch (error) { next(error); }
  });

  router.post("/", ...requireSettingsEdit, async (request, response, next) => {
    try {
      const input = parseChampionshipCreate(request.body);
      const championship = await database.transaction(async (tx) => {
        const result = await tx.query(
          `INSERT INTO public.championships (code, name, status, current_season_year, uses_divisions, default_location)
           VALUES ($1::public.championship_code, $2, $3::public.championship_status, $4, $5, $6)
           RETURNING id, code, name, status, current_season_year AS "currentSeasonYear", uses_divisions AS "usesDivisions", default_location AS "defaultLocation", created_at::text AS "createdAt"`,
          [input.code, input.name, input.status, input.currentSeasonYear, input.usesDivisions, input.defaultLocation],
        );
        const created = result.rows[0]!;
        await insertAudit(tx, request as AuthenticatedRequest, "INSERT", "championships", String(created.id), "Campeonato criado via laje-api.", null, created);
        return created;
      });
      response.status(201).json({ data: championship });
    } catch (error) { next(error); }
  });

  router.get("/:championshipId", async (request, response, next) => {
    try {
      const championshipId = requireUuid(request.params.championshipId, "championshipId");
      const championship = await getChampionship(database, championshipId);
      if (!championship) throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
      response.status(200).json({ data: championship });
    } catch (error) { next(error); }
  });

  router.patch("/:championshipId", ...requireSettingsEdit, async (request, response, next) => {
    try {
      const championshipId = requireUuid(request.params.championshipId, "championshipId");
      const payload = requireRecord(request.body);
      const updates: Array<{ column: string; value: unknown; cast?: string }> = [];
      if (payload.name !== undefined) updates.push({ column: "name", value: requireString(payload.name, "name", 160) });
      if (payload.status !== undefined) updates.push({ column: "status", value: requireEnum(payload.status, "status", CHAMPIONSHIP_STATUSES), cast: "public.championship_status" });
      if (payload.currentSeasonYear !== undefined) updates.push({ column: "current_season_year", value: requireInteger(payload.currentSeasonYear, "currentSeasonYear", { min: 2000, max: 2100 }) });
      if (payload.usesDivisions !== undefined) updates.push({ column: "uses_divisions", value: optionalBoolean(payload.usesDivisions, "usesDivisions") });
      if (payload.defaultLocation !== undefined) updates.push({ column: "default_location", value: payload.defaultLocation === null ? null : requireString(payload.defaultLocation, "defaultLocation", 255) });
      if (updates.length === 0) throw new ApiError(422, "VALIDATION_ERROR", "Informe ao menos um campo para atualização.");
      const championship = await database.transaction(async (tx) => {
        const oldRecord = await getChampionship(tx, championshipId);
        if (!oldRecord) throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
        const assignments = updates.map((update, index) => `${update.column} = $${index + 2}${update.cast ? `::${update.cast}` : ""}`);
        await tx.query(`UPDATE public.championships SET ${assignments.join(", ")} WHERE id = $1`, [championshipId, ...updates.map((update) => update.value)]);
        const newRecord = await getChampionship(tx, championshipId);
        if (!newRecord) throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado após atualização.");
        await insertAudit(tx, request as AuthenticatedRequest, "UPDATE", "championships", championshipId, "Campeonato atualizado via laje-api.", oldRecord, newRecord);
        return newRecord;
      });
      response.status(200).json({ data: championship });
    } catch (error) { next(error); }
  });

  router.get("/:championshipId/seasons/:seasonYear", async (request, response, next) => {
    try {
      const championshipId = requireUuid(request.params.championshipId, "championshipId");
      const seasonYear = requireInteger(request.params.seasonYear, "seasonYear", { min: 2000, max: 2100 });
      if (!(await getChampionship(database, championshipId))) throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
      const result = await database.query(
        `SELECT id, championship_id AS "championshipId", season_year AS "seasonYear", division_format AS "divisionFormat",
          division_settlement_mode AS "divisionSettlementMode", principal_slots_count AS "principalSlotsCount",
          principal_relegation_count AS "principalRelegationCount", access_promotion_count AS "accessPromotionCount",
          yellow_card_reset_phase AS "yellowCardResetPhase", created_at::text AS "createdAt", updated_at::text AS "updatedAt"
         FROM public.championship_season_settings WHERE championship_id = $1 AND season_year = $2`,
        [championshipId, seasonYear],
      );
      response.status(200).json({ data: result.rows[0] ?? null });
    } catch (error) { next(error); }
  });

  router.put("/:championshipId/seasons/:seasonYear", ...requireSettingsEdit, async (request, response, next) => {
    try {
      const championshipId = requireUuid(request.params.championshipId, "championshipId");
      const seasonYear = requireInteger(request.params.seasonYear, "seasonYear", { min: 2000, max: 2100 });
      const input = parseSeasonSettings(request.body, championshipId, seasonYear);
      if (!(await getChampionship(database, championshipId))) throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
      const result = await database.transaction(async (tx) => {
        const previous = await tx.query("SELECT * FROM public.championship_season_settings WHERE championship_id = $1 AND season_year = $2", [championshipId, seasonYear]);
        const upserted = await tx.query(
          `INSERT INTO public.championship_season_settings
            (championship_id, season_year, division_format, division_settlement_mode, principal_slots_count, principal_relegation_count, access_promotion_count, yellow_card_reset_phase)
           VALUES ($1, $2, $3::public.championship_season_division_format, $4::public.championship_season_division_settlement_mode, $5, $6, $7, $8)
           ON CONFLICT (championship_id, season_year) DO UPDATE SET
             division_format = EXCLUDED.division_format,
             division_settlement_mode = EXCLUDED.division_settlement_mode,
             principal_slots_count = EXCLUDED.principal_slots_count,
             principal_relegation_count = EXCLUDED.principal_relegation_count,
             access_promotion_count = EXCLUDED.access_promotion_count,
             yellow_card_reset_phase = EXCLUDED.yellow_card_reset_phase,
             updated_at = now()
           RETURNING id, championship_id AS "championshipId", season_year AS "seasonYear", division_format AS "divisionFormat",
             division_settlement_mode AS "divisionSettlementMode", principal_slots_count AS "principalSlotsCount",
             principal_relegation_count AS "principalRelegationCount", access_promotion_count AS "accessPromotionCount",
             yellow_card_reset_phase AS "yellowCardResetPhase", created_at::text AS "createdAt", updated_at::text AS "updatedAt"`,
          [input.championshipId, input.seasonYear, input.divisionFormat, input.divisionSettlementMode, input.principalSlotsCount, input.principalRelegationCount, input.accessPromotionCount, input.yellowCardResetPhase],
        );
        const row = upserted.rows[0]!;
        await insertAudit(tx, request as AuthenticatedRequest, previous.rows[0] ? "UPDATE" : "INSERT", "championship_season_settings", String(row.id), "Configuração de temporada persistida via laje-api.", previous.rows[0] ?? null, row);
        return row;
      });
      response.status(200).json({ data: result });
    } catch (error) { next(error); }
  });

  router.get("/:championshipId/calendar", async (request, response, next) => {
    try {
      const championshipId = requireUuid(request.params.championshipId, "championshipId");
      const seasonYear = requireInteger(request.query.seasonYear, "seasonYear", { min: 2000, max: 2100 });
      const sportId = optionalUuid(request.query.sportId, "sportId");
      const teamId = optionalUuid(request.query.teamId, "teamId");
      const naipe = optionalEnum(request.query.naipe, "naipe", MATCH_NAIPES);
      const division = optionalEnum(request.query.division, "division", TEAM_DIVISIONS);
      const from = parseDate(request.query.from, "from");
      const to = parseDate(request.query.to, "to");
      if (from && to && from > to) throw new ApiError(422, "VALIDATION_ERROR", "O filtro from não pode ser posterior a to.");
      const { page, pageSize, offset } = parsePagination(request.query as Record<string, unknown>);
      if (!(await getChampionship(database, championshipId))) throw new ApiError(404, "CHAMPIONSHIP_NOT_FOUND", "Campeonato não encontrado.");
      const parameters: unknown[] = [championshipId, seasonYear];
      const conditions = ["m.championship_id = $1", "m.season_year = $2"];
      if (sportId) { parameters.push(sportId); conditions.push(`m.sport_id = $${parameters.length}`); }
      if (teamId) { parameters.push(teamId, teamId); conditions.push(`(m.home_team_id = $${parameters.length - 1} OR m.away_team_id = $${parameters.length})`); }
      if (naipe) { parameters.push(naipe); conditions.push(`m.naipe = $${parameters.length}::public.match_naipe`); }
      if (division) { parameters.push(division); conditions.push(`m.division = $${parameters.length}::public.team_division`); }
      if (from) { parameters.push(from); conditions.push(`m.scheduled_date >= $${parameters.length}::date`); }
      if (to) { parameters.push(to); conditions.push(`m.scheduled_date <= $${parameters.length}::date`); }
      parameters.push(pageSize, offset);
      const result = await database.query(
        `SELECT m.id, m.championship_id AS "championshipId", m.season_year AS "seasonYear", m.sport_id AS "sportId", s.name AS "sportName",
          m.naipe, m.division, m.status, m.scheduled_date::text AS "scheduledDate", m.queue_position AS "queuePosition", m.scheduled_slot AS "scheduledSlot",
          m.scheduled_start_time::text AS "scheduledStartTime", m.start_time::text AS "startTime", m.end_time::text AS "endTime", m.location, m.court_name AS "courtName",
          m.home_team_id AS "homeTeamId", ht.name AS "homeTeamName", m.away_team_id AS "awayTeamId", at.name AS "awayTeamName",
          m.home_score AS "homeScore", m.away_score AS "awayScore", count(*) OVER()::int AS "totalCount"
         FROM public.matches m JOIN public.sports s ON s.id = m.sport_id JOIN public.teams ht ON ht.id = m.home_team_id JOIN public.teams at ON at.id = m.away_team_id
         WHERE ${conditions.join(" AND ")}
         ORDER BY m.scheduled_date ASC NULLS LAST, m.queue_position ASC NULLS LAST, m.scheduled_start_time ASC NULLS LAST, m.id ASC
         LIMIT $${parameters.length - 1} OFFSET $${parameters.length}`,
        parameters,
      );
      const total = Number(result.rows[0]?.totalCount ?? 0);
      response.status(200).json({ data: result.rows.map(({ totalCount: _totalCount, ...row }) => row), meta: { page, pageSize, total, totalPages: Math.ceil(total / pageSize) } });
    } catch (error) { next(error); }
  });

  router.use("/:championshipId/standings", createStandingsRouter());
  router.use("/:championshipId/bracket", createBracketRouter(authService));

  return router;
}
