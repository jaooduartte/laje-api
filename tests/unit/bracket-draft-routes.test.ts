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

const [{ database }, { createBracketRouter }, { errorHandler }] = await Promise.all([
  import("../../src/database/index.js"),
  import("../../src/modules/brackets/brackets.routes.js"),
  import("../../src/common/middlewares/error-handler.middleware.js"),
]);

import type { AuthService } from "../../src/modules/auth/auth.service.js";
import type { DatabaseQueryExecutor, DatabaseRow } from "../../src/database/types.js";

const CHAMPIONSHIP_ID = "c6435be1-43e0-4620-b912-648364749a10";
const USER_ID = "19c1b5ae-ffdb-4b36-bd62-a44f82c7d891";
const DRAFT_ID = "d5417725-66af-45e8-b6a0-39c44c9ae321";
const principal = {
  userId: USER_ID,
  sessionId: "9996e6b6-1a11-4f36-99bd-12849f883671",
  user: {
    id: USER_ID,
    email: "qa@example.invalid",
    role: "admin" as const,
    profile: null,
    permissions: [{ scope: "bracket_setup", level: "EDIT" as const }],
    canAccessAdminPanel: true,
  },
};

const authService = {
  authenticateAccessToken: async () => principal,
} as unknown as AuthService;

test("LAJE-150 reads and saves draft in AWS RDS adapter without invoking Supabase", async (t) => {
  let draft: Record<string, unknown> | null = null;
  let championshipStatus = "UPCOMING";
  const statements: string[] = [];

  const query = async <Row extends DatabaseRow = DatabaseRow>(
    statement: string,
    params: readonly unknown[] = [],
  ) => {
    statements.push(statement);
    let rows: Record<string, unknown>[] = [];
    if (statement.includes("FROM public.championships WHERE id = $1")) {
      rows = [{ seasonYear: 2026, status: championshipStatus }];
    } else if (statement.includes("SELECT id, status FROM public.championship_bracket_editions")) {
      rows = draft ? [{ id: DRAFT_ID, status: "DRAFT" }] : [];
    } else if (statement.includes("INSERT INTO public.championship_bracket_editions")) {
      draft = {
        edition_id: DRAFT_ID,
        season_year: 2026,
        status: "DRAFT",
        payload_snapshot: JSON.parse(String(params[2])),
        updated_by: USER_ID,
        updated_at: "2026-10-24T10:00:00.000Z",
        updated_by_name: "QA",
      };
    } else if (statement.includes("UPDATE public.championship_bracket_editions")) {
      if (draft) draft.payload_snapshot = JSON.parse(String(params[1]));
    } else if (statement.includes("FROM public.championship_bracket_editions e")) {
      rows = draft ? [draft] : [];
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
  app.use("/championships/:championshipId/bracket", createBracketRouter(authService));
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
  const path =
    "http://127.0.0.1:" + address.port + "/championships/" + CHAMPIONSHIP_ID + "/bracket/draft";

  const empty = await fetch(path, { headers: { authorization: "Bearer test" } });
  assert.equal(empty.status, 200);
  assert.deepEqual((await empty.json()).data, null);

  const payloadSnapshot = { schedule_days: [{ date: "2026-11-20" }], competitions: [] };
  const save = await fetch(path, {
    method: "PUT",
    headers: { authorization: "Bearer test", "content-type": "application/json" },
    body: JSON.stringify({ payloadSnapshot }),
  });
  assert.equal(save.status, 200);
  assert.deepEqual((await save.json()).data.payload_snapshot, payloadSnapshot);

  const get = await fetch(path, { headers: { authorization: "Bearer test" } });
  assert.equal(get.status, 200);
  assert.deepEqual((await get.json()).data.payload_snapshot, payloadSnapshot);

  const update = await fetch(path, {
    method: "PUT",
    headers: { authorization: "Bearer test", "content-type": "application/json" },
    body: JSON.stringify({ payloadSnapshot: { schedule_days: [] } }),
  });
  assert.equal(update.status, 200);
  assert.deepEqual((await update.json()).data.payload_snapshot, { schedule_days: [] });

  championshipStatus = "IN_PROGRESS";
  const closed = await fetch(path, {
    method: "PUT",
    headers: { authorization: "Bearer test", "content-type": "application/json" },
    body: JSON.stringify({ payloadSnapshot }),
  });
  assert.equal(closed.status, 409);
  assert.ok(statements.some((statement) => statement.includes("FOR UPDATE")));
});
