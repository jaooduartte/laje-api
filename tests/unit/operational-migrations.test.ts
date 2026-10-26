import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

const migrationName = "20261015030000_create_api_rate_limit_windows.sql";

test("LAJE-149 registers the rate limit table migration before the AWS API starts", async () => {
  const runner = await readFile(resolve("src/operations/apply-operational-migrations.ts"), "utf8");
  const migration = await readFile(resolve("infra/database/migrations", migrationName), "utf8");
  const realtimeMigrationIndex = runner.indexOf(
    '"20261013221800_port_realtime_read_rpc_dependencies.sql"',
  );
  const rateLimitMigrationIndex = runner.indexOf(`"${migrationName}"`);
  const nextMigrationIndex = runner.indexOf('"20261024180000_restore_match_finish_guards.sql"');

  assert.ok(realtimeMigrationIndex >= 0);
  assert.ok(rateLimitMigrationIndex > realtimeMigrationIndex);
  assert.ok(nextMigrationIndex > rateLimitMigrationIndex);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS public\.api_rate_limit_windows/i);
});
