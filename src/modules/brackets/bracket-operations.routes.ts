import { Router } from "express";
import { rateLimit } from "express-rate-limit";

import { ApiError } from "../../common/errors/api-error.js";
import { createPostgresRateLimitOptions } from "../../common/middlewares/rate-limit.middleware.js";
import { requireInteger, requireRecord, requireUuid } from "../../common/validation/common.schema.js";
import { database } from "../../database/index.js";
import {
  createRequireAuthentication,
  requirePermission,
  type AuthenticatedRequest,
} from "../auth/auth.middleware.js";
import type { AuthService } from "../auth/auth.service.js";

type RouteSpec = {
  scope: "edition" | "source" | "competition" | "match" | "tie-break" | "standings";
  sql: string;
  parameterKind?: "json" | "revision" | "array" | "none";
};


/**
 * Read-only, schema-scoped projection of the championship's saved court hierarchy.
 * The same JSON shape is used by the original Supabase relationships so the
 * business mapping in the AWS frontend does not drift from the operational app.
 */
const BRACKET_DAYS_SOURCE_SQL = `
  COALESCE((
    SELECT jsonb_agg(
      jsonb_build_object(
        'id', d.id,
        'event_date', d.event_date,
        'championship_bracket_locations', COALESCE((
          SELECT jsonb_agg(
            jsonb_build_object(
              'id', l.id,
              'name', l.name,
              'position', l.position,
              'location_group_id', l.location_group_id,
              'championship_bracket_courts', COALESCE((
                SELECT jsonb_agg(
                  jsonb_build_object(
                    'id', c.id,
                    'name', c.name,
                    'position', c.position,
                    'court_group_id', c.court_group_id,
                    'preferred_sport_id', c.preferred_sport_id,
                    'championship_bracket_court_sports', COALESCE((
                      SELECT jsonb_agg(
                        jsonb_build_object(
                          'sport_id', cs.sport_id,
                          'preferred_naipe', cs.preferred_naipe,
                          'preferred_division', cs.preferred_division,
                          'sequence_mode', cs.sequence_mode
                        ) ORDER BY cs.sport_id
                      )
                      FROM public.championship_bracket_court_sports cs
                      WHERE cs.bracket_court_id = c.id
                    ), '[]'::jsonb)
                  ) ORDER BY c.position
                )
                FROM public.championship_bracket_courts c
                WHERE c.bracket_location_id = l.id
              ), '[]'::jsonb)
            ) ORDER BY l.position
          )
          FROM public.championship_bracket_locations l
          WHERE l.bracket_day_id = d.id
        ), '[]'::jsonb)
      ) ORDER BY d.event_date
    )
    FROM public.championship_bracket_days d
    WHERE d.bracket_edition_id = $1::uuid
  ), '[]'::jsonb)
`;

/** Read-only operations are available to a user with matches VIEW permission. */
const VIEW_OPERATIONS = new Set([
  "generated-location-groups",
  "location-sport-source",
  "knockout-court-source",
  "knockout-adjustment-candidates",
  "editable-schedule-slots",
  "group-stage-standings",
]);

