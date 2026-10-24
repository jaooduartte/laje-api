import assert from "node:assert/strict";
import test from "node:test";

import type { DatabaseQueryExecutor } from "../../src/database/types.js";
import { hydrateKnockoutAfterGroupFinish } from "../../src/modules/brackets/knockout-hydration.service.js";

const CHAMPIONSHIP = "a233522a-1343-418f-b687-bcf1e42a6655";
const EDITION = "f3d55f5c-32a9-44f4-afcf-dbe6e59da008";
const COMPETITION = "f3d55f5c-32a9-44f4-afcf-dbe6e59da009";
const MATCH = "f3d55f5c-32a9-44f4-afcf-dbe6e59da002";

test("LAJE-150 hydrates only the exact-v8 competition after a finished group match", async () => {
  const queries: Array<{ sql: string; params: readonly unknown[] }> = [];
  const executor = {
    async query(sql: string, params: readonly unknown[] = []) {
      queries.push({ sql, params });
      return {
        rows: sql.includes("WHERE bm.match_id")
          ? [{ competitionId: COMPETITION, editionId: EDITION, championshipId: CHAMPIONSHIP }]
          : [{ competition_id: COMPETITION }],
        count: 1,
      };
    },
  } as DatabaseQueryExecutor;
  assert.equal(await hydrateKnockoutAfterGroupFinish(executor, MATCH), 1);
  assert.match(queries[0]!.sql, /FOR UPDATE OF ed/);
  assert.match(queries[0]!.sql, /async-exact-v8/);
  assert.match(queries[1]!.sql, /hydrate_championship_bracket_preview_v8_knockout/);
  assert.deepEqual(queries[1]!.params, [CHAMPIONSHIP, COMPETITION, EDITION]);
});

test("LAJE-150 ignores matches without an exact-v8 group-stage bracket link", async () => {
  const queries: string[] = [];
  const executor = {
    async query(sql: string) {
      queries.push(sql);
      return { rows: [], count: 0 };
    },
  } as DatabaseQueryExecutor;
  assert.equal(await hydrateKnockoutAfterGroupFinish(executor, MATCH), 0);
  assert.equal(queries.length, 1);
});

test("LAJE-150 rolls back the enclosing match finish when knockout hydration fails", async () => {
  const executor = {
    async query(sql: string) {
      if (sql.includes("WHERE bm.match_id"))
        return {
          rows: [{ competitionId: COMPETITION, editionId: EDITION, championshipId: CHAMPIONSHIP }],
          count: 1,
        };
      throw new Error("Estrutura exata divergente");
    },
  } as DatabaseQueryExecutor;
  await assert.rejects(
    hydrateKnockoutAfterGroupFinish(executor, MATCH),
    /Estrutura exata divergente/,
  );
});
