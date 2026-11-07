import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import test from "node:test";

import type { Request, RequestHandler, Response } from "express";

const testDatabaseUrl = process.env.CHAMPIONSHIP_RESET_TEST_DATABASE_URL;
if (!testDatabaseUrl) {
  throw new Error("CHAMPIONSHIP_RESET_TEST_DATABASE_URL is required for reset integration tests.");
}

const parsedTestDatabaseUrl = new URL(testDatabaseUrl);
if (
  !["localhost", "127.0.0.1", "[::1]"].includes(parsedTestDatabaseUrl.hostname) ||
  parsedTestDatabaseUrl.pathname !== "/laje_season_reset_test"
) {
  throw new Error(
    "Championship reset integration tests only allow the local laje_season_reset_test database.",
  );
}

process.env.NODE_ENV = "test";
process.env.PORT = "3000";
process.env.DATABASE_URL = testDatabaseUrl;
process.env.CORS_ORIGINS = "http://localhost:8080";
process.env.AUTH_ENABLED = "false";
process.env.AWS_ENABLED = "false";
process.env.MAIL_ENABLED = "false";

const [{ database }, { CURRENT_SEASON_DELETE_OPERATIONS, createChampionshipsRouter }] =
  await Promise.all([
    import("../../src/database/index.js"),
    import("../../src/modules/championships/championships.routes.js"),
  ]);

const championshipId = randomUUID();
const editionId = randomUUID();
const competitionId = randomUUID();
const bracketMatchId = randomUUID();
const currentMatchId = randomUUID();
const previousMatchId = randomUUID();
const correctionId = randomUUID();
const sportId = randomUUID();
const homeTeamId = randomUUID();
const awayTeamId = randomUUID();
const publicLinkSectionId = randomUUID();
const publicLinkItemId = randomUUID();
const publicLinkItemFilterId = randomUUID();
const seasonYear = 2098;

function createRouter() {
  const principal = {
    userId: "60a76e3b-72bd-499b-9da1-cc624470c596",
    sessionId: "f54a1750-0fee-40c6-921d-4662c22065d5",
    user: {
      id: "60a76e3b-72bd-499b-9da1-cc624470c596",
      name: "PostgreSQL reset integration",
      email: "reset-integration@example.invalid",
      role: "admin" as const,
      profile: null,
      permissions: [{ scope: "settings", level: "EDIT" as const }],
      canAccessAdminPanel: true,
    },
  };
  const authService = {
    authenticateAccessToken: async () => principal,
  };
  return createChampionshipsRouter(authService as never) as unknown as {
    stack: Array<{
      route?: {
        path: string;
        methods: Record<string, boolean>;
        stack: Array<{ handle: RequestHandler }>;
      };
    }>;
  };
}

function invokeResetRoute(): Promise<{ statusCode: number }> {
  const router = createRouter();
  const path = "/:championshipId/seasons/:seasonYear/reset-to-planning";
  const routeLayer = router.stack.find(
    (layer) => layer.route?.path === path && layer.route.methods.post,
  );
  assert.ok(routeLayer?.route);
  const route = routeLayer.route;

  return new Promise((resolve, reject) => {
    const response = {
      statusCode: 200,
      status(code: number) {
        this.statusCode = code;
        return this;
      },
      json() {
        resolve({ statusCode: this.statusCode });
        return this;
      },
      send() {
        resolve({ statusCode: this.statusCode });
        return this;
      },
    };
    const request = {
      method: "POST",
      params: { championshipId, seasonYear: String(seasonYear) },
      body: {},
      header: (name: string) =>
        name.toLowerCase() === "authorization" ? "Bearer integration-token" : undefined,
    };
    const dispatch = (index: number): void => {
      const handler = route.stack[index];
      if (!handler) {
        resolve({ statusCode: response.statusCode });
        return;
      }
      try {
        const result = handler.handle(
          request as unknown as Request,
          response as unknown as Response,
          (error?: unknown) => {
            if (error) {
              reject(error);
              return;
            }
            dispatch(index + 1);
          },
        );
        Promise.resolve(result).catch(reject);
      } catch (error) {
        reject(error);
      }
    };
    dispatch(0);
  });
}