/** Every SQL expression below is a static allowlisted function, never a client-supplied identifier. */
const OPERATIONS: Record<string, RouteSpec> = {
  "manual-relocation-preview": {
    scope: "edition",
    sql: "SELECT public.preview_manual_match_relocation($1::uuid, $2::jsonb) AS result",
    parameterKind: "json",
  },
  "manual-relocation-apply": {
    scope: "edition",
    sql: "SELECT public.apply_manual_match_relocation($1::uuid, $2::jsonb, $3::bigint) AS result",
    parameterKind: "revision",
  },
  "manual-relocation-slot-preview": {
    scope: "edition",
    sql: "SELECT public.preview_manual_match_relocation_slot($1::uuid, $2::jsonb) AS result",
    parameterKind: "json",
  },
  "manual-relocation-slot-apply": {
    scope: "edition",
    sql: "SELECT public.apply_manual_match_relocation_slot($1::uuid, $2::jsonb, $3::bigint) AS result",
    parameterKind: "revision",
  },
  "manual-relocation-hold": {
    scope: "edition",
    sql: "SELECT public.hold_matches_for_manual_relocation($1::uuid, $2::jsonb) AS result",
    parameterKind: "json",
  },
  "day-reorganization-preview": {
    scope: "edition",
    sql: "SELECT public.preview_day_schedule_reorganization($1::uuid, $2::jsonb) AS result",
    parameterKind: "json",
  },
  "day-reorganization-apply": {
    scope: "edition",
    sql: "SELECT public.apply_day_schedule_reorganization($1::uuid, $2::jsonb, $3::bigint) AS result",
    parameterKind: "revision",
  },
  "interval-preview": {
    scope: "edition",
    sql: "SELECT public.preview_operational_schedule_interval($1::uuid, $2::jsonb) AS result",
    parameterKind: "json",
  },
  "interval-apply": {
    scope: "edition",
    sql: "SELECT public.apply_operational_schedule_interval($1::uuid, $2::jsonb, $3::bigint) AS result",
    parameterKind: "revision",
  },
  "knockout-adjustment-preview": {
    scope: "edition",
    sql: "SELECT public.preview_operational_knockout_schedule_adjustment($1::uuid, $2::jsonb) AS result",
    parameterKind: "json",
  },
  "knockout-adjustment-apply": {
    scope: "edition",
    sql: "SELECT public.apply_operational_knockout_schedule_adjustment($1::uuid, $2::jsonb, $3::bigint) AS result",
    parameterKind: "revision",
  },
  "bracket-day-update": {
    scope: "edition",
    sql: "SELECT public.update_bracket_day_schedule($1::uuid, $2::jsonb) AS result",
    parameterKind: "array",
  },
  "knockout-court-priorities-update": {
    scope: "edition",
    sql: "SELECT public.update_bracket_knockout_court_priorities($1::uuid, $2::jsonb) AS result",
    parameterKind: "array",
  },
  "location-sport-source": {
    scope: "edition",
    sql: `SELECT jsonb_build_object(
      'days', ${BRACKET_DAYS_SOURCE_SQL},
      'priorities', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'location_group_id', lp.location_group_id,
          'sport_id', lp.sport_id,
          'priority_mode', lp.priority_mode
        ))
        FROM public.championship_bracket_location_sport_priorities lp
        WHERE lp.bracket_edition_id = $1::uuid
      ), '[]'::jsonb),
      'bracketMatches', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'match_id', bm.match_id,
          'matches', jsonb_build_object(
            'scheduled_date', m.scheduled_date,
            'sport_id', m.sport_id
          )
        ))
        FROM public.championship_bracket_matches bm
        JOIN public.matches m ON m.id = bm.match_id
        WHERE bm.bracket_edition_id = $1::uuid
      ), '[]'::jsonb)
    ) AS result`,
  },
  "knockout-court-source": {
    scope: "edition",
    sql: `SELECT jsonb_build_object(
      'days', ${BRACKET_DAYS_SOURCE_SQL},
      'competitions', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('sport_id', c.sport_id, 'division', c.division))
        FROM public.championship_bracket_competitions c
        WHERE c.bracket_edition_id = $1::uuid
      ), '[]'::jsonb),
      'priorities', COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
          'sport_id', p.sport_id,
          'phase', p.phase,
          'division_scope', p.division_scope,
          'location_group_id', p.location_group_id,
          'court_group_id', p.court_group_id
        ))
        FROM public.championship_bracket_knockout_court_priorities p
        WHERE p.bracket_edition_id = $1::uuid
      ), '[]'::jsonb),
      'finalProgram', COALESCE((
        SELECT jsonb_agg(to_jsonb(fp))
        FROM public.get_championship_knockout_final_program_schedule($1::uuid) fp
      ), '[]'::jsonb)
    ) AS result`,
  },
  "generated-location-groups": {
    scope: "edition",
    sql: `WITH location_rows AS (
        SELECT DISTINCT ON (l.location_group_id)
               l.location_group_id, l.name, l.position
        FROM public.championship_bracket_days d
        JOIN public.championship_bracket_locations l ON l.bracket_day_id = d.id
        WHERE d.bracket_edition_id = $1
        ORDER BY l.location_group_id, d.event_date, l.position
      ), court_rows AS (
        SELECT DISTINCT ON (l.location_group_id, c.court_group_id)
               l.location_group_id, c.court_group_id, c.name, c.position
        FROM public.championship_bracket_days d
        JOIN public.championship_bracket_locations l ON l.bracket_day_id = d.id
        JOIN public.championship_bracket_courts c ON c.bracket_location_id = l.id
        WHERE d.bracket_edition_id = $1
        ORDER BY l.location_group_id, c.court_group_id, d.event_date, c.position
      )
      SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
          'location_group_id', l.location_group_id,
          'location_name', l.name,
          'position', l.position,
          'courts', COALESCE((
            SELECT jsonb_agg(
              jsonb_build_object(
                'court_group_id', c.court_group_id,
                'court_name', c.name,
                'position', c.position
              ) ORDER BY c.position
            )
            FROM court_rows c WHERE c.location_group_id = l.location_group_id
          ), '[]'::jsonb)
        ) ORDER BY l.position
      ), '[]'::jsonb) AS result FROM location_rows l`,
  },
  "generated-location-update": {
    scope: "edition",
    sql: "SELECT public.update_bracket_generated_location_group($1::uuid, $2::jsonb) AS result",
    parameterKind: "json",
  },
  "knockout-adjustment-candidates": {
    scope: "source",
    sql: "SELECT public.list_operational_knockout_schedule_adjustment_candidates($1::uuid) AS result",
  },
  "editable-schedule-slots": {
    scope: "match",
    sql: `SELECT to_jsonb(slot) AS result
      FROM public.list_editable_match_schedule_slots(
        $1::uuid, $2::date, $3::text, $4::text,
        $5::uuid, $6::public.match_naipe, $7::uuid, $8::uuid
      ) AS slot`,
  },
  "match-logistics-update": {
    scope: "match",
    sql: `SELECT public.update_scheduled_match_logistics(
      $1::uuid, $2::date, $3::text, $4::text, $5::timestamptz,
      $6::text, $7::uuid, $8::public.match_naipe, $9::uuid, $10::uuid
    ) AS result`,
  },
  "competition-settings-update": {
    scope: "competition",
    sql: `SELECT public.update_bracket_competition_settings(
      $1::uuid, $2::integer, $3::boolean, $4::text
    ) AS result`,
  },
  "knockout-teams-swap": {
    scope: "competition",
    sql: "SELECT public.swap_championship_knockout_bracket_teams($1::uuid, $2::uuid, $3::uuid) AS result",
  },
  "tie-break-save": {
    scope: "tie-break",
    sql: "SELECT public.save_championship_bracket_tie_break_resolution($1::jsonb) AS result",
    parameterKind: "json",
  },
  "knockout-generate": {
    scope: "standings",
    sql: `SELECT public.generate_championship_knockout_for_competition(
      $1::uuid, $2::uuid, $3::uuid
    ) AS result`,
  },
  "group-stage-standings": {
    scope: "standings",
    sql: `SELECT to_jsonb(s) AS result
      FROM public.get_championship_group_stage_qualification_display_metrics(
        $1::uuid, $2::integer
      ) AS s`,
  },
};

