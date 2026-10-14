import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";

import express from "express";

process.env.NODE_ENV = "test";
process.env.PORT = "3000";
process.env.DATABASE_URL = "postgresql://laje:laje@localhost:5432/laje";
process.env.CORS_ORIGINS = "http://localhost:8080";
process.env.AUTH_ENABLED = "false";
process.env.AWS_ENABLED = "false";
process.env.MAIL_ENABLED = "false";

const [
  { database },
  { errorHandler },
  { createAuthRouter },
  { createMatchesRouter },
  { createChampionshipsRouter },
  { createPublicRuntimeRouter },
  { createPublicAccessRouter },
  { createLeagueEventsRouter },
] = await Promise.all([
  import("../../src/database/index.js"),
  import("../../src/common/middlewares/error-handler.middleware.js"),
  import("../../src/modules/auth/auth.routes.js"),
  import("../../src/modules/matches/matches.routes.js"),
  import("../../src/modules/championships/championships.routes.js"),
  import("../../src/modules/public-runtime/public-runtime.routes.js"),
  import("../../src/modules/public-access/public-access.routes.js"),
  import("../../src/modules/league-events/league-events.routes.js"),
]);
import type { AuthService } from "../../src/modules/auth/auth.service.js";
import type { DatabaseQueryExecutor, DatabaseRow } from "../../src/database/types.js";

const ID = "b37e22a1-8181-43b2-98a1-29db7e864f0a";
const ADMIN_ID = "b37e22a1-8181-43b2-98a1-29db7e864f0b";
const permissions = [
  "control",
  "matches",
  "settings",
  "links",
  "events",
  "bracket_setup",
  "score_sheet_review",
  "championship_schedule",
].map((scope) => ({ scope, level: "EDIT" as const }));
const principal = {
  userId: ADMIN_ID,
  sessionId: ID,
  user: {
    id: ADMIN_ID,
    email: "ci@example.invalid",
    role: "admin" as const,
    profile: null,
    permissions,
    canAccessAdminPanel: true,
  },
};

const authService = {
  authenticateAccessToken: async (_token: string) => principal,
  createSession: async () => ({
    refreshToken: "synthetic-only-test",
    payload: {
      accessToken: "synthetic-jwt",
      tokenType: "Bearer",
      expiresAt: new Date().toISOString(),
      user: principal.user,
    },
  }),
  revokeSession: async () => {},
  getRefreshCookieConfig: () => ({ secure: false, maxAgeMs: 10_000 }),
} as unknown as AuthService;

type TestResponse = { status: number; body: Record<string, unknown> };
const champ = {
  id: ID,
  code: "INTERLAJE",
  name: "Campeonato Sintético",
  status: "IN_PROGRESS",
  currentSeasonYear: 2026,
  usesDivisions: false,
  defaultLocation: null,
};

