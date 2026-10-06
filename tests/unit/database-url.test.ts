import assert from "node:assert/strict";
import test from "node:test";

import { resolveDatabaseUrl } from "../../src/config/database-url.js";

test("resolveDatabaseUrl keeps a valid DATABASE_URL unchanged", () => {
  const value = "postgresql://user:password@localhost:5432/laje?sslmode=disable";

  assert.deepEqual(resolveDatabaseUrl({ url: value }), {
    url: value,
    issues: [],
  });
});

test("resolveDatabaseUrl builds a PostgreSQL URL from discrete runtime secrets", () => {
  const result = resolveDatabaseUrl({
    host: "db.internal.example",
    port: "5432",
    database: "laje staging",
    user: "api@user",
    password: "p@ss:/?#word",
    sslMode: "require",
  });

  assert.deepEqual(result, {
    url: "postgresql://api%40user:p%40ss%3A%2F%3F%23word@db.internal.example:5432/laje%20staging?sslmode=require",
    issues: [],
  });
});

test("resolveDatabaseUrl defaults PostgreSQL port and TLS mode for AWS runtime", () => {
  const result = resolveDatabaseUrl({
    host: "database.internal",
    database: "laje_staging",
    user: "laje",
    password: "secret",
  });

  assert.equal(
    result.url,
    "postgresql://laje:secret@database.internal:5432/laje_staging?sslmode=require",
  );
  assert.deepEqual(result.issues, []);
});

test("resolveDatabaseUrl rejects incomplete discrete database configuration", () => {
  const result = resolveDatabaseUrl({
    host: "database.internal",
    database: "laje_staging",
  });

  assert.equal(result.url, undefined);
  assert.equal(result.issues.length, 1);
  assert.match(result.issues[0] ?? "", /DATABASE_URL is required unless/);
});

test("resolveDatabaseUrl rejects non-PostgreSQL direct URLs", () => {
  const result = resolveDatabaseUrl({ url: "https://example.com/database" });

  assert.equal(result.url, undefined);
  assert.deepEqual(result.issues, [
    "DATABASE_URL must use the postgres:// or postgresql:// protocol.",
  ]);
});