function uuidOrNull(value: unknown): string | null {
  return value == null ? null : requireUuid(value, "uuid");
}

function stringField(value: unknown, name: string): string {
  if (typeof value !== "string" || !value.trim()) {
    throw new ApiError(422, "VALIDATION_ERROR", `Informe ${name}.`);
  }
  return value.trim();
}

export function createBracketOperationsRouter(authService: AuthService): Router {
  const router = Router();
  const requireAuthentication = createRequireAuthentication(authService);
  router.post(
    "/:operation",
    rateLimit(createPostgresRateLimitOptions({ scope: "bracket-operations", maxRequests: 30, windowSeconds: 60 })),
    requireAuthentication,
    (request, response, next) => {
      const operation = String(request.params.operation ?? "");
      const required = VIEW_OPERATIONS.has(operation) ? "VIEW" : "EDIT";
      requirePermission("matches", required)(request, response, next);
    },
    async (request, response, next) => {
      try {
        const operation = String(request.params.operation ?? "");
        const spec = OPERATIONS[operation];
        if (!spec) throw new ApiError(404, "BRACKET_OPERATION_NOT_FOUND", "Operação não suportada.");
        const payload = requireRecord(request.body);
        const data = await database.transaction(async (tx) => {
          const userId = (request as AuthenticatedRequest).authPrincipal?.userId;
          if (!userId) throw new ApiError(401, "ACCESS_TOKEN_REQUIRED", "Autenticação obrigatória.");
          await tx.query("SELECT set_config('laje.request_user_id', $1, true)", [userId]);

          const input = payload.input;
          let values: unknown[];
          if (spec.scope === "edition") {
            const id = requireUuid(payload.editionId, "editionId");
            const edition = await tx.query(
              "SELECT id FROM public.championship_bracket_editions WHERE id = $1",
              [id],
            );
            if (!edition.rows[0]) throw new ApiError(404, "BRACKET_NOT_FOUND", "Edição não encontrada.");
            if (spec.parameterKind === "array") {
              if (!Array.isArray(input)) throw new ApiError(422, "VALIDATION_ERROR", "Informe as atualizações.");
              values = [id, JSON.stringify(input)];
            } else if (spec.parameterKind === "json" || spec.parameterKind === "revision") {
              const body = requireRecord(input);
              values = [id, JSON.stringify(body)];
              if (spec.parameterKind === "revision") {
                values.push(requireInteger(payload.expectedRevision, "expectedRevision", { min: 0 }));
              }
            } else {
              values = [id];
            }
          } else if (spec.scope === "source") {
            const id = requireUuid(payload.sourceBracketMatchId, "sourceBracketMatchId");
            const found = await tx.query(
              "SELECT id FROM public.championship_bracket_matches WHERE id = $1",
              [id],
            );
            if (!found.rows[0]) throw new ApiError(404, "BRACKET_MATCH_NOT_FOUND", "Confronto não encontrado.");
            values = [id];
          } else if (spec.scope === "match") {
            const body = requireRecord(input);
            const id = requireUuid(body.match_id, "match_id");
            const found = await tx.query("SELECT id, status FROM public.matches WHERE id = $1 FOR UPDATE", [id]);
            if (!found.rows[0]) throw new ApiError(404, "MATCH_NOT_FOUND", "Jogo não encontrado.");
            if (found.rows[0].status !== "SCHEDULED")
              throw new ApiError(409, "MATCH_STATE_CONFLICT", "Somente jogos agendados podem ser reprogramados.");
            if (operation === "editable-schedule-slots") {
              values = [
                id, stringField(body.target_date, "target_date"),
                stringField(body.target_location, "target_location"),
                stringField(body.target_court_name, "target_court_name"),
                uuidOrNull(body.sport_id), body.naipe ?? null,
                uuidOrNull(body.home_team_id), uuidOrNull(body.away_team_id),
              ];
            } else {
              values = [
                id, stringField(body.scheduled_date, "scheduled_date"),
                stringField(body.location, "location"),
                stringField(body.court_name, "court_name"),
                stringField(body.slot_start_time, "slot_start_time"),
                body.representation_mode ?? "AUTO",
                uuidOrNull(body.sport_id), body.naipe ?? null,
                uuidOrNull(body.home_team_id), uuidOrNull(body.away_team_id),
              ];
            }
          } else if (spec.scope === "competition") {
            const id = requireUuid(payload.competitionId, "competitionId");
            const found = await tx.query(
              "SELECT id FROM public.championship_bracket_competitions WHERE id = $1",
              [id],
            );
            if (!found.rows[0]) throw new ApiError(404, "COMPETITION_NOT_FOUND", "Competição não encontrada.");
            const body = requireRecord(input);
            if (operation === "competition-settings-update") {
              values = [
                id,
                requireInteger(body.qualifiersPerGroup, "qualifiersPerGroup", { min: 1, max: 16 }),
                body.shouldCompleteKnockoutWithBestSecondPlacedTeams === true,
                stringField(body.knockoutPairingMode, "knockoutPairingMode"),
              ];
            } else {
              values = [id, requireUuid(body.teamAId, "teamAId"), requireUuid(body.teamBId, "teamBId")];
            }
          } else if (spec.scope === "tie-break") {
            values = [JSON.stringify(requireRecord(input))];
          } else {
            const championshipId = requireUuid(payload.championshipId, "championshipId");
            if (operation === "group-stage-standings") {
              values = [championshipId, requireInteger(payload.seasonYear, "seasonYear", { min: 2000, max: 2100 })];
            } else {
              const competitionId = requireUuid(payload.competitionId, "competitionId");
              const editionId = requireUuid(payload.editionId, "editionId");
              const target = await tx.query(
                `SELECT 1 FROM public.championship_bracket_competitions c
                   JOIN public.championship_bracket_editions e ON e.id = c.bracket_edition_id
                  WHERE c.id=$1 AND e.id=$2 AND e.championship_id=$3`,
                [competitionId, editionId, championshipId],
              );
              if (!target.rows[0]) throw new ApiError(404, "COMPETITION_NOT_FOUND", "Competição não encontrada.");
              values = [championshipId, competitionId, editionId];
            }
          }
          const result = await tx.query(spec.sql, values);
          return ["editable-schedule-slots", "group-stage-standings"].includes(operation)
            ? result.rows.map((row) => row.result)
            : (result.rows[0]?.result ?? null);
        });
        response.status(200).json({ data });
      } catch (error) {
        next(error);
      }
    },
  );
  return router;
}
