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

const [{ database }, { errorHandler }, { createRealtimeReadRouter }, { SNAPSHOTS }] = await Promise.all([
  import("../../src/database/index.js"),
  import("../../src/common/middlewares/error-handler.middleware.js"),
  import("../../src/modules/realtime-read/realtime-read.routes.js"),
  import("../../src/modules/realtime-read/realtime-read.queries.js"),
]);

const ID = "b37e22a1-8181-43b2-98a1-29db7e864f0a";
const auth = {
  authenticateAccessToken: async () => ({
    userId: ID, sessionId: ID, user: {
      id: ID, email: "synthetic@example.invalid", role: "admin",
      profile: null, canAccessAdminPanel: true,
      permissions: ["matches", "bracket_setup"].map(
        (scope) => ({ scope, level: "EDIT" }),
      ),
    },
  }),
} as unknown as AuthService;

test("LAJE-38 validates allowlisted realtime snapshots and authorization", async (t) => {
  const calls: { sql: string; params?: readonly unknown[] }[] = [];
  t.mock.method(database, "query", async (sql: string, params?: readonly unknown[]) => {
    calls.push({ sql, ...(params === undefined ? {} : { params }) });
    return { rows: [{ data: [] }], count: 1 };
  });

  const app = express();
  app.use("/", createRealtimeReadRouter(auth));
  app.use(errorHandler);
  const server = app.listen(0, "127.0.0.1");
  t.after(() => new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  }));
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const url = `http://127.0.0.1:${address.port}`;

  for (const name of Object.keys(SNAPSHOTS)) {
    const isAdmin = name === "pending-award-draws" || name === "pending-tie-breaks";
    const extra = name === "interlaje-competition-standings" ? `&sportId=${ID}&naipe=MASCULINO` : "";
    const path = `/${ID}/${name}?seasonYear=2026${extra}`;
    const response = await fetch(url + path, {
      headers: isAdmin ? { authorization: "Bearer synthetic" } : {},
    });
    assert.equal(response.status, 200, name);
    assert.deepEqual((await response.json() as { data: unknown[] }).data, []);
    assert.equal(response.headers.get("cache-control"), "private, no-store");
    if (isAdmin) {
      const denied = await fetch(url + path);
      assert.equal(denied.status, 401);
    }
  }
  assert.equal(calls.length, Object.keys(SNAPSHOTS).length);
  assert.ok(calls.every(({ sql }) => /^SELECT /.test(sql) && sql.includes("public.")));
  assert.equal((await fetch(url + "/" + ID + "/yellow-card-discipline")).status, 422);
});
