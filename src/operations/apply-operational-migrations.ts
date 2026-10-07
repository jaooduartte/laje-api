import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { database } from "../database/index.js";
import type { DatabaseQueryExecutor } from "../database/types.js";
import { splitSqlStatements } from "./sql-script.js";

const MIGRATIONS = [
  "20261007160300_drop_obsolete_public_preview_jobs.sql",
  "20261007160400_port_exact_preview_public_helpers.sql",
  "20261007160500_port_exact_preview_schema.sql",
  "20261007160600_port_exact_preview_functions_a_o.sql",
  "20261007160700_port_exact_preview_functions_p_r.sql",
  "20261007160800_port_exact_preview_functions_s_z.sql",
  "20261007160900_port_exact_preview_triggers.sql",
  "20261007161000_port_exact_preview_api_functions.sql",
] as const;

const MIGRATION_SCHEMA = "laje_api_internal";
const MIGRATION_TABLE = "operational_migrations";

async function ensureMigrationRegistry(): Promise<void> {
  await database.query(`CREATE SCHEMA IF NOT EXISTS ${MIGRATION_SCHEMA}`);
  await database.query(
    `CREATE TABLE IF NOT EXISTS ${MIGRATION_SCHEMA}.${MIGRATION_TABLE} (
       migration_name text PRIMARY KEY,
       applied_at timestamptz NOT NULL DEFAULT now()
     )`,
  );
}

async function isApplied(migration: string): Promise<boolean> {
  const result = await database.query(
    `SELECT 1
       FROM ${MIGRATION_SCHEMA}.${MIGRATION_TABLE}
       WHERE migration_name = $1
       LIMIT 1`,
    [migration],
  );
  return result.rows.length > 0;
}

async function applyMigration(
  migration: string,
  statements: string[],
): Promise<void> {
  await database.transaction(async (executor: DatabaseQueryExecutor) => {
    for (const statement of statements) {
      await executor.query(statement);
    }
    await executor.query(
      `INSERT INTO ${MIGRATION_SCHEMA}.${MIGRATION_TABLE} (migration_name)
       VALUES ($1)`,
      [migration],
    );
  });
}

async function main(): Promise<void> {
  await database.checkConnection();
  await ensureMigrationRegistry();

  for (const migration of MIGRATIONS) {
    if (await isApplied(migration)) {
      console.log(`Skipping already applied operational migration ${migration}`);
      continue;
    }

    const path = resolve(process.cwd(), "infra", "database", "migrations", migration);
    const script = await readFile(path, "utf8");
    const statements = splitSqlStatements(script);

    console.log(
      `Applying operational migration ${migration} (${statements.length} statement(s))`,
    );
    await applyMigration(migration, statements);
  }

  await database.close();
}

void main().catch(async (error: unknown) => {
  console.error("Operational migration failed.", error);
  try {
    await database.close();
  } catch {
    // The original migration error is authoritative.
  }
  process.exitCode = 1;
});
