import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import {
  optionalEnum,
  optionalUuid,
  requireEnum,
  requireInteger,
  requireUuid,
} from "../../common/validation/common.schema.js";
import { database } from "../../database/index.js";
import { createRequireAuthentication } from "../auth/auth.middleware.js";
import type { AuthService } from "../auth/auth.service.js";

const MATCH_NAIPES = ["MASCULINO", "FEMININO", "MISTO"] as const;
const TEAM_DIVISIONS = ["DIVISAO_PRINCIPAL", "DIVISAO_ACESSO"] as const;

/**
 * Strict whitelist of existing PostgreSQL read-only procedures migrated from
 * Supabase. Never accept arbitrary procedure names or SQL from an HTTP caller.
 * The two operational pending queues require an AWS admin access token.
 */
const SNAPSHOTS = {
  "pending-award-draws": {
    name: "get_championship_award_pending_draws",
    signature: "uuid,integer",
    type: "json",
    admin: true,
  },
  "pending-tie-breaks": {
    name: "get_championship_bracket_pending_tie_breaks",
    signature: "uuid,uuid",
    type: "json",
    admin: true,
  },
  "interlaje-competition-standings": {
    name: "get_interlaje_regulation_competition_standings",
    signature: "uuid,integer,uuid,match_naipe,team_division",
    type: "rows",
    admin: false,
  },
  "interlaje-overall-standings": {
    name: "get_interlaje_overall_standings",
    signature: "uuid,integer",
    type: "rows",
    admin: false,
  },
  "awards-rankings": {
    name: "get_championship_score_sheet_awards_rankings",
    signature: "uuid,integer",
    type: "json",
    admin: false,
  },
  "corrected-group-standings": {
    name: "get_championship_corrected_group_standings",
    signature: "uuid,integer",
    type: "rows",
    admin: false,
  },
  "resolved-tie-break-orders": {
    name: "get_championship_bracket_resolved_tie_break_orders",
    signature: "uuid,integer",
    type: "json",
    admin: false,
  },
  "yellow-card-discipline": {
    name: "get_championship_yellow_card_discipline",
    signature: "uuid,integer",
    type: "json",
    admin: false,
  },
  "interlaje-position-points": {
    name: "get_interlaje_position_point_settings",
    signature: "uuid,integer",
    type: "rows",
    admin: false,
  },
  "competition-disqualifications": {
    name: "list_championship_competition_team_disqualifications",
    signature: "uuid,integer",
    type: "rows",
    admin: false,
  },
} as const;

export type RealtimeSnapshotName = keyof typeof SNAPSHOTS;

export function isRealtimeSnapshotName(value: string): value is RealtimeSnapshotName {
  return Object.prototype.hasOwnProperty.call(SNAPSHOTS, value);
}

export function buildRealtimeSnapshotQuery(
  name: RealtimeSnapshotName,
  scope: {
    championshipId: string;
    seasonYear?: number | null | undefined;
    bracketEditionId?: string | undefined;
    sportId?: string | undefined;
    naipe?: string | undefined;
    division?: string | null | undefined;
  },
): { sql: string; parameters: unknown[] } {
  const spec = SNAPSHOTS[name];
  const parameters: unknown[] = [scope.championshipId];
  if (name === "pending-tie-breaks") {
    parameters.push(scope.bracketEditionId ?? null);
  } else {
    parameters.push(scope.seasonYear);
  }
  if (name === "interlaje-competition-standings") {
    parameters.push(scope.sportId, scope.naipe, scope.division ?? null);
  }

  const casts = spec.signature.split(",");
  const placeholders = casts
    .map(
      (cast, index) =>
        `$${index + 1}::${cast === "match_naipe" || cast === "team_division" ? `public.${cast}` : cast}`,
    )
    .join(", ");
  const expression = `public.${spec.name}(${placeholders})`;
  return {
    sql:
      spec.type === "json"
        ? `SELECT ${expression} AS data`
        : `SELECT COALESCE(jsonb_agg(to_jsonb(item)), '[]'::jsonb) AS data FROM ${expression} AS item`,
    parameters,
  };
}

export function createRealtimeReadRouter(authService: AuthService): Router {
  const router = Router();
  const authenticate = createRequireAuthentication(authService);

  for (const name of Object.keys(SNAPSHOTS) as RealtimeSnapshotName[]) {
    const spec = SNAPSHOTS[name];
    const middlewares = spec.admin ? [authenticate] : [];

    router.get(`/:championshipId/${name}`, ...middlewares, async (request, response, next) => {
      try {
        const championshipId = requireUuid(request.params.championshipId, "championshipId");
        const seasonYear =
          name === "pending-tie-breaks"
            ? undefined
            : request.query.seasonYear == null &&
                (name === "corrected-group-standings" || name === "resolved-tie-break-orders")
              ? null
              : requireInteger(request.query.seasonYear, "seasonYear", { min: 2000, max: 2100 });
        const bracketEditionId =
          name === "pending-tie-breaks"
            ? optionalUuid(request.query.bracketEditionId, "bracketEditionId")
            : undefined;
        const sportId =
          name === "interlaje-competition-standings"
            ? requireUuid(request.query.sportId, "sportId")
            : undefined;
        const naipe =
          name === "interlaje-competition-standings"
            ? requireEnum(request.query.naipe, "naipe", MATCH_NAIPES)
            : undefined;
        const division =
          name === "interlaje-competition-standings"
            ? optionalEnum(request.query.division, "division", TEAM_DIVISIONS)
            : undefined;

        const { sql, parameters } = buildRealtimeSnapshotQuery(name, {
          championshipId,
          seasonYear,
          bracketEditionId,
          sportId,
          naipe,
          division,
        });
        const result = await database.query<{ data: unknown }>(sql, parameters);
        if (!result.rows[0]) {
          throw new ApiError(503, "SNAPSHOT_UNAVAILABLE", "Consulta temporariamente indisponível.");
        }
        response.setHeader("Cache-Control", "private, no-store");
        response.status(200).json({ data: result.rows[0].data });
      } catch (error) {
        next(error);
      }
    });
  }

  return router;
}
