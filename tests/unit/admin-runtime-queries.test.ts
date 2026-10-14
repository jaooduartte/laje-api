import assert from "node:assert/strict";
import { once } from "node:events";
import test from "node:test";
import express from "express";
import type { AuthService } from "../../src/modules/auth/auth.service.js";

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
  { createAdminRuntimeRouter },
  { createLeagueEventConflictsRouter },
] = await Promise.all([
  import("../../src/database/index.js"),
  import("../../src/common/middlewares/error-handler.middleware.js"),
  import("../../src/modules/admin-runtime/admin-runtime.routes.js"),
  import("../../src/modules/league-events/league-event-conflicts.routes.js"),
]);

const ID = "b37e22a1-8181-43b2-98a1-29db7e864f0a";
const auth = {
  authenticateAccessToken: async () => ({
    userId: ID,
    sessionId: ID,
    user: {
      id: ID,
      email: null,
      role: "admin",
      profile: null,
      canAccessAdminPanel: true,
      permissions: ["users", "logs"].map((scope) => ({ scope, level: "EDIT" })),
    },
  }),
} as unknown as AuthService;

test("LAJE-38 admin audit and conflict endpoints use parameterized read-only queries", async (t) => {
  const sql: string[] = [];
  t.mock.method(database, "query", async (statement: string) => {
    sql.push(statement);
    if (statement.includes("FROM public.admin_action_logs\n         WHERE")) {
      return { rows: [{ id: ID, totalCount: 1, actionType: "LOGIN" }], count: 1 };
    }
    return { rows: [], count: 0 };
  });
  const app = express();
  app.use("/admin-runtime", createAdminRuntimeRouter(auth));
  app.use("/league-events", createLeagueEventConflictsRouter());
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
  const url = `http://127.0.0.1:${address.port}`;

  const users = await fetch(url + "/admin-runtime/users", {
    headers: { authorization: "Bearer synthetic" },
  });
  assert.equal(users.status, 200);
  const userBody = (await users.json()) as { data: { users: unknown[]; profiles: unknown[] } };
  assert.deepEqual(userBody.data, { users: [], profiles: [] });

  const logs = await fetch(url + `/admin-runtime/logs?userId=${ID}&actionType=LOGIN&search=login`, {
    headers: { authorization: "Bearer synthetic" },
  });
  assert.equal(logs.status, 200);
  const logBody = (await logs.json()) as { data: { totalCount: number; logs: unknown[] } };
  assert.equal(logBody.data.totalCount, 1);
  assert.equal(logBody.data.logs.length, 1);
  assert.ok(
    sql.some((statement) => statement.includes("action_type = $2::public.admin_action_type")),
  );

  const conflict = await fetch(
    url + "/league-events/reservation-requests/conflicts?date=2026-10-30",
  );
  assert.equal(conflict.status, 200);
  assert.deepEqual(((await conflict.json()) as { data: unknown[] }).data, []);
  const invalid = await fetch(url + "/league-events/reservation-requests/conflicts");
  assert.equal(invalid.status, 422);
});
