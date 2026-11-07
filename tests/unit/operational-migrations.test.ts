import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";
import { splitSqlStatements } from "../../src/operations/sql-script.js";

const migrationName = "20261015030000_create_api_rate_limit_windows.sql";
const jobEventSequenceMigrationName = "20261104150000_fix_exact_preview_job_event_id_sequence.sql";
const courtPreferenceSyncMigrationName =
  "20261104170000_fix_bracket_court_preference_sync_helper.sql";
const estimatedStartTimeSettingMigrationName =
  "20261104180000_add_championship_sport_estimated_start_time_setting.sql";
const qualificationPoolRankingMigrationName =
  "20261105004000_fix_bracket_qualification_pool_ranking_recursion.sql";
const currentSeasonResetMigrationName =
  "20261106220454_reset_current_championship_season_to_planning.sql";

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

test("LAJE-149 registers the exact preview job event ID sequence repair", async () => {
  const runner = await readFile(resolve("src/operations/apply-operational-migrations.ts"), "utf8");
  const migration = await readFile(
    resolve("infra/database/migrations", jobEventSequenceMigrationName),
    "utf8",
  );
  const previousMigrationIndex = runner.indexOf(
    '"20261024213000_port_championship_review_reconfiguration.sql"',
  );
  const repairMigrationIndex = runner.indexOf(`"${jobEventSequenceMigrationName}"`);

  assert.ok(previousMigrationIndex >= 0);
  assert.ok(repairMigrationIndex > previousMigrationIndex);
  assert.match(
    migration,
    /ALTER COLUMN id\s+SET DEFAULT nextval\('championship_bracket_preview_private\.job_events_id_seq'::regclass\)/i,
  );
  assert.match(
    migration,
    /ALTER SEQUENCE championship_bracket_preview_private\.job_events_id_seq\s+OWNED BY championship_bracket_preview_private\.job_events\.id/i,
  );
});

test("LAJE-149 restores the bracket court preference synchronization helper", async () => {
  const runner = await readFile(resolve("src/operations/apply-operational-migrations.ts"), "utf8");
  const migration = await readFile(
    resolve("infra/database/migrations", courtPreferenceSyncMigrationName),
    "utf8",
  );
  const sequenceMigrationIndex = runner.indexOf(`"${jobEventSequenceMigrationName}"`);
  const courtPreferenceSyncMigrationIndex = runner.indexOf(`"${courtPreferenceSyncMigrationName}"`);
  const statements = splitSqlStatements(migration);

  assert.ok(sequenceMigrationIndex >= 0);
  assert.ok(courtPreferenceSyncMigrationIndex > sequenceMigrationIndex);
  assert.ok("sync_bracket_court_sport_preferences_base_v8".length <= 63);
  assert.match(
    migration,
    /CREATE OR REPLACE FUNCTION\s+public\.sync_bracket_court_sport_preferences_base_v8/i,
  );
  assert.match(migration, /pg_get_functiondef\(/i);
  assert.match(
    migration,
    /sync_championship_bracket_court_sport_preferences_before_structure_fix_v8/,
  );
  assert.match(migration, /sync_bracket_court_sport_preferences_base_v8/);
  assert.equal(statements.length, 4);
  assert.match(statements[2]!, /^DO \$migration\$/i);
});

test("LAJE-149 registers the estimated Beach Soccer start time setting for AWS", async () => {
  const runner = await readFile(resolve("src/operations/apply-operational-migrations.ts"), "utf8");
  const migration = await readFile(
    resolve("infra/database/migrations", estimatedStartTimeSettingMigrationName),
    "utf8",
  );
  const courtPreferenceMigrationIndex = runner.indexOf(`"${courtPreferenceSyncMigrationName}"`);
  const estimatedStartTimeMigrationIndex = runner.indexOf(
    `"${estimatedStartTimeSettingMigrationName}"`,
  );

  assert.ok(courtPreferenceMigrationIndex >= 0);
  assert.ok(estimatedStartTimeMigrationIndex > courtPreferenceMigrationIndex);
  assert.match(
    migration,
    /ADD COLUMN show_estimated_start_time_on_cards boolean NOT NULL DEFAULT false/i,
  );
  assert.match(migration, /normalize_sport_name\(sports\.name\) = 'beach soccer'/i);
});

test("repairs qualification pool ranking recursion caused by PostgreSQL name truncation", async () => {
  const runner = await readFile(resolve("src/operations/apply-operational-migrations.ts"), "utf8");
  const migration = await readFile(
    resolve("infra/database/migrations", qualificationPoolRankingMigrationName),
    "utf8",
  );
  const previousMigrationIndex = runner.indexOf(`"${estimatedStartTimeSettingMigrationName}"`);
  const repairMigrationIndex = runner.indexOf(`"${qualificationPoolRankingMigrationName}"`);
  const statements = splitSqlStatements(migration);

  assert.ok(previousMigrationIndex >= 0);
  assert.ok(repairMigrationIndex > previousMigrationIndex);
  assert.ok("get_championship_bracket_qualification_pool_rankings".length <= 63);
  assert.match(
    migration,
    /CREATE OR REPLACE FUNCTION\s+public\.get_championship_bracket_qualification_pool_rankings/i,
  );
  assert.match(migration, /get_championship_bracket_competition_qualification_pool_ranking\(/);
  assert.match(migration, /pg_get_functiondef\(/i);
  assert.match(
    migration,
    /old_helper_name CONSTANT text := 'get_championship_bracket_competition_qualification_pool_rankings\('/,
  );
  assert.match(
    migration,
    /new_helper_name CONSTANT text := 'get_championship_bracket_qualification_pool_rankings\('/,
  );
  assert.equal(statements.length, 3);
  assert.match(statements[2]!, /^DO \$migration\$/i);
});

test("registers the transactional current season reset status guard for the API database", async () => {
  const runner = await readFile(resolve("src/operations/apply-operational-migrations.ts"), "utf8");
  const migration = await readFile(
    resolve("infra/database/migrations", currentSeasonResetMigrationName),
    "utf8",
  );
  const previousMigrationIndex = runner.indexOf(
    '"20261105012000_fix_knockout_match_queue_position_conflicts.sql"',
  );
  const resetMigrationIndex = runner.indexOf(`"${currentSeasonResetMigrationName}"`);
  const statements = splitSqlStatements(migration);

  assert.ok(previousMigrationIndex >= 0);
  assert.ok(resetMigrationIndex > previousMigrationIndex);
  assert.equal(statements.length, 3);
  assert.match(migration, /allow_championship_planning_transition/i);
  assert.match(migration, /CREATE TRIGGER validate_championship_status_transition_trigger/i);
  assert.match(migration, /current_setting\('laje\.allow_championship_planning_transition'/i);
});
