import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import {
  optionalEnum,
  optionalInteger,
  optionalString,
  parseDate,
  requireEnum,
  requireRecord,
  requireString,
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

const EVENT_TYPES = ["HH", "OPEN_BAR", "CHAMPIONSHIP", "LAJE_EVENT"] as const;
const RESERVATION_STATUSES = ["PENDING", "APPROVED", "REJECTED"] as const;

const EVENT_SELECT = `
SELECT
  e.id,
  e.name,
  e.event_type AS "eventType",
  e.organizer_type AS "organizerType",
  e.organizer_team_id AS "organizerTeamId",
  e.event_date::text AS "eventDate",
  e.created_at::text AS "createdAt",
  e.updated_at::text AS "updatedAt",
  CASE WHEN primary_team.id IS NULL THEN NULL ELSE to_jsonb(primary_team) END AS "organizerTeam",
  COALESCE((
    SELECT jsonb_agg(to_jsonb(organizer_team) ORDER BY organizer_team.name)
    FROM public.league_event_organizer_teams organizer_relation
    JOIN public.teams organizer_team ON organizer_team.id = organizer_relation.team_id
    WHERE organizer_relation.event_id = e.id
  ), '[]'::jsonb) AS "organizerTeams"
FROM public.league_events e
LEFT JOIN public.teams primary_team ON primary_team.id = e.organizer_team_id`;

const RESERVATION_SELECT = `
SELECT
  r.id,
  r.team_id AS "teamId",
  r.event_name AS "eventName",
  r.event_type AS "eventType",
  r.event_date::text AS "eventDate",
  r.requester_name AS "requesterName",
  r.requester_email AS "requesterEmail",
  r.status,
  r.approved_league_event_id AS "approvedLeagueEventId",
  r.review_notes AS "reviewNotes",
  r.reviewed_at::text AS "reviewedAt",
  r.reviewed_by AS "reviewedBy",
  r.created_at::text AS "createdAt",
  r.updated_at::text AS "updatedAt",
  to_jsonb(team) AS team,
  CASE WHEN approved_event.id IS NULL THEN NULL ELSE jsonb_build_object(
    'id', approved_event.id,
    'name', approved_event.name,
    'eventType', approved_event.event_type,
    'organizerType', approved_event.organizer_type,
    'organizerTeamId', approved_event.organizer_team_id,
    'eventDate', approved_event.event_date::text,
    'createdAt', approved_event.created_at::text,
    'updatedAt', approved_event.updated_at::text
  ) END AS "approvedLeagueEvent"
FROM public.league_event_reservation_requests r
JOIN public.teams team ON team.id = r.team_id
LEFT JOIN public.league_events approved_event ON approved_event.id = r.approved_league_event_id`;

async function insertAudit(
  executor: DatabaseQueryExecutor,
  request: AuthenticatedRequest,
  actionType: "INSERT" | "UPDATE" | "DELETE",
  resourceTable: string,
  recordId: string,
  description: string,
  oldData: DatabaseRow | null,
  newData: DatabaseRow | null,
  metadata: Record<string, unknown> = {},
): Promise<void> {
  const principal = request.authPrincipal;
  await executor.query(
    `INSERT INTO public.admin_action_logs
      (actor_user_id, actor_email, actor_role, action_type, resource_table, record_id, description, old_data, new_data, metadata, actor_name)
     VALUES ($1, $2, $3::public.app_role, $4::public.admin_action_type, $5, $6, $7, $8::jsonb, $9::jsonb, $10::jsonb, $11)`,
    [
      principal?.userId ?? null,
      principal?.user.email ?? null,
      principal?.user.role ?? null,
      actionType,
      resourceTable,
      recordId,
      description,
      oldData ? JSON.stringify(oldData) : null,
      newData ? JSON.stringify(newData) : null,
      JSON.stringify({ source: "laje-api", task: "LAJE-87", ...metadata }),
      principal?.user.profile?.name ?? null,
    ],
  );
}

async function getLeagueEvent(executor: DatabaseQueryExecutor, eventId: string) {
  const result = await executor.query(
    `${EVENT_SELECT} WHERE e.id = $1 GROUP BY e.id, primary_team.id`,
    [eventId],
  );
  return result.rows[0] ?? null;
}

async function getReservationRequest(executor: DatabaseQueryExecutor, requestId: string) {
  const result = await executor.query(`${RESERVATION_SELECT} WHERE r.id = $1`, [requestId]);
  return result.rows[0] ?? null;
}

function parseOrganizerTeamIds(value: unknown): string[] {
  if (!Array.isArray(value)) {
    throw new ApiError(422, "VALIDATION_ERROR", "O campo organizerTeamIds deve ser uma lista.");
  }
  return [...new Set(value.map((item, index) => requireUuid(item, `organizerTeamIds[${index}]`)))];
}

function parseEventInput(body: unknown) {
  const payload = requireRecord(body);
  const eventType = requireEnum(payload.eventType, "eventType", EVENT_TYPES);
  const organizerTeamIds =
    eventType === "LAJE_EVENT" ? [] : parseOrganizerTeamIds(payload.organizerTeamIds);
  if (eventType !== "LAJE_EVENT" && organizerTeamIds.length === 0) {
    throw new ApiError(
      422,
      "VALIDATION_ERROR",
      "Selecione ao menos uma atlética organizadora para eventos de atlética.",
    );
  }
  const eventDate = parseDate(payload.eventDate, "eventDate");
  if (!eventDate) {
    throw new ApiError(422, "VALIDATION_ERROR", "O campo eventDate é obrigatório.");
  }
  return {
    name: requireString(payload.name, "name", 160),
    eventType,
    organizerType: eventType === "LAJE_EVENT" ? ("LAJE" as const) : ("ATHLETIC" as const),
    organizerTeamIds,
    organizerTeamId: eventType === "LAJE_EVENT" ? null : organizerTeamIds[0]!,
    eventDate,
  };
}

function parseReservationCreate(body: unknown) {
  const payload = requireRecord(body);
  const eventDate = parseDate(payload.eventDate, "eventDate");
  if (!eventDate) {
    throw new ApiError(422, "VALIDATION_ERROR", "O campo eventDate é obrigatório.");
  }
  const requesterEmail = requireString(payload.requesterEmail, "requesterEmail", 320).toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(requesterEmail)) {
    throw new ApiError(422, "VALIDATION_ERROR", "Informe um email válido.");
  }
  return {
    teamId: requireUuid(payload.teamId, "teamId"),
    eventName: requireString(payload.eventName, "eventName", 160),
    eventType: requireEnum(payload.eventType, "eventType", EVENT_TYPES),
    eventDate,
    requesterName: requireString(payload.requesterName, "requesterName", 160),
    requesterEmail,
  };
}

