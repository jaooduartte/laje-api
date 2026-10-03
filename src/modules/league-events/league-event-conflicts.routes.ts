import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import { parseDate } from "../../common/validation/common.schema.js";
import { database } from "../../database/index.js";

export function createLeagueEventConflictsRouter(): Router {
  const router = Router();

  router.get("/reservation-requests/conflicts", async (request, response, next) => {
    try {
      const date = parseDate(request.query.date, "date");
      if (!date) {
        throw new ApiError(422, "VALIDATION_ERROR", "O filtro date é obrigatório.");
      }

      const result = await database.query(
        `SELECT
          r.id,
          r.team_id AS "teamId",
          r.event_name AS "eventName",
          r.event_type AS "eventType",
          r.event_date::text AS "eventDate",
          r.status,
          r.created_at::text AS "createdAt",
          r.updated_at::text AS "updatedAt",
          jsonb_build_object(
            'id', team.id,
            'name', team.name,
            'city', team.city,
            'division', team.division,
            'isActive', team.is_active,
            'createdAt', team.created_at::text
          ) AS team
         FROM public.league_event_reservation_requests r
         JOIN public.teams team ON team.id = r.team_id
         WHERE r.event_date = $1::date
           AND r.status = 'PENDING'
         ORDER BY r.created_at, r.id`,
        [date],
      );

      response.status(200).json({ data: result.rows });
    } catch (error) {
      next(error);
    }
  });

  return router;
}
