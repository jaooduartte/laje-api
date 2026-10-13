import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import test from "node:test";

import { splitSqlStatements } from "../../src/operations/sql-script.js";

const migrationPath = resolve(
  "infra/database/migrations/20261013221800_port_realtime_read_rpc_dependencies.sql",
);

const rootSnapshots = [
  "get_championship_award_pending_draws",
  "get_championship_bracket_pending_tie_breaks",
  "get_championship_bracket_resolved_tie_break_orders",
  "get_championship_corrected_group_standings",
  "get_championship_score_sheet_awards_rankings",
  "get_championship_yellow_card_discipline",
  "get_interlaje_overall_standings",
  "get_interlaje_position_point_settings",
  "get_interlaje_regulation_competition_standings",
  "list_championship_competition_team_disqualifications",
];

test("LAJE-89 migration installs ten API snapshots and their transitive PostgreSQL helpers", async () => {
  const source = await readFile(migrationPath, "utf8");
  const statements = splitSqlStatements(source);
  const functions = statements.filter((sql) => sql.includes("CREATE OR REPLACE FUNCTION public."));

  assert.equal(functions.length, 23);
  for (const name of rootSnapshots) {
    assert.ok(
      functions.some((sql) => sql.includes(`CREATE OR REPLACE FUNCTION public.${name}(`)),
      `Missing RDS read function: ${name}`,
    );
  }
  assert.match(statements[0] ?? "", /SET LOCAL check_function_bodies = off/i);
  assert.match(statements.at(-1) ?? "", /SET LOCAL check_function_bodies = on/i);
});

test("LAJE-89 migration retains read-only SQL definitions and does not alter legacy migrations", async () => {
  const sql = await readFile(migrationPath, "utf8");
  const statements = splitSqlStatements(sql);
  const functions = statements.filter((statement) =>
    statement.includes("CREATE OR REPLACE FUNCTION public."),
  );

  for (const definition of functions) {
    assert.match(definition, /\b(CREATE OR REPLACE FUNCTION) public\.[a-z_]+\(/);
    assert.doesNotMatch(definition, /\b(?:INSERT INTO|DELETE FROM|TRUNCATE TABLE|DROP TABLE)\b/i);
  }
});
