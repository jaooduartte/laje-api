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

const [{ database }, { errorHandler }, { createAuthRouter }, { createMatchesRouter }, {
  createChampionshipsRouter,
}, { createPublicRuntimeRouter }, { createPublicAccessRouter }, { createLeagueEventsRouter }] =
  await Promise.all([
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
const permissions = ["control", "matches", "settings", "links", "events", "bracket_setup",
  "score_sheet_review", "championship_schedule"].map((scope) => ({ scope, level: "EDIT" as const }));
const principal = {
  userId: ADMIN_ID,
  sessionId: ID,
  user: { id: ADMIN_ID, email: "ci@example.invalid", role: "admin" as const, profile: null,
    permissions, canAccessAdminPanel: true },
};

const authService = {
  authenticateAccessToken: async (_token: string) => principal,
  createSession: async () => ({
    refreshToken: "synthetic-only-test",
    payload: { accessToken: "synthetic-jwt", tokenType: "Bearer", expiresAt: new Date().toISOString(),
      user: principal.user },
  }),
  revokeSession: async () => {},
  getRefreshCookieConfig: () => ({ secure: false, maxAgeMs: 10_000 }),
} as unknown as AuthService;

type TestResponse = { status: number; body: Record<string, unknown> };
const champ = { id: ID, code: "INTERLAJE", name: "Campeonato Sintético", status: "IN_PROGRESS",
  currentSeasonYear: 2026, usesDivisions: false, defaultLocation: null };

test("LAJE-38 HTTP controller coverage uses only synthetic database adapters", async (t) => {
  const executedSql: string[] = [];
  let status = "SCHEDULED";
  let homeScore = 0;
  let awayScore = 0;
  const match = () => ({
    id: ID, championshipId: ID, seasonYear: 2026, sportId: ID,
    homeTeamId: ID, awayTeamId: ADMIN_ID, status, homeScore, awayScore,
    naipe: "MASCULINO", division: null, courtName: "Ginásio",
    scheduledDate: "2026-10-30", totalCount: 1,
  });

  const query = async <Row extends DatabaseRow = DatabaseRow>(
    statement: string,
    _parameters?: readonly unknown[],
  ): Promise<{ rows: Row[]; count: number }> => {
    executedSql.push(statement);
    let rows: Record<string, unknown>[] = [];
    if (/UPDATE public.matches SET/.test(statement) || /UPDATE public.matches\s+SET/.test(statement)) {
      if (/status = 'LIVE'/.test(statement)) status = "LIVE";
      if (/status = 'FINISHED'/.test(statement)) status = "FINISHED";
      if (/status = 'SCHEDULED'/.test(statement)) status = "SCHEDULED";
      rows = [{ id: ID }];
    } else if (/FROM public.matches m/.test(statement) && /JOIN public.championships/.test(statement)) {
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
  t.mock.method(database, "transaction", async <T>(
    work: (executor: DatabaseQueryExecutor) => Promise<T>,
  ): Promise<T> => work({ query }));

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
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  }));
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const origin = `http://127.0.0.1:${address.port}`;

  async function call(path: string, options: RequestInit = {}): Promise<TestResponse> {
    const response = await fetch(origin + path, {
      ...options, headers: { "content-type": "application/json", authorization: "Bearer test", ...options.headers },
    });
    const body = (response.status === 204 ? {} : await response.json()) as Record<string, unknown>;
    return { status: response.status, body };
  }
  function jsonBody(response: TestResponse): { data?: Record<string, unknown> | Record<string, unknown>[] } {
    assert.equal(response.status, 200);
    return response.body;
  }

  // Public browsing includes full list/query paths and input validation.
  assert.equal((jsonBody(await call("/matches")).data as unknown[]).length, 1);
  assert.equal((jsonBody(await call("/matches/" + ID)).data as Record<string, unknown>).id, ID);
  assert.equal((jsonBody(await call("/championships")).data as unknown[]).length, 1);
  assert.equal((jsonBody(await call("/championships/" + ID)).data as Record<string, unknown>).id, ID);
  assert.equal((await call("/matches?status=WRONG")).status, 422);
  assert.equal((await call("/championships/" + ID + "/calendar?seasonYear=2026")).status, 200);

  // Authenticated control traverses scheduling, scoreboard and completion handlers.
  const started = await call("/matches/" + ID + "/start", { method: "POST" });
  assert.equal(started.status, 200);
  assert.equal((started.body.data as Record<string, unknown>).status, "LIVE");
  const score = await call("/matches/" + ID + "/scoreboard", {
    method: "PATCH", body: JSON.stringify({ homeScore: 2, awayScore: 1 }),
  });
  assert.equal(score.status, 200);
  assert.equal((score.body.data as Record<string, unknown>).status, "LIVE");
  const invalid = await call("/matches/" + ID + "/scoreboard", {
    method: "PATCH", body: JSON.stringify({ homeScore: -1 }),
  });
  assert.equal(invalid.status, 422);
  const finished = await call("/matches/" + ID + "/finish", {
    method: "POST", body: JSON.stringify({}),
  });
  assert.equal(finished.status, 200);
  assert.equal((finished.body.data as Record<string, unknown>).status, "FINISHED");

  // The remaining public-resource reads are still tested with deterministic empty results.
  const publicPaths = [
    "/public-runtime/teams", "/public-runtime/sports",
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
    "/public/settings", "/public/links", "/public/links/admin",
    "/league-events", "/league-events/years", "/league-events/reservation-requests",
    "/league-events/reservation-requests/pending-count",
  ];
  for (const path of publicPaths) {
    const result = await call(path);
    assert.equal(result.status, 200, `Expected successful read-only endpoint ${path}: ${JSON.stringify(result.body)}`);
  }
  assert.ok(executedSql.some((statement) => statement.includes("public.matches")));
  assert.ok(executedSql.some((statement) => statement.includes("public.championships")));
});