test("LAJE-38 HTTP controller coverage uses only synthetic database adapters", async (t) => {
  const executedSql: string[] = [];
  let status = "SCHEDULED";
  const homeScore = 0;
  const awayScore = 0;
  const match = () => ({
    id: ID,
    championshipId: ID,
    seasonYear: 2026,
    sportId: ID,
    homeTeamId: ID,
    awayTeamId: ADMIN_ID,
    status,
    homeScore,
    awayScore,
    naipe: "MASCULINO",
    division: null,
    courtName: "Ginásio",
    scheduledDate: "2026-10-30",
    totalCount: 1,
  });

  const query = async <Row extends DatabaseRow = DatabaseRow>(
    statement: string,
    _parameters?: readonly unknown[],
  ): Promise<{ rows: Row[]; count: number }> => {
    executedSql.push(statement);
    let rows: Record<string, unknown>[] = [];
    if (
      /UPDATE public.matches SET/.test(statement) ||
      /UPDATE public.matches\s+SET/.test(statement)
    ) {
      if (/SET status = 'LIVE'/.test(statement)) status = "LIVE";
      else if (/SET status = 'FINISHED'/.test(statement)) status = "FINISHED";
      else if (/SET status = 'SCHEDULED'/.test(statement)) status = "SCHEDULED";
      rows = [{ id: ID }];
    } else if (
      /FROM public.matches m/.test(statement) &&
      /JOIN public.championships/.test(statement)
    ) {
      rows = [match()];
    } else if (/FROM public.matches m/.test(statement) && /JOIN public.sports/.test(statement)) {
      rows = [match()];
    } else if (/FROM public.championships/.test(statement)) {
      rows = [champ];
    } else if (/FROM public.teams/.test(statement)) {
      rows = [{ id: ID, name: "Atlética Sintética", division: null, isActive: true }];
    } else if (/FROM public.sports/.test(statement)) {
      rows = [{ id: ID, name: "Futsal", code: "FUTSAL" }];
    } else if (/FROM public.standings st/.test(statement)) {
      rows = [];
    } else if (/SELECT DISTINCT team_id/.test(statement)) {
      rows = [{ teamId: ID }];
    } else if (/FROM public.league_calendar_holidays/.test(statement)) {
      rows = [];
    } else if (/INSERT INTO public.admin_action_logs/.test(statement)) {
      rows = [{ id: ID }];
    } else if (/RETURNING/.test(statement)) {
      rows = [{ id: ID }];
    }
    return { rows: rows as Row[], count: rows.length };
  };

  t.mock.method(database, "query", query);
  t.mock.method(
    database,
    "transaction",
    async <T>(work: (executor: DatabaseQueryExecutor) => Promise<T>): Promise<T> => work({ query }),
  );

  const app = express();
  app.use(express.json());
  app.use("/auth", createAuthRouter(authService));
  app.use("/matches", createMatchesRouter(authService));
  app.use("/championships", createChampionshipsRouter(authService));
  app.use("/public-runtime", createPublicRuntimeRouter());
  app.use("/public", createPublicAccessRouter(authService));
  app.use("/league-events", createLeagueEventsRouter(authService));
  app.use(errorHandler);
  const server = app.listen(0, "127.0.0.1");
  t.after(
    () =>
      new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      }),
  );
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const origin = `http://127.0.0.1:${address.port}`;

  async function call(path: string, options: RequestInit = {}): Promise<TestResponse> {
    const response = await fetch(origin + path, {
      ...options,
      headers: {
        "content-type": "application/json",
        authorization: "Bearer test",
        ...options.headers,
      },
    });
    const body = (response.status === 204 ? {} : await response.json()) as Record<string, unknown>;
    return { status: response.status, body };
  }
  function jsonBody(response: TestResponse): {
    data?: Record<string, unknown> | Record<string, unknown>[];
  } {
    assert.equal(response.status, 200);
    return response.body;
  }

  // Public browsing includes full list/query paths and input validation.
  assert.equal((jsonBody(await call("/matches")).data as unknown[]).length, 1);
  assert.equal((jsonBody(await call("/matches/" + ID)).data as Record<string, unknown>).id, ID);
  assert.equal((jsonBody(await call("/championships")).data as unknown[]).length, 1);
  assert.equal(
    (jsonBody(await call("/championships/" + ID)).data as Record<string, unknown>).id,
    ID,
  );
  assert.equal((await call("/matches?status=WRONG")).status, 422);
  assert.equal((await call("/championships/" + ID + "/calendar?seasonYear=2026")).status, 200);

  // Authenticated control traverses scheduling, scoreboard and completion handlers.
  const started = await call("/matches/" + ID + "/start", { method: "POST" });
  assert.equal(started.status, 200);
  assert.equal((started.body.data as Record<string, unknown>).status, "LIVE");
  const score = await call("/matches/" + ID + "/scoreboard", {
    method: "PATCH",
    body: JSON.stringify({ homeScore: 2, awayScore: 1 }),
  });
  assert.equal(score.status, 200);
  assert.equal((score.body.data as Record<string, unknown>).status, "LIVE");
  const invalid = await call("/matches/" + ID + "/scoreboard", {
    method: "PATCH",
    body: JSON.stringify({ homeScore: -1 }),
  });
  assert.equal(invalid.status, 422);
  const finished = await call("/matches/" + ID + "/finish", {
    method: "POST",
    body: JSON.stringify({}),
  });
  assert.equal(finished.status, 200);
  assert.equal((finished.body.data as Record<string, unknown>).status, "FINISHED");

  // The remaining public-resource reads are still tested with deterministic empty results.
  const publicPaths = [
    "/public-runtime/teams",
    "/public-runtime/sports",
    "/public-runtime/championships/" + ID + "/season-years",
    "/public-runtime/championships/" + ID + "/seasons/2026/removed-sports",
    "/public-runtime/championships/" + ID + "/seasons/2026/disqualifications",
    "/public-runtime/championships/" + ID + "/seasons/2026/match-context",
    "/public-runtime/league-calendar-holidays?startDate=2026-10-01&endDate=2026-10-31",
    "/public-runtime/bracket-location-templates",
    "/public-runtime/championships/" + ID + "/individual-events?seasonYear=2026",
    "/public-runtime/championships/" + ID + "/individual-sessions?seasonYear=2026",
    "/public-runtime/individual-event-entries",
    "/public-runtime/individual-sessions/" + ID + "/participants",
    "/public-runtime/championships/" + ID + "/individual-standings?seasonYear=2026",
    "/public/settings",
    "/public/links",
    "/public/links/admin",
    "/league-events",
    "/league-events/years",
    "/league-events/reservation-requests",
    "/league-events/reservation-requests/pending-count",
  ];
  for (const path of publicPaths) {
    const result = await call(path);
    assert.equal(
      result.status,
      200,
      `Expected successful read-only endpoint ${path}: ${JSON.stringify(result.body)}`,
    );
  }

  // Control-plane validation and deterministic synthetic write paths.
  const holidays = await call("/public-runtime/league-calendar-holidays/ensure-year", {
    method: "POST",
    body: JSON.stringify({ year: 2026 }),
  });
  assert.equal(holidays.status, 200);
  assert.ok(
    executedSql.some((statement) =>
      statement.includes("INSERT INTO public.league_calendar_holidays"),
    ),
  );
  assert.equal(
    (
      await call("/public-runtime/league-calendar-holidays/ensure-year", {
        method: "POST",
        body: JSON.stringify({ year: 1700 }),
      })
    ).status,
    422,
  );

  const section = await call("/public/link-sections", {
    method: "POST",
    body: JSON.stringify({ name: "Links sintéticos", sortOrder: 1 }),
  });
  assert.equal(section.status, 201);
  assert.ok(
    executedSql.some((statement) => statement.includes("INSERT INTO public.public_link_sections")),
  );
  assert.equal(
    (
      await call("/public/link-sections", {
        method: "POST",
        body: JSON.stringify({ name: "", sortOrder: 0 }),
      })
    ).status,
    422,
  );

  const settings = await call("/public/settings", {
    method: "PUT",
    body: JSON.stringify({
      isPublicAccessBlocked: false,
      announcementContent: { version: 1, segments: [{ text: "Testes de integração", bold: true }] },
    }),
  });
  assert.equal(settings.status, 200);
  assert.ok(
    executedSql.some((statement) =>
      statement.includes("INSERT INTO public.public_page_access_settings"),
    ),
  );
  assert.equal(
    (
      await call("/public/link-items", {
        method: "POST",
        body: JSON.stringify({
          sectionId: ID,
          displayName: "URL inválida",
          url: "javascript:alert(1)",
          sortOrder: 1,
          filterMode: "GLOBAL",
        }),
      })
    ).status,
    422,
  );

  const leagueEvent = await call("/league-events", {
    method: "POST",
    body: JSON.stringify({
      name: "Evento sintético da liga",
      eventType: "LAJE_EVENT",
      eventDate: "2026-11-01",
    }),
  });
  assert.equal(leagueEvent.status, 201);
  assert.ok(
    executedSql.some((statement) => statement.includes("INSERT INTO public.league_events")),
  );

  const reservation = await call("/league-events/reservation-requests", {
    method: "POST",
    body: JSON.stringify({
      teamId: ID,
      eventName: "Evento sintético",
      eventType: "HH",
      eventDate: "2026-11-01",
      requesterName: "Pessoa de teste",
      requesterEmail: "test@example.invalid",
    }),
  });
  assert.equal(reservation.status, 201);
  assert.ok(
    executedSql.some((statement) =>
      statement.includes("INSERT INTO public.league_event_reservation_requests"),
    ),
  );
  assert.equal(
    (
      await call("/league-events/reservation-requests", {
        method: "POST",
        body: JSON.stringify({
          teamId: ID,
          eventName: "Evento sintético",
          eventType: "HH",
          eventDate: "2026-11-01",
          requesterName: "Pessoa de teste",
          requesterEmail: "invalid-email",
        }),
      })
    ).status,
    422,
  );

  const standings = await call("/championships/" + ID + "/standings?seasonYear=2026");
  assert.equal(standings.status, 200);

  // Campeonato: CRUD autorizado, configurações sazonais e impedimento de avanço inválido.
  const createdChampionship = await call("/championships", {
    method: "POST",
    body: JSON.stringify({
      code: "SOCIETY",
      name: "Copa Society Sintética",
      currentSeasonYear: 2026,
      status: "PLANNING",
      usesDivisions: true,
    }),
  });
  assert.equal(createdChampionship.status, 201);
  assert.ok(
    executedSql.some((statement) => statement.includes("INSERT INTO public.championships")),
  );
  assert.equal(
    (
      await call("/championships", {
        method: "POST",
        body: JSON.stringify({ code: "NOT_ALLOWED", name: "" }),
      })
    ).status,
    422,
  );

  const changedChampionship = await call("/championships/" + ID, {
    method: "PATCH",
    body: JSON.stringify({
      name: "Interlaje 2026",
      status: "FINISHED",
      currentSeasonYear: 2026,
      usesDivisions: true,
      defaultLocation: "Ginásio",
    }),
  });
  assert.equal(changedChampionship.status, 200);
  assert.ok(executedSql.some((statement) => statement.includes("UPDATE public.championships SET")));
  assert.equal(
    (
      await call("/championships/" + ID, {
        method: "PATCH",
        body: JSON.stringify({}),
      })
    ).status,
    422,
  );
  const readSeason = await call("/championships/" + ID + "/seasons/2026");
  assert.equal(readSeason.status, 200);

  const upsertSeason = await call("/championships/" + ID + "/seasons/2026", {
    method: "PUT",
    body: JSON.stringify({
      divisionFormat: "SEPARATED",
      divisionSettlementMode: "PROMOTION_RELEGATION",
      principalSlotsCount: 12,
      principalRelegationCount: 2,
      accessPromotionCount: 2,
      yellowCardResetPhase: "FINAL",
    }),
  });
  assert.equal(upsertSeason.status, 200);
  assert.ok(
    executedSql.some((statement) =>
      statement.includes("INSERT INTO public.championship_season_settings"),
    ),
  );

  const forbiddenAdvance = await call("/championships/" + ID + "/seasons/advance", {
    method: "POST",
  });
  assert.equal(forbiddenAdvance.status, 409);
  assert.equal(
    (forbiddenAdvance.body.error as Record<string, unknown>).code,
    "CHAMPIONSHIP_STATE_CONFLICT",
  );
  const resetSeason = await call("/championships/" + ID + "/seasons/2026/reset", {
    method: "POST",
  });
  assert.equal(resetSeason.status, 204);
  assert.ok(executedSql.some((statement) => statement.includes("DELETE FROM public.matches")));

  // Retornar ao agendamento desfaz a operação ao vivo e refaz a classificação.
  const returnedMatch = await call("/matches/" + ID + "/return-to-scheduled", {
    method: "POST",
  });
  assert.equal(returnedMatch.status, 200);
  assert.equal((returnedMatch.body.data as Record<string, unknown>).status, "SCHEDULED");
  assert.equal(
    (
      await call("/matches/" + ID + "/return-to-scheduled", {
        method: "POST",
      })
    ).status,
    409,
  );
  assert.ok(executedSql.some((statement) => statement.includes("DELETE FROM public.match_sets")));

  assert.ok(executedSql.some((statement) => statement.includes("public.matches")));
  assert.ok(executedSql.some((statement) => statement.includes("public.championships")));
});