async function insertFixtures() {
  await database.transaction(async (transaction) => {
    await transaction.query(
      `INSERT INTO public.championships
        (id, code, name, status, current_season_year, uses_divisions)
       VALUES ($1, 'CLV'::public.championship_code, $2, 'IN_PROGRESS'::public.championship_status, $3, false)`,
      [championshipId, `reset integration ${championshipId}`, seasonYear],
    );
    await transaction.query(
      `INSERT INTO public.public_link_sections (id, name)
       VALUES ($1, $2)`,
      [publicLinkSectionId, `reset link section ${publicLinkSectionId}`],
    );
    await transaction.query(
      `INSERT INTO public.public_link_items
        (id, section_id, display_name, url, filter_mode)
       VALUES ($1, $2, $3, $4, 'BY_CHAMPIONSHIP_YEAR'::public.public_link_filter_mode)`,
      [
        publicLinkItemId,
        publicLinkSectionId,
        `reset link item ${publicLinkItemId}`,
        "https://example.invalid/reset-integration",
      ],
    );
    await transaction.query(
      `INSERT INTO public.public_link_item_filters
        (id, public_link_item_id, championship_id, season_year)
       VALUES ($1, $2, $3, $4)`,
      [publicLinkItemFilterId, publicLinkItemId, championshipId, seasonYear],
    );
    await transaction.query(
      `INSERT INTO public.teams (id, name)
       VALUES ($1, $2), ($3, $4)`,
      [homeTeamId, `reset home ${homeTeamId}`, awayTeamId, `reset away ${awayTeamId}`],
    );
    await transaction.query(
      `INSERT INTO public.sports (id, name, default_match_duration_minutes)
       VALUES ($1, $2, 30)`,
      [sportId, `reset sport ${sportId}`],
    );
    await transaction.query(
      `INSERT INTO public.matches
        (id, sport_id, home_team_id, away_team_id, championship_id, season_year)
       VALUES
        ($1, $3, $4, $5, $6, $7),
        ($2, $3, $4, $5, $6, $8)`,
      [
        currentMatchId,
        previousMatchId,
        sportId,
        homeTeamId,
        awayTeamId,
        championshipId,
        seasonYear,
        seasonYear - 1,
      ],
    );
    await transaction.query(`INSERT INTO public.match_sets (match_id, set_number) VALUES ($1, 1)`, [
      currentMatchId,
    ]);
    await transaction.query(
      `INSERT INTO public.championship_bracket_editions
        (id, championship_id, season_year)
       VALUES ($1, $2, $3)`,
      [editionId, championshipId, seasonYear],
    );
    await transaction.query(
      `INSERT INTO public.championship_bracket_competitions
        (id, bracket_edition_id, sport_id, naipe, groups_count, qualifiers_per_group)
       VALUES ($1, $2, $3, 'MASCULINO'::public.match_naipe, 1, 1)`,
      [competitionId, editionId, sportId],
    );
    await transaction.query(
      `INSERT INTO public.championship_bracket_matches
        (id, bracket_edition_id, competition_id, phase, match_id)
       VALUES ($1, $2, $3, 'KNOCKOUT'::public.bracket_phase, $4)`,
      [bracketMatchId, editionId, competitionId, currentMatchId],
    );
    await transaction.query(
      `INSERT INTO public.championship_knockout_result_corrections
        (id, championship_id, season_year, competition_id, source_bracket_match_id,
         source_match_id, walkover_mode)
       VALUES ($1, $2, $3, $4, $5, $6, 'HOME_LOST')`,
      [correctionId, championshipId, seasonYear, competitionId, bracketMatchId, currentMatchId],
    );
  });
}

async function cleanupFixtures() {
  await database.query(
    `DELETE FROM public.championship_knockout_result_corrections WHERE championship_id = $1`,
    [championshipId],
  );
  await database.query(`DELETE FROM public.matches WHERE championship_id = $1`, [championshipId]);
  await database.query(
    `DELETE FROM public.championship_bracket_matches WHERE bracket_edition_id = $1`,
    [editionId],
  );
  await database.query(
    `DELETE FROM public.championship_bracket_competitions WHERE bracket_edition_id = $1`,
    [editionId],
  );
  await database.query(`DELETE FROM public.championship_bracket_editions WHERE id = $1`, [
    editionId,
  ]);
  await database.query(
    `DELETE FROM public.admin_action_logs WHERE resource_table = 'championships' AND record_id = $1`,
    [championshipId],
  );
  await database.query(`DELETE FROM public.public_link_item_filters WHERE id = $1`, [
    publicLinkItemFilterId,
  ]);
  await database.query(`DELETE FROM public.public_link_items WHERE id = $1`, [publicLinkItemId]);
  await database.query(`DELETE FROM public.public_link_sections WHERE id = $1`, [
    publicLinkSectionId,
  ]);
  await database.query(`DELETE FROM public.championships WHERE id = $1`, [championshipId]);
  await database.query(`DELETE FROM public.teams WHERE id = ANY($1::uuid[])`, [
    [homeTeamId, awayTeamId],
  ]);
  await database.query(`DELETE FROM public.sports WHERE id = $1`, [sportId]);
}

