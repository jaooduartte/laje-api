import assert from "node:assert/strict";
import test from "node:test";

import { DatabaseClient } from "../../src/database/client.js";
import { createPostgresAdapter } from "../../src/database/postgres-adapter.js";

const databaseUrl = process.env.DATABASE_URL;

if (!databaseUrl) {
  throw new Error("DATABASE_URL is required to run PostgreSQL integration tests.");
}

function createTestDatabase(): DatabaseClient {
  return new DatabaseClient(
    createPostgresAdapter({
      url: databaseUrl,
      maxConnections: 2,
      idleTimeoutSeconds: 5,
      connectTimeoutSeconds: 5,
      shutdownTimeoutSeconds: 5,
      applicationName: "laje-api-integration-test",
    }),
  );
}

test("connects to PostgreSQL and executes parameterized queries", async (t) => {
  const database = createTestDatabase();
  t.after(async () => database.close());

  await database.checkConnection();
  const result = await database.query<{ value: number }>("SELECT $1::int AS value", [42]);

  assert.equal(result.rows[0]?.value, 42);
  assert.equal(result.count, 1);
});

test("executes work inside a PostgreSQL transaction", async (t) => {
  const database = createTestDatabase();
  t.after(async () => database.close());

  const value = await database.transaction(async (transaction) => {
    const result = await transaction.query<{ value: number }>("SELECT $1::int AS value", [7]);
    return result.rows[0]?.value;
  });

  assert.equal(value, 7);
});
