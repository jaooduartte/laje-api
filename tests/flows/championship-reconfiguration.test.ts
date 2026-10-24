import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";

process.env.NODE_ENV = "test";
process.env.PORT = "3000";
process.env.CORS_ORIGINS = "http://localhost:8080";
process.env.AUTH_ENABLED = "true";
process.env.AUTH_JWT_SECRET = "laje-150-reconfiguration-test-secret-at-least-32-characters";
process.env.AUTH_JWT_EXPIRES_IN = "15m";
process.env.AWS_ENABLED = "false";
process.env.MAIL_ENABLED = "false";

const [{ hashPassword }, { database }, { app }] = await Promise.all([
  import("../../src/modules/auth/auth.crypto.js"),
  import("../../src/database/index.js"),
  import("../../src/app.js"),
]);

const IDS = {
  championship: "e0be193d-a2d6-4919-bb95-3cb18d7e0001",
  edition: "e0be193d-a2d6-4919-bb95-3cb18d7e0002",
  profile: "e0be193d-a2d6-4919-bb95-3cb18d7e0003",
  operator: "e0be193d-a2d6-4919-bb95-3cb18d7e0004",
} as const;

test("LAJE-150 performs real PostgreSQL preview and revision-guarded application without Supabase", async (t) => {
  assert.match(process.env.DATABASE_URL ?? "", /laje_priority_flows/);
  await database.query(
    "INSERT INTO public.championships (id, code, name, status, current_season_year) VALUES ($1, 'CLV', 'LAJE-150 Reconfiguration Test', 'REVIEW', 2026)",
    [IDS.championship],
  );
  await database.query(
    "INSERT INTO public.championship_bracket_editions (id, championship_id, season_year, status) VALUES ($1,$2,2026,'GROUPS_GENERATED')",
    [IDS.edition, IDS.championship],
  );
  await database.query(
    "INSERT INTO public.admin_profiles (id, name, is_system) VALUES ($1, 'LAJE-150 Admin', false)",
    [IDS.profile],
  );
  for (const tab of ["control", "matches", "championship_schedule"]) {
    await database.query(
      "INSERT INTO public.admin_profile_permissions (profile_id, admin_tab, access_level) VALUES ($1, $2::public.admin_panel_tab, 'EDIT')",
      [IDS.profile, tab],
    );
  }
  await database.query(
    "INSERT INTO public.admin_user_profiles (user_id, profile_id, login_identifier, password_status, name) VALUES ($1,$2,'laje150-ci','ACTIVE','Reconfiguration Admin')",
    [IDS.operator, IDS.profile],
  );
  await database.query(
    "INSERT INTO public.admin_auth_accounts (user_id, email, password_hash) VALUES ($1,'laje150@example.invalid',$2)",
    [IDS.operator, await hashPassword("LAJE-150-2026-Postgres-Check")],
  );

  const server = app.listen(0, "127.0.0.1");
  t.after(async () => {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
    await database.close();
  });
  await once(server, "listening");
  const addr = server.address();
  assert.ok(addr && typeof addr === "object");

  const base = `http://127.0.0.1:${addr.port}/api/v1`;
  const login = await fetch(base + "/auth/sessions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      loginIdentifier: "laje150-ci",
      password: "LAJE-150-2026-Postgres-Check",
    }),
  });
  assert.equal(login.status, 200);
  const token = (await login.json()).data.accessToken;
  assert.equal(typeof token, "string");

  const path = base + "/bracket-operations/";
  const request = {
    editionId: IDS.edition,
    action: "DAY_SCHEDULE",
    input: { schedule_updates: [] },
  };
  const send = (operation: string, body: Record<string, unknown>, authorized = true) =>
    fetch(path + operation, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(authorized ? { authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    });

  assert.equal((await send("reconfiguration-preview", request, false)).status, 401);
  const before = await database.query(
    "SELECT reprogramming_revision FROM public.championship_bracket_editions WHERE id = $1",
    [IDS.edition],
  );
  const revision = Number(before.rows[0]?.reprogramming_revision);
  assert.equal(revision, 0);

  const preview = await send("reconfiguration-preview", request);
  assert.equal(preview.status, 200);
  const result = (await preview.json()).data;
  assert.equal(Number(result.revision), revision);
  assert.equal(result.action, "DAY_SCHEDULE");
  assert.deepEqual(result.blockers, []);

  const afterPreview = await database.query(
    "SELECT reprogramming_revision FROM public.championship_bracket_editions WHERE id = $1",
    [IDS.edition],
  );
  assert.equal(Number(afterPreview.rows[0]?.reprogramming_revision), revision);

  const applied = await send("reconfiguration-apply", { ...request, expectedRevision: revision });
  assert.equal(applied.status, 200);
  const conflict = await send("reconfiguration-apply", {
    ...request,
    expectedRevision: revision + 1,
  });
  assert.equal(conflict.status, 409);
  assert.equal((await conflict.json()).error.code, "RECONFIGURATION_REVISION_CONFLICT");
});