test("season reset SQL matches PostgreSQL season tables and foreign-key order", async (t) => {
  t.after(async () => database.close());
  await database.query(`CREATE SCHEMA IF NOT EXISTS championship_bracket_preview_private`);
  await database.query(
    `CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.jobs (
      id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      championship_id uuid NOT NULL,
      season_year integer NOT NULL
    )`,
  );
  const operations = CURRENT_SEASON_DELETE_OPERATIONS.map((operation, index) => ({
    index,
    relation: `${operation.schema ?? "public"}.${operation.table}`,
  }));
  const operationPositions = new Map(operations.map(({ relation, index }) => [relation, index]));
  const intentionallyPreservedSeasonScopedRelations = new Set(["public.public_link_item_filters"]);

  const seasonTables = await database.query<{ schemaName: string; tableName: string }>(
    `SELECT table_schema AS "schemaName", table_name AS "tableName"
     FROM information_schema.columns
     WHERE table_schema IN ('public', 'championship_bracket_preview_private')
     GROUP BY table_schema, table_name
     HAVING bool_or(column_name = 'championship_id')
        AND bool_or(column_name = 'season_year')`,
  );
  for (const table of seasonTables.rows) {
    const relation = `${table.schemaName}.${table.tableName}`;
    if (intentionallyPreservedSeasonScopedRelations.has(relation)) {
      assert.equal(
        operationPositions.has(relation),
        false,
        `${relation} is preserved by the reset`,
      );
      continue;
    }
    assert.ok(operationPositions.has(relation), `${relation} has season keys but is omitted`);
  }

  const foreignKeys = await database.query<{
    childSchema: string;
    childTable: string;
    parentSchema: string;
    parentTable: string;
  }>(
    `SELECT child_namespace.nspname AS "childSchema",
            child_table.relname AS "childTable",
            parent_namespace.nspname AS "parentSchema",
            parent_table.relname AS "parentTable"
     FROM pg_constraint AS constraint_table
     JOIN pg_class AS child_table ON child_table.oid = constraint_table.conrelid
     JOIN pg_namespace AS child_namespace ON child_namespace.oid = child_table.relnamespace
     JOIN pg_class AS parent_table ON parent_table.oid = constraint_table.confrelid
     JOIN pg_namespace AS parent_namespace ON parent_namespace.oid = parent_table.relnamespace
     WHERE constraint_table.contype = 'f'
       AND constraint_table.confdeltype IN ('a', 'r')
       AND child_namespace.nspname IN ('public', 'championship_bracket_preview_private')
       AND parent_namespace.nspname IN ('public', 'championship_bracket_preview_private')`,
  );
  for (const foreignKey of foreignKeys.rows) {
    const child = `${foreignKey.childSchema}.${foreignKey.childTable}`;
    const parent = `${foreignKey.parentSchema}.${foreignKey.parentTable}`;
    const parentPosition = operationPositions.get(parent);
    if (parentPosition === undefined || child === parent) continue;
    const childPosition = operationPositions.get(child);
    assert.notEqual(childPosition, undefined, `${child} must be included before ${parent}`);
    assert.ok(childPosition! < parentPosition, `${child} must be deleted before ${parent}`);
  }

  let fixturesInserted = false;
  try {
    await insertFixtures();
    fixturesInserted = true;
    const result = await invokeResetRoute();
    assert.equal(result.statusCode, 204);

    const counts = await database.query<{
      currentMatches: number;
      previousMatches: number;
      corrections: number;
      editions: number;
      publicLinkFilters: number;
    }>(
      `SELECT
         (SELECT count(*)::int FROM public.matches WHERE id = $1) AS "currentMatches",
         (SELECT count(*)::int FROM public.matches WHERE id = $2) AS "previousMatches",
         (SELECT count(*)::int FROM public.championship_knockout_result_corrections WHERE id = $3) AS corrections,
         (SELECT count(*)::int FROM public.championship_bracket_editions WHERE id = $4) AS editions,
         (SELECT count(*)::int FROM public.public_link_item_filters WHERE id = $5) AS "publicLinkFilters"`,
      [currentMatchId, previousMatchId, correctionId, editionId, publicLinkItemFilterId],
    );
    assert.deepEqual(counts.rows[0], {
      currentMatches: 0,
      previousMatches: 1,
      corrections: 0,
      editions: 0,
      publicLinkFilters: 1,
    });

    const championship = await database.query<{ status: string }>(
      `SELECT status::text AS status FROM public.championships WHERE id = $1`,
      [championshipId],
    );
    assert.equal(championship.rows[0]?.status, "PLANNING");
  } finally {
    if (fixturesInserted) await cleanupFixtures();
  }
});
