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
import { SNAPSHOTS, buildRealtimeSnapshotQuery, type RealtimeSnapshotName } from "./realtime-read.queries.js";

const MATCH_NAIPES = ["MASCULINO", "FEMININO", "MISTO"] as const;
const TEAM_DIVISIONS = ["DIVISAO_PRINCIPAL", "DIVISAO_ACESSO"] as const;

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
