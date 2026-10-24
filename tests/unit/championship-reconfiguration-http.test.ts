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

const [{ database }, { createBracketOperationsRouter }, { errorHandler }] = await Promise.all([
  import("../../src/database/index.js"),
  import("../../src/modules/brackets/bracket-operations.routes.js"),
  import("../../src/common/middlewares/error-handler.middleware.js"),
]);

import type { AuthService } from "../../src/modules/auth/auth.service.js";
import type { DatabaseQueryExecutor, DatabaseRow } from "../../src/database/types.js";

const editionId = "f9444536-09c2-4c10-b3c3-a374744f9a4c";
const userId = "a6d2b658-dedc-4fbb-8143-18111cb130fe";
const principal = {
  userId,
  sessionId: "1998933e-8b57-412a-8f5a-a992cb8c4484",
  user: {
    id: userId,
    email: "qa@example.invalid",
    role: "admin" as const,
    profile: null,
    permissions: [{ scope: "matches", level: "EDIT" as const }],
    canAccessAdminPanel: true,
  },
};

test("LAJE-150 routes bracket reconfiguration preview and revision-locked apply to PostgreSQL", async (t) => {
  const queries: Array<{ sql: string; values: readonly unknown[] }> = [];
  let conflict = false;
  const query = async <Row extends DatabaseRow = DatabaseRow>(
    sql: string,
    values: readonly unknown[] = [],
  ) => {
    queries.push({ sql, values });
    if (sql.includes("FROM public.championship_bracket_editions WHERE id = $1")) {
      return { rows: [{ id: editionId }] as unknown as Row[], count: 1 };
    }
    if (sql.includes("preview_championship_bracket_reconfiguration")) {
      return {
        rows: [
          {
            result: {
              revision: 7,
              action: "DAY_SCHEDULE",
              affected_matches: 1,
              changes: [],
              blockers: [],
            },
          },
        ] as unknown as Row[],
        count: 1,
      };
    }
    if (sql.includes("apply_championship_bracket_reconfiguration")) {
      if (conflict) {
        throw Object.assign(new Error("revision conflict"), { code: "40001" });
      }
      return { rows: [{ result: null }] as unknown as Row[], count: 1 };
    }
    return { rows: [] as Row[], count: 0 };
  };

  t.mock.method(
    database,
    "transaction",
    async <T>(work: (executor: DatabaseQueryExecutor) => Promise<T>): Promise<T> =>
      work({ query }),
  );
  const authService = {
    authenticateAccessToken: async () => principal,
  } as unknown as AuthService;

  const app = express();
  app.use(express.json());
  app.use("/bracket-operations", createBracketOperationsRouter(authService));
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
  const root = "http://127.0.0.1:" + address.port + "/bracket-operations/";
  const headers = { authorization: "Bearer test", "content-type": "application/json" };
  const input = { editionId, action: "DAY_SCHEDULE", input: { schedule_updates: [] } };

  const preview = await fetch(root + "reconfiguration-preview", {
    method: "POST",
    headers,
    body: JSON.stringify(input),
  });
  assert.equal(preview.status, 200);
  assert.equal((await preview.json()).data.revision, 7);
  assert.ok(
    queries.some(
      ({ sql, values }) =>
        sql.includes("preview_championship_bracket_reconfiguration") &&
        values[0] === editionId &&
        values[1] === "DAY_SCHEDULE",
    ),
  );

  const apply = await fetch(root + "reconfiguration-apply", {
    method: "POST",
    headers,
    body: JSON.stringify({ ...input, expectedRevision: 7 }),
  });
  assert.equal(apply.status, 200);
  assert.ok(
    queries.some(
      ({ sql, values }) =>
        sql.includes("apply_championship_bracket_reconfiguration") && values[3] === 7,
    ),
  );

  conflict = true;
  const stale = await fetch(root + "reconfiguration-apply", {
    method: "POST",
    headers,
    body: JSON.stringify({ ...input, expectedRevision: 7 }),
  });
  assert.equal(stale.status, 409);
  assert.equal((await stale.json()).error.code, "RECONFIGURATION_REVISION_CONFLICT");

  const invalid = await fetch(root + "reconfiguration-preview", {
    method: "POST",
    headers,
    body: JSON.stringify({ ...input, action: "DROP_DATABASE" }),
  });
  assert.equal(invalid.status, 422);

  const missingRevision = await fetch(root + "reconfiguration-apply", {
    method: "POST",
    headers,
    body: JSON.stringify(input),
  });
  assert.equal(missingRevision.status, 422);
});

test("LAJE-150 denies reconfiguration without matches edit permission", async (t) => {
  const authService = {
    authenticateAccessToken: async () => ({
      ...principal,
      user: { ...principal.user, permissions: [{ scope: "matches", level: "VIEW" }] },
    }),
  } as unknown as AuthService;

  const app = express();
  app.use(express.json());
  app.use("/bracket-operations", createBracketOperationsRouter(authService));
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
  const root = "http://127.0.0.1:" + address.port + "/bracket-operations/";
  for (const operation of ["reconfiguration-preview", "reconfiguration-apply"]) {
    const response = await fetch(root + operation, {
      method: "POST",
      headers: { authorization: "Bearer test", "content-type": "application/json" },
      body: JSON.stringify({ editionId, action: "DAY_SCHEDULE", input: {}, expectedRevision: 1 }),
    });
    assert.equal(response.status, 403);
  }
});
