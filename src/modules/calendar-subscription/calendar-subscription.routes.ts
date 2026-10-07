import { Router } from "express";

import { ApiError } from "../../common/errors/api-error.js";
import { database } from "../../database/index.js";
import {
  buildCalendarDocument,
  resolveCalendarDescription,
  resolveETag,
  resolveMatchCalendarTitle,
  resolveScheduledSessionDateTime,
  type CalendarFeedEvent,
} from "./calendar-ics.js";

const SCOPES = [
  "MATCH",
  "SESSION",
  "SPORT_NAIPE",
  "TEAM",
  "TEAM_MATCHES",
  "TEAM_SPORT_NAIPE",
] as const;

type CalendarScope = (typeof SCOPES)[number];

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function stringQuery(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function isUuid(value: string | null): value is string {
  return value != null && UUID_PATTERN.test(value);
}

function resolveNaipeLabel(naipe: string): string {
  if (naipe === "MASCULINO") return "Masculino";
  if (naipe === "FEMININO") return "Feminino";
  return "Misto";
}

function resolveDivisionLabel(division: string | null): string | null {
  if (division === "DIVISAO_PRINCIPAL") return "Divisão Principal";
  if (division === "DIVISAO_ACESSO") return "Divisão de Acesso";
  return null;
}

function resolveLocation(location: string | null, courtName: string | null): string | null {
  if (!location) return courtName;
  return courtName ? `${location} • ${courtName}` : location;
}

function resolveMatchEndTime(
  startTime: string,
  endTime: string | null,
  durationMinutes: number | null,
): string | null {
  if (endTime) {
    const start = new Date(startTime).getTime();
    const end = new Date(endTime).getTime();
    if (Number.isFinite(start) && Number.isFinite(end) && end > start) return endTime;
  }
  if (!durationMinutes || durationMinutes <= 0) return null;
  return new Date(new Date(startTime).getTime() + durationMinutes * 60_000).toISOString();
}

function parseRequest(query: Record<string, unknown>) {
  const scope = stringQuery(query.scope) as CalendarScope | null;
  const championshipId = stringQuery(query.championship_id);
  const seasonYear = Number(stringQuery(query.season_year));
  const matchId = stringQuery(query.match_id);
  const sessionId = stringQuery(query.session_id);
  const sportId = stringQuery(query.sport_id);
  const naipe = stringQuery(query.naipe);
  const teamId = stringQuery(query.team_id);

  if (
    !scope ||
    !SCOPES.includes(scope) ||
    !isUuid(championshipId) ||
    !Number.isInteger(seasonYear) ||
    seasonYear < 2000 ||
    seasonYear > 2100 ||
    (scope === "MATCH" && !isUuid(matchId)) ||
    (scope === "SESSION" && !isUuid(sessionId)) ||
    (scope === "SPORT_NAIPE" && (!isUuid(sportId) || !naipe)) ||
    ((scope === "TEAM" || scope === "TEAM_MATCHES") && !isUuid(teamId)) ||
    (scope === "TEAM_SPORT_NAIPE" && (!isUuid(teamId) || !isUuid(sportId) || !naipe))
  ) {
    throw new ApiError(400, "INVALID_CALENDAR_SUBSCRIPTION", "Solicitação de agenda inválida.");
  }

  return { scope, championshipId, seasonYear, matchId, sessionId, sportId, naipe, teamId };
}

async function assertPublicCalendarEnabled(): Promise<void> {
  const result = await database.query(
    `SELECT is_public_access_blocked AS "isPublicAccessBlocked",
            is_schedule_page_blocked AS "isSchedulePageBlocked"
       FROM public.public_page_access_settings
       ORDER BY id
       LIMIT 1`,
  );
  const settings = result.rows[0];
  if (settings?.isPublicAccessBlocked === true || settings?.isSchedulePageBlocked === true) {
    throw new ApiError(404, "CALENDAR_FEED_NOT_FOUND", "Agenda não encontrada.");
  }
}

async function loadEvents(input: ReturnType<typeof parseRequest>): Promise<CalendarFeedEvent[]> {
  const events: CalendarFeedEvent[] = [];
  const appUrl = process.env.APP_URL?.trim() || "https://laje-tcc.vercel.app";

  if (input.scope !== "SESSION") {
    const parameters: unknown[] = [input.championshipId, input.seasonYear];
    const conditions = [
      "m.championship_id = $1",
      "m.season_year = $2",
      "m.status = 'SCHEDULED'",
      "COALESCE(m.is_pending_manual_relocation, false) = false",
      "m.start_time IS NOT NULL",
      "m.start_time >= now()",
    ];

    if (input.scope === "MATCH") {
      parameters.push(input.matchId);
      conditions.push(`m.id = $${parameters.length}`);
    }
    if (input.scope === "SPORT_NAIPE" || input.scope === "TEAM_SPORT_NAIPE") {
      parameters.push(input.sportId, input.naipe);
      conditions.push(`m.sport_id = $${parameters.length - 1}`);
      conditions.push(`m.naipe::text = $${parameters.length}`);
    }
    if (
      input.scope === "TEAM" ||
      input.scope === "TEAM_MATCHES" ||
      input.scope === "TEAM_SPORT_NAIPE"
    ) {
      parameters.push(input.teamId);
      conditions.push(
        `(m.home_team_id = $${parameters.length} OR m.away_team_id = $${parameters.length})`,
      );
    }

    const matches = await database.query(
      `SELECT m.id, m.championship_id AS "championshipId", m.season_year AS "seasonYear",
              m.sport_id AS "sportId", m.naipe::text AS naipe, m.division::text AS division,
              m.location, m.court_name AS "courtName", m.start_time::text AS "startTime",
              m.end_time::text AS "endTime", m.created_at::text AS "createdAt",
              COALESCE(m.updated_at, m.created_at)::text AS "updatedAt",
              c.name AS "championshipName", s.name AS "sportName",
              ht.name AS "homeTeamName", at.name AS "awayTeamName",
              cs.default_match_duration_minutes AS "durationMinutes"
         FROM public.matches m
         JOIN public.championships c ON c.id = m.championship_id
         JOIN public.sports s ON s.id = m.sport_id
         JOIN public.teams ht ON ht.id = m.home_team_id
         JOIN public.teams at ON at.id = m.away_team_id
         LEFT JOIN public.championship_sports cs
           ON cs.championship_id = m.championship_id AND cs.sport_id = m.sport_id
        WHERE ${conditions.join(" AND ")}
        ORDER BY m.start_time, m.id`,
      parameters,
    );

    for (const match of matches.rows) {
      const startTime = String(match.startTime);
      const endTime = resolveMatchEndTime(
        startTime,
        match.endTime == null ? null : String(match.endTime),
        match.durationMinutes == null ? null : Number(match.durationMinutes),
      );
      if (!endTime) continue;
      events.push({
        uid: `match-${String(match.id)}@laje.app`,
        title: resolveMatchCalendarTitle(
          String(match.sportName),
          resolveNaipeLabel(String(match.naipe)),
          String(match.homeTeamName),
          String(match.awayTeamName),
        ),
        description: resolveCalendarDescription([
          String(match.championshipName),
          `Edição ${String(match.seasonYear)}`,
          resolveNaipeLabel(String(match.naipe)),
          resolveDivisionLabel(match.division == null ? null : String(match.division)),
          `Agenda: ${appUrl}/agenda`,
        ]),
        location: resolveLocation(
          match.location == null ? null : String(match.location),
          match.courtName == null ? null : String(match.courtName),
        ),
        startTime,
        endTime,
        updatedAt: String(match.updatedAt ?? match.createdAt),
      });
    }
  }

  if (input.scope === "SESSION" || input.scope === "SPORT_NAIPE" || input.scope === "TEAM") {
    const parameters: unknown[] = [input.championshipId, input.seasonYear];
    const conditions = [
      "s.championship_id = $1",
      "s.season_year = $2",
      "s.status = 'SCHEDULED'",
      "s.scheduled_date IS NOT NULL",
      "s.start_time IS NOT NULL",
      "s.end_time IS NOT NULL",
      "(s.scheduled_date > (now() AT TIME ZONE 'America/Sao_Paulo')::date OR (s.scheduled_date = (now() AT TIME ZONE 'America/Sao_Paulo')::date AND s.start_time >= (now() AT TIME ZONE 'America/Sao_Paulo')::time))",
    ];

    if (input.scope === "SESSION") {
      parameters.push(input.sessionId);
      conditions.push(`s.id = $${parameters.length}`);
    }
    if (input.scope === "SPORT_NAIPE") {
      parameters.push(input.sportId, input.naipe);
      conditions.push(`s.sport_id = $${parameters.length - 1}`);
      conditions.push(`s.naipe::text = $${parameters.length}`);
    }
    if (input.scope === "TEAM") {
      parameters.push(input.teamId);
      conditions.push(
        `EXISTS (
           SELECT 1
             FROM public.championship_individual_events ie
             JOIN public.championship_individual_event_entries e ON e.event_id = ie.id
            WHERE ie.session_id = s.id AND e.team_id = $${parameters.length}
         )`,
      );
    }

    const sessions = await database.query(
      `SELECT s.id, s.season_year AS "seasonYear", s.naipe::text AS naipe,
              s.division::text AS division, s.scheduled_date::text AS "scheduledDate",
              s.start_time::text AS "startTime", s.end_time::text AS "endTime",
              s.location_name AS "locationName", s.court_name AS "courtName",
              s.created_at::text AS "createdAt", s.updated_at::text AS "updatedAt",
              sport.name AS "sportName"
         FROM public.championship_individual_sessions s
         JOIN public.sports sport ON sport.id = s.sport_id
        WHERE ${conditions.join(" AND ")}
        ORDER BY s.scheduled_date, s.start_time, s.id`,
      parameters,
    );

    for (const session of sessions.rows) {
      const scheduledDate = String(session.scheduledDate);
      const startTime = resolveScheduledSessionDateTime(scheduledDate, String(session.startTime));
      const endTime = resolveScheduledSessionDateTime(scheduledDate, String(session.endTime));
      if (!startTime || !endTime || new Date(endTime).getTime() <= new Date(startTime).getTime()) {
        continue;
      }
      events.push({
        uid: `session-${String(session.id)}@laje.app`,
        title: `LAJE · Sessão de ${String(session.sportName)} — ${resolveNaipeLabel(String(session.naipe))}`,
        description: resolveCalendarDescription([
          "Sessão individual",
          `Edição ${String(session.seasonYear)}`,
          resolveNaipeLabel(String(session.naipe)),
          resolveDivisionLabel(session.division == null ? null : String(session.division)),
          `Agenda: ${appUrl}/agenda`,
        ]),
        location: resolveLocation(
          session.locationName == null ? null : String(session.locationName),
          session.courtName == null ? null : String(session.courtName),
        ),
        startTime,
        endTime,
        updatedAt: String(session.updatedAt ?? session.createdAt),
      });
    }
  }

  return events.sort((left, right) => left.startTime.localeCompare(right.startTime));
}

export function createCalendarSubscriptionRouter(): Router {
  const router = Router();

  router.get("/", async (request, response, next) => {
    try {
      const input = parseRequest(request.query as Record<string, unknown>);
      await assertPublicCalendarEnabled();
      const calendar = buildCalendarDocument(await loadEvents(input));
      const etag = resolveETag(calendar);

      if (request.headers["if-none-match"] === etag) {
        response.status(304).set({ ETag: etag, "Cache-Control": "private, max-age=300" }).end();
        return;
      }

      response
        .status(200)
        .set({
          "Content-Type": "text/calendar; charset=utf-8",
          "Content-Disposition":
            request.query.download === "1"
              ? "attachment; filename=laje-agenda.ics"
              : "inline; filename=laje-agenda.ics",
          "Cache-Control": "private, max-age=300",
          ETag: etag,
        })
        .send(calendar);
    } catch (error) {
      next(error);
    }
  });

  return router;
}
