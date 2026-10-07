import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { database } from "../database/index.js";

const MIGRATIONS = ["20261007160000_create_championship_bracket_preview_jobs.sql"] as const;

async function main(): Promise<void> {
  await database.checkConnection();

  for (const migration of MIGRATIONS) {
    const path = resolve(process.cwd(), "infra", "database", "migrations", migration);
    const script = await readFile(path, "utf8");
    console.log(`Applying operational migration ${migration}`);
    const statements = script
      .split(/;\s*(?:\n|$)/)
      .map((statement) => statement.trim())
      .filter(Boolean);

    for (const statement of statements) {
      await database.query(statement);
    }
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
