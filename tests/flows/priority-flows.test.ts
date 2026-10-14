import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";

process.env.NODE_ENV = "test";
process.env.PORT = "3000";
process.env.CORS_ORIGINS = "http://localhost:8080";
process.env.AUTH_ENABLED = "true";
process.env.AUTH_JWT_SECRET = "laje-38-synthetic-ci-jwt-secret-at-least-32-characters";
process.env.AUTH_JWT_EXPIRES_IN = "15m";
process.env.AWS_ENABLED = "false";
process.env.MAIL_ENABLED = "false";

const { hashPassword } = await import("../../src/modules/auth/auth.crypto.js");
const { database } = await import("../../src/database/index.js");
const { app } = await import("../../src/app.js");

const IDS = {
  championship: "f3d55f5c-32a9-44f4-afcf-dbe6e59da001",
  sport: "f3d55f5c-32a9-44f4-afcf-dbe6e59da002",
  home: "f3d55f5c-32a9-44f4-afcf-dbe6e59da003",
  away: "f3d55f5c-32a9-44f4-afcf-dbe6e59da004",
  match: "f3d55f5c-32a9-44f4-afcf-dbe6e59da005",
  profile: "f3d55f5c-32a9-44f4-afcf-dbe6e59da006",
  operator: "f3d55f5c-32a9-44f4-afcf-dbe6e59da007",
} as const;

const password = "Laje38-test-password-2026";

type ApiPayload = {
  data?: Record<string, unknown> | Record<string, unknown>[];
  error?: { code: string; message: string };
  meta?: { total: number };
};

function rows(payload: ApiPayload): Record<string, unknown>[] {
  assert.ok(Array.isArray(payload.data), "Expected an array response");
  return payload.data;
}

async function seedFixture(): Promise<void> {
  const hash = await hashPassword(password);
  await database.query(
    "INSERT INTO public.championships (id, code, name, status, current_season_year) VALUES ($1, 'INTERLAJE', 'LAJE-38 Synthetic Interlaje', 'IN_PROGRESS', 2026)",
    [IDS.championship],
  );
  await database.query(
    "INSERT INTO public.sports (id, name, code, default_match_duration_minutes) VALUES ($1, 'Futsal LAJE-38', 'FUTSAL', 60)",
    [IDS.sport],
  );
  for (const [id, name] of [[IDS.home, "Synthetic Home"], [IDS.away, "Synthetic Away"]]) {
    await database.query("INSERT INTO public.teams (id, name) VALUES ($1, $2)", [id, name]);
  }
  await database.query(
    "INSERT INTO public.championship_sports (championship_id, sport_id, default_match_duration_minutes) VALUES ($1, $2, 60)",
    [IDS.championship, IDS.sport],
  );
  await database.query(
    "INSERT INTO public.matches (id, championship_id, sport_id, home_team_id, away_team_id, season_year, scheduled_date, queue_position, status) VALUES ($1,$2,$3,$4,$5,2026,'2026-10-30',1,'SCHEDULED')",
    [IDS.match, IDS.championship, IDS.sport, IDS.home, IDS.away],
  );
  await database.query(
    "INSERT INTO public.admin_profiles (id, name, is_system, system_role) VALUES ($1, 'LAJE-38 Synthetic Admin', true, 'admin')",
    [IDS.profile],
  );
  await database.query(
    "INSERT INTO public.admin_profile_permissions (profile_id, admin_tab, access_level) VALUES ($1,'control','EDIT')",
    [IDS.profile],
  );
  await database.query(
    "INSERT INTO public.admin_user_profiles (user_id, profile_id, login_identifier, password_status, name) VALUES ($1,$2,'laje38-ci','ACTIVE','Synthetic Operator')",
    [IDS.operator, IDS.profile],
  );
  await database.query(
    "INSERT INTO public.admin_auth_accounts (user_id, email, password_hash) VALUES ($1,'laje38@example.invalid',$2)",
    [IDS.operator, hash],
  );
}

