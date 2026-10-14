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

const [{ database }, { errorHandler }, { createCalendarSubscriptionRouter }] = await Promise.all([
  import("../../src/database/index.js"),
  import("../../src/common/middlewares/error-handler.middleware.js"),
  import("../../src/modules/calendar-subscription/calendar-subscription.routes.js"),
]);

const ID = "b37e22a1-8181-43b2-98a1-29db7e864f0a";

test("LAJE-38 covers subscription scopes, cache revalidation and access restrictions", async (t) => {
  let blocked = false;
  const statements: string[] = [];
  t.mock.method(database, "query", async (statement: string) => {
    statements.push(statement);
    if (statement.includes("is_public_access_blocked")) {
      return {
        rows: [{ isPublicAccessBlocked: blocked, isSchedulePageBlocked: false }],
        count: 1,
      };
    }
    if (statement.includes("FROM public.matches m")) {
      return {
        rows: [{
          id: ID, championshipId: ID, seasonYear: 2026, sportId: ID,
          naipe: "MASCULINO", division: null, location: "Ginásio", courtName: "Quadra 1",
          startTime: "2027-01-01T12:00:00.000Z", endTime: "2027-01-01T13:00:00.000Z",
          createdAt: "2026-10-01T00:00:00.000Z", updatedAt: "2026-10-01T00:00:00.000Z",
          championshipName: "Interlaje", sportName: "Futsal", homeTeamName: "Casa",
          awayTeamName: "Visitante", durationMinutes: 60,
        }],
        count: 1,
      };
    }
    if (statement.includes("FROM public.championship_individual_sessions s")) {
      return {
        rows: [{
          id: ID, seasonYear: 2026, naipe: "FEMININO", division: null,
          scheduledDate: "2027-01-02", startTime: "12:00:00", endTime: "13:30:00",
          locationName: "Ginásio", courtName: "Piscina", sportName: "Natação",
          createdAt: "2026-10-01T00:00:00.000Z", updatedAt: "2026-10-01T00:00:00.000Z",
        }],
        count: 1,
      };
    }
    return { rows: [], count: 0 };
  });

  const app = express();
  app.use("/", createCalendarSubscriptionRouter());
  app.use(errorHandler);
  const server = app.listen(0, "127.0.0.1");
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  }));
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const url = `http://127.0.0.1:${address.port}/?`;
  const root = `championship_id=${ID}&season_year=2026`;
  const scopes = [
    `scope=MATCH&match_id=${ID}`,
    `scope=SESSION&session_id=${ID}`,
    `scope=SPORT_NAIPE&sport_id=${ID}&naipe=MASCULINO`,
    `scope=TEAM&team_id=${ID}`,
    `scope=TEAM_MATCHES&team_id=${ID}`,
    `scope=TEAM_SPORT_NAIPE&team_id=${ID}&sport_id=${ID}&naipe=MASCULINO`,
  ];

  for (const scope of scopes) {
    const response = await fetch(url + root + "&" + scope);
    assert.equal(response.status, 200, scope);
    assert.match(response.headers.get("content-type") ?? "", /text\/calendar/);
    const contents = await response.text();
    assert.ok(contents.includes("BEGIN:VCALENDAR"));
    assert.ok(contents.includes("END:VCALENDAR"));
    assert.ok(contents.includes("BEGIN:VEVENT"));
    const etag = response.headers.get("etag");
    assert.ok(etag);
    const cached = await fetch(url + root + "&" + scope, {
      headers: { "if-none-match": etag },
    });
    assert.equal(cached.status, 304);
  }

  const download = await fetch(url + root + `&scope=MATCH&match_id=${ID}&download=1`);
  assert.match(download.headers.get("content-disposition") ?? "", /attachment/);
  assert.equal((await fetch(url + "scope=MATCH")).status, 400);
  blocked = true;
  assert.equal((await fetch(url + root + `&scope=MATCH&match_id=${ID}`)).status, 404);
  assert.ok(statements.some((sql) => sql.includes("FROM public.matches m")));
  assert.ok(statements.some((sql) => sql.includes("FROM public.championship_individual_sessions s")));
});