async function replaceOrganizerTeams(
  executor: DatabaseQueryExecutor,
  eventId: string,
  organizerTeamIds: readonly string[],
): Promise<void> {
  await executor.query("DELETE FROM public.league_event_organizer_teams WHERE event_id = $1", [
    eventId,
  ]);
  for (const teamId of organizerTeamIds) {
    await executor.query(
      `INSERT INTO public.league_event_organizer_teams(event_id, team_id)
       VALUES ($1, $2)
       ON CONFLICT (event_id, team_id) DO NOTHING`,
      [eventId, teamId],
    );
  }
}

async function ensureTeamsExist(
  executor: DatabaseQueryExecutor,
  teamIds: readonly string[],
): Promise<void> {
  if (teamIds.length === 0) return;
  const result = await executor.query("SELECT id FROM public.teams WHERE id = ANY($1::uuid[])", [
    teamIds,
  ]);
  if (result.rows.length !== teamIds.length) {
    throw new ApiError(
      422,
      "TEAM_NOT_FOUND",
      "Uma ou mais atléticas organizadoras não foram encontradas.",
    );
  }
}

export function createLeagueEventsRouter(authService: AuthService): Router {
  const router = Router();
  const requireAuthentication = createRequireAuthentication(authService);
  const requireEventsView = [requireAuthentication, requirePermission("events", "VIEW")] as const;
  const requireEventsEdit = [requireAuthentication, requirePermission("events", "EDIT")] as const;

  router.get("/", async (request, response, next) => {
    try {
      const from = parseDate(request.query.from, "from");
      const to = parseDate(request.query.to, "to");
      if (from && to && from > to) {
        throw new ApiError(422, "VALIDATION_ERROR", "O filtro from não pode ser posterior a to.");
      }
      const year = optionalInteger(request.query.year, "year", { min: 2000, max: 9999 });
      const parameters: unknown[] = [];
      const conditions: string[] = [];
      if (from) {
        parameters.push(from);
        conditions.push(`e.event_date >= $${parameters.length}::date`);
      }
      if (to) {
        parameters.push(to);
        conditions.push(`e.event_date <= $${parameters.length}::date`);
      }
      if (year) {
        parameters.push(year);
        conditions.push(`EXTRACT(YEAR FROM e.event_date)::integer = $${parameters.length}`);
      }
      const where = conditions.length > 0 ? ` WHERE ${conditions.join(" AND ")}` : "";
      const result = await database.query(
        `${EVENT_SELECT}${where} GROUP BY e.id, primary_team.id ORDER BY e.event_date, e.name`,
        parameters,
      );
      response.status(200).json({ data: result.rows });
    } catch (error) {
      next(error);
    }
  });

  router.get("/years", async (_request, response, next) => {
    try {
      const result = await database.query(
        `SELECT DISTINCT year FROM (
           SELECT EXTRACT(YEAR FROM event_date)::integer AS year FROM public.league_events
           UNION
           SELECT EXTRACT(YEAR FROM event_date)::integer AS year
             FROM public.league_event_reservation_requests
             WHERE status IN ('PENDING', 'APPROVED')
         ) years ORDER BY year DESC`,
      );
      response.status(200).json({ data: result.rows.map((row) => Number(row.year)) });
    } catch (error) {
      next(error);
    }
  });

  router.get(
    "/reservation-requests/pending-count",
    ...requireEventsView,
    async (_request, response, next) => {
      try {
        const result = await database.query(
          "SELECT count(*)::integer AS count FROM public.league_event_reservation_requests WHERE status = 'PENDING'",
        );
        response.status(200).json({ data: { count: Number(result.rows[0]?.count ?? 0) } });
      } catch (error) {
        next(error);
      }
    },
  );

  router.get("/reservation-requests", ...requireEventsView, async (request, response, next) => {
    try {
      const year = optionalInteger(request.query.year, "year", { min: 2000, max: 9999 });
      const status = optionalEnum(request.query.status, "status", RESERVATION_STATUSES);
      const date = parseDate(request.query.date, "date");
      const parameters: unknown[] = [];
      const conditions: string[] = [];
      if (year) {
        parameters.push(year);
        conditions.push(`EXTRACT(YEAR FROM r.event_date)::integer = $${parameters.length}`);
      }
      if (status) {
        parameters.push(status);
        conditions.push(
          `r.status = $${parameters.length}::public.league_event_reservation_request_status`,
        );
      }
      if (date) {
        parameters.push(date);
        conditions.push(`r.event_date = $${parameters.length}::date`);
      }
      const where = conditions.length > 0 ? ` WHERE ${conditions.join(" AND ")}` : "";
      const result = await database.query(
        `${RESERVATION_SELECT}${where} ORDER BY r.created_at`,
        parameters,
      );
      response.status(200).json({ data: result.rows });
    } catch (error) {
      next(error);
    }
  });

  router.post("/reservation-requests", async (request, response, next) => {
    try {
      const input = parseReservationCreate(request.body);
      const teamResult = await database.query(
        "SELECT id FROM public.teams WHERE id = $1 AND is_active",
        [input.teamId],
      );
      if (teamResult.rows.length === 0) {
        throw new ApiError(
          422,
          "TEAM_NOT_FOUND",
          "Atlética responsável não encontrada ou inativa.",
        );
      }
      const result = await database.query(
        `INSERT INTO public.league_event_reservation_requests
          (team_id, event_name, event_type, event_date, requester_name, requester_email, status)
         VALUES ($1, $2, $3::public.league_event_type, $4::date, $5, $6, 'PENDING')
         RETURNING id, team_id AS "teamId", event_name AS "eventName", event_type AS "eventType",
           event_date::text AS "eventDate", status, created_at::text AS "createdAt", updated_at::text AS "updatedAt"`,
        [
          input.teamId,
          input.eventName,
          input.eventType,
          input.eventDate,
          input.requesterName,
          input.requesterEmail,
        ],
      );
      response.status(201).json({ data: result.rows[0] });
    } catch (error) {
      next(error);
    }
  });

  router.post(
    "/reservation-requests/:requestId/review",
    ...requireEventsEdit,
    async (request, response, next) => {
      try {
        const requestId = requireUuid(request.params.requestId, "requestId");
        const payload = requireRecord(request.body);
        const decision = requireEnum(payload.decision, "decision", [
          "APPROVED",
          "REJECTED",
        ] as const);
        const reviewNotes = optionalString(payload.reviewNotes, "reviewNotes", 2000) ?? null;
        const reviewedBy = (request as AuthenticatedRequest).authPrincipal?.userId ?? null;

        const reviewed = await database.transaction(async (transaction) => {
          const lockResult = await transaction.query(
            `SELECT id, team_id AS "teamId", event_name AS "eventName", event_type AS "eventType",
              event_date::text AS "eventDate", requester_name AS "requesterName", requester_email AS "requesterEmail",
              status, approved_league_event_id AS "approvedLeagueEventId", review_notes AS "reviewNotes",
              reviewed_at::text AS "reviewedAt", reviewed_by AS "reviewedBy", created_at::text AS "createdAt",
              updated_at::text AS "updatedAt"
             FROM public.league_event_reservation_requests WHERE id = $1 FOR UPDATE`,
            [requestId],
          );
          const oldRequest = lockResult.rows[0];
          if (!oldRequest) {
            throw new ApiError(
              404,
              "RESERVATION_REQUEST_NOT_FOUND",
              "Solicitação de reserva não encontrada.",
            );
          }
          if (oldRequest.status !== "PENDING") {
            throw new ApiError(
              409,
              "RESERVATION_ALREADY_REVIEWED",
              "Esta solicitação já foi analisada.",
            );
          }

          let approvedEventId: string | null = null;
          let createdEvent: DatabaseRow | null = null;
          if (decision === "APPROVED") {
            const eventResult = await transaction.query(
              `INSERT INTO public.league_events(name, event_type, organizer_type, organizer_team_id, event_date)
               VALUES ($1, $2::public.league_event_type, 'ATHLETIC', $3, $4::date)
               RETURNING id`,
              [oldRequest.eventName, oldRequest.eventType, oldRequest.teamId, oldRequest.eventDate],
            );
            approvedEventId = String(eventResult.rows[0]!.id);
            await transaction.query(
              "INSERT INTO public.league_event_organizer_teams(event_id, team_id) VALUES ($1, $2)",
              [approvedEventId, oldRequest.teamId],
            );
            createdEvent = await getLeagueEvent(transaction, approvedEventId);
          }

          await transaction.query(
            `UPDATE public.league_event_reservation_requests SET
              status = $2::public.league_event_reservation_request_status,
              approved_league_event_id = $3,
              review_notes = $4,
              reviewed_at = timezone('utc', now()),
              reviewed_by = $5,
              updated_at = timezone('utc', now())
             WHERE id = $1`,
            [requestId, decision, approvedEventId, reviewNotes, reviewedBy],
          );
          const newRequest = await getReservationRequest(transaction, requestId);
          await insertAudit(
            transaction,
            request as AuthenticatedRequest,
            "UPDATE",
            "public.league_event_reservation_requests",
            requestId,
            decision === "APPROVED"
              ? "Reserva do calendário aprovada."
              : "Reserva do calendário recusada.",
            oldRequest,
            newRequest,
            { approvedLeagueEventId: approvedEventId },
          );
          return { request: newRequest, leagueEvent: createdEvent };
        });

        response.status(200).json({ data: reviewed });
      } catch (error) {
        next(error);
      }
    },
  );

  router.post("/", ...requireEventsEdit, async (request, response, next) => {
    try {
      const input = parseEventInput(request.body);
      const event = await database.transaction(async (transaction) => {
        await ensureTeamsExist(transaction, input.organizerTeamIds);
        const result = await transaction.query(
          `INSERT INTO public.league_events(name, event_type, organizer_type, organizer_team_id, event_date)
           VALUES ($1, $2::public.league_event_type, $3::public.league_event_organizer_type, $4, $5::date)
           RETURNING id`,
          [
            input.name,
            input.eventType,
            input.organizerType,
            input.organizerTeamId,
            input.eventDate,
          ],
        );
        const eventId = String(result.rows[0]!.id);
        await replaceOrganizerTeams(transaction, eventId, input.organizerTeamIds);
        const created = await getLeagueEvent(transaction, eventId);
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          "INSERT",
          "public.league_events",
          eventId,
          "Evento da liga criado via laje-api.",
          null,
          created,
        );
        return created;
      });
      response.status(201).json({ data: event });
    } catch (error) {
      next(error);
    }
  });

  router.get("/:eventId", async (request, response, next) => {
    try {
      const eventId = requireUuid(request.params.eventId, "eventId");
      const event = await getLeagueEvent(database, eventId);
      if (!event) {
        throw new ApiError(404, "LEAGUE_EVENT_NOT_FOUND", "Evento da liga não encontrado.");
      }
      response.status(200).json({ data: event });
    } catch (error) {
      next(error);
    }
  });

  router.put("/:eventId", ...requireEventsEdit, async (request, response, next) => {
    try {
      const eventId = requireUuid(request.params.eventId, "eventId");
      const input = parseEventInput(request.body);
      const event = await database.transaction(async (transaction) => {
        const oldEvent = await getLeagueEvent(transaction, eventId);
        if (!oldEvent) {
          throw new ApiError(404, "LEAGUE_EVENT_NOT_FOUND", "Evento da liga não encontrado.");
        }
        await ensureTeamsExist(transaction, input.organizerTeamIds);
        await transaction.query(
          `UPDATE public.league_events SET
            name = $2,
            event_type = $3::public.league_event_type,
            organizer_type = $4::public.league_event_organizer_type,
            organizer_team_id = $5,
            event_date = $6::date,
            updated_at = now()
           WHERE id = $1`,
          [
            eventId,
            input.name,
            input.eventType,
            input.organizerType,
            input.organizerTeamId,
            input.eventDate,
          ],
        );
        await replaceOrganizerTeams(transaction, eventId, input.organizerTeamIds);
        const updated = await getLeagueEvent(transaction, eventId);
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          "UPDATE",
          "public.league_events",
          eventId,
          "Evento da liga atualizado via laje-api.",
          oldEvent,
          updated,
        );
        return updated;
      });
      response.status(200).json({ data: event });
    } catch (error) {
      next(error);
    }
  });

  router.delete("/:eventId", ...requireEventsEdit, async (request, response, next) => {
    try {
      const eventId = requireUuid(request.params.eventId, "eventId");
      await database.transaction(async (transaction) => {
        const oldEvent = await getLeagueEvent(transaction, eventId);
        if (!oldEvent) {
          throw new ApiError(404, "LEAGUE_EVENT_NOT_FOUND", "Evento da liga não encontrado.");
        }
        await transaction.query("DELETE FROM public.league_events WHERE id = $1", [eventId]);
        await insertAudit(
          transaction,
          request as AuthenticatedRequest,
          "DELETE",
          "public.league_events",
          eventId,
          "Evento da liga excluído via laje-api.",
          oldEvent,
          null,
        );
      });
      response.status(204).end();
    } catch (error) {
      next(error);
    }
  });

  return router;
}
