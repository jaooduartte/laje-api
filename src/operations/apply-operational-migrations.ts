import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { database } from "../database/index.js";
import type { DatabaseQueryExecutor } from "../database/types.js";

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

export function splitSqlStatements(script: string): string[] {
  const statements: string[] = [];
  let current = "";
  let index = 0;
  let singleQuoted = false;
  let doubleQuoted = false;
  let lineComment = false;
  let blockCommentDepth = 0;
  let dollarTag: string | null = null;

  while (index < script.length) {
    const character = script[index]!;
    const next = script[index + 1] ?? "";

    if (lineComment) {
      current += character;
      if (character === "\n") lineComment = false;
      index += 1;
      continue;
    }

    if (blockCommentDepth > 0) {
      current += character;
      if (character === "/" && next === "*") {
        current += next;
        blockCommentDepth += 1;
        index += 2;
        continue;
      }
      if (character === "*" && next === "/") {
        current += next;
        blockCommentDepth -= 1;
        index += 2;
        continue;
      }
      index += 1;
      continue;
    }

    if (dollarTag) {
      if (script.startsWith(dollarTag, index)) {
        current += dollarTag;
        index += dollarTag.length;
        dollarTag = null;
      } else {
        current += character;
        index += 1;
      }
      continue;
    }

    if (singleQuoted) {
      current += character;
      if (character === "'" && next === "'") {
        current += next;
        index += 2;
        continue;
      }
      if (character === "'") singleQuoted = false;
      index += 1;
      continue;
    }

    if (doubleQuoted) {
      current += character;
      if (character === '"' && next === '"') {
        current += next;
        index += 2;
        continue;
      }
      if (character === '"') doubleQuoted = false;
      index += 1;
      continue;
    }

    if (character === "-" && next === "-") {
      current += character + next;
      lineComment = true;
      index += 2;
      continue;
    }

    if (character === "/" && next === "*") {
      current += character + next;
      blockCommentDepth = 1;
      index += 2;
      continue;
    }

    if (character === "'") {
      current += character;
      singleQuoted = true;
      index += 1;
      continue;
    }

    if (character === '"') {
      current += character;
      doubleQuoted = true;
      index += 1;
      continue;
    }

    if (character === "$") {
      const match = script.slice(index).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/);
      if (match) {
        dollarTag = match[0];
        current += dollarTag;
        index += dollarTag.length;
        continue;
      }
    }

    if (character === ";") {
      const statement = current.trim();
      if (statement) statements.push(statement);
      current = "";
      index += 1;
      continue;
    }

    current += character;
    index += 1;
  }

  const trailing = current.trim();
  if (trailing) statements.push(trailing);

  if (singleQuoted || doubleQuoted || dollarTag || blockCommentDepth > 0) {
    throw new Error("Operational migration contains an unterminated SQL literal or comment.");
  }

  return statements;
}

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