test("LAJE-38 completes login, live operations, standings and calendar on isolated PostgreSQL", async (t) => {
  assert.match(process.env.DATABASE_URL ?? "", /laje_priority_flows/);
  await seedFixture();

  const server = app.listen(0, "127.0.0.1");
  t.after(async () => {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
    await database.close();
  });
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const apiBase = `http://127.0.0.1:${address.port}/api/v1`;

  async function call(path: string, init: RequestInit = {}): Promise<{ status: number; payload: ApiPayload }> {
    const response = await fetch(`${apiBase}${path}`, {
      ...init,
      headers: { "content-type": "application/json", ...init.headers },
    });
    const payload = (response.status === 204 ? {} : await response.json()) as ApiPayload;
    return { status: response.status, payload };
  }

  // 1. Login => JWT => authorized admin profile, then session revocation.
  const invalidLogin = await call("/auth/sessions", {
    method: "POST",
    body: JSON.stringify({ loginIdentifier: "laje38-ci", password: "invalid" }),
  });
  assert.equal(invalidLogin.status, 401);
  assert.equal(invalidLogin.payload.error?.code, "INVALID_CREDENTIALS");

  const login = await call("/auth/sessions", {
    method: "POST",
    body: JSON.stringify({ loginIdentifier: "laje38-ci", password }),
  });
  assert.equal(login.status, 200);
  assert.ok(login.payload.data && !Array.isArray(login.payload.data));
  const token = login.payload.data.accessToken;
  assert.equal(typeof token, "string");

  const authorized = { authorization: `Bearer ${token}` };
  const me = await call("/auth/me", { headers: authorized });
  assert.equal(me.status, 200);
  assert.ok(me.payload.data && !Array.isArray(me.payload.data));
  assert.equal(me.payload.data.canAccessAdminPanel, true);

  // 2. Start -> scoreboard -> finish -> derived classification update.
  const anonymousWrite = await call(`/matches/${IDS.match}/start`, { method: "POST" });
  assert.equal(anonymousWrite.status, 401);

  const started = await call(`/matches/${IDS.match}/start`, { method: "POST", headers: authorized });
  assert.equal(started.status, 200);
  assert.ok(started.payload.data && !Array.isArray(started.payload.data));
  assert.equal(started.payload.data.status, "LIVE");

  const scoreboard = await call(`/matches/${IDS.match}/scoreboard`, {
    method: "PATCH",
    headers: authorized,
    body: JSON.stringify({ homeScore: 2, awayScore: 1 }),
  });
  assert.equal(scoreboard.status, 200);
  assert.ok(scoreboard.payload.data && !Array.isArray(scoreboard.payload.data));
  assert.equal(scoreboard.payload.data.homeScore, 2);

  const finished = await call(`/matches/${IDS.match}/finish`, {
    method: "POST",
    headers: authorized,
    body: JSON.stringify({ homeScore: 2, awayScore: 1 }),
  });
  assert.equal(finished.status, 200);
  assert.ok(finished.payload.data && !Array.isArray(finished.payload.data));
  assert.equal(finished.payload.data.status, "FINISHED");
  const invalidFinish = await call(`/matches/${IDS.match}/finish`, {
    method: "POST",
    headers: authorized,
    body: JSON.stringify({}),
  });
  assert.equal(invalidFinish.status, 409);

  // 3. Public championships, standings and calendar use persisted data.
  const championships = await call("/championships");
  assert.equal(championships.status, 200);
  assert.ok(rows(championships.payload).some((item) => item.id === IDS.championship));

  const calendar = await call(`/championships/${IDS.championship}/calendar?seasonYear=2026`);
  assert.equal(calendar.status, 200);
  assert.equal(calendar.payload.meta?.total, 1);
  assert.equal(rows(calendar.payload)[0]?.status, "FINISHED");

  const standing = await call(`/championships/${IDS.championship}/standings?seasonYear=2026`);
  assert.equal(standing.status, 200);
  assert.ok(rows(standing.payload).some((item) => item.teamId === IDS.home && item.points === 3));

  const revoke = await call("/auth/sessions/current", { method: "DELETE", headers: authorized });
  assert.equal(revoke.status, 204);
  const expired = await call("/auth/me", { headers: authorized });
  assert.equal(expired.status, 401);
});
