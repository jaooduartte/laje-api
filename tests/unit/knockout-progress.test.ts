import assert from "node:assert/strict";
import test from "node:test";

import type { DatabaseQueryExecutor, DatabaseRow } from "../../src/database/types.js";
import { propagateExistingKnockoutResult } from "../../src/modules/brackets/knockout-progress.service.js";

const HOME = "e38bb21a-2493-4ef3-9f3d-dcd29117f411";
const AWAY = "7b623cd6-6508-4594-b864-b3183dbe99f0";
const QUALIFIED = "9f5c5bfc-c8b5-40a4-992b-7fbd4c67e8aa";
const TARGET = "d540e4ad-5c41-4b76-9600-ea1535a7c613";
const SOURCE = "303ad959-dcd0-4df7-8929-fc87127d1f80";
const NEXT_MATCH = "2b4b2811-98e6-4016-8cc1-cd21cd02095c";

function mockKnockoutExecutor(targetOverrides: Record<string, unknown> = {}) {
  const calls: { sql: string; params: readonly unknown[] }[] = [];
  const target = {
    id: TARGET,
    matchId: null,
    homeTeamId: null,
    awayTeamId: QUALIFIED,
    sourceHomeId: SOURCE,
    sourceAwayId: "997c1a6c-c9b4-486b-91db-8718eb494fc3",
    algorithmVersion: "async-exact-v8",
    competitionId: "d8b25779-3480-45b2-afcc-5a940ba9d007",
    plannedDate: "2026-11-22",
    plannedSlot: 2,
    plannedQueue: 8,
    plannedStart: "14:00:00",
    plannedEnd: "15:30:00",
    plannedLocationGroupId: "d3e4007c-6750-4294-a90c-2a3f7c8d3d4e",
    plannedCourtGroupId: "92bd7fc9-5063-4a78-a15f-f37a96704e5f",
    plannedLocation: "Ginásio",
    plannedCourt: "Quadra 1",
    ...targetOverrides,
  };
  const query = async (sql: string, params: readonly unknown[] = []) => {
    calls.push({ sql, params });
    if (sql.includes("WHERE match_id = $1 AND phase = 'KNOCKOUT'")) {
      return { rows: [{ id: SOURCE, winnerTeamId: null, nextBracketMatchId: TARGET }], count: 1 };
    }
    if (sql.includes("WHERE bm.id = $1 FOR UPDATE OF bm")) {
      return { rows: [target], count: 1 };
    }
    if (sql.includes("INSERT INTO public.matches")) {
      return { rows: [{ id: NEXT_MATCH }], count: 1 };
    }
    return { rows: [], count: 1 };
  };
  return {
    calls,
    executor: { query } as unknown as DatabaseQueryExecutor,
  };
}

const finished: DatabaseRow = {
  id: "79f6968d-f8a6-4205-b91d-63e7cb46b399",
  homeTeamId: HOME,
  awayTeamId: AWAY,
  homeScore: 3,
  awayScore: 1,
  isWalkover: false,
  isDoubleWalkover: false,
};

test("LAJE-150 materializes an exact-v8 next-round fixture with approved date and court", async () => {
  const { executor, calls } = mockKnockoutExecutor();
  await propagateExistingKnockoutResult(executor, finished);
  const insert = calls.find((call) => call.sql.includes("INSERT INTO public.matches"));
  assert.ok(insert, "A partida seguinte precisa ser criada quando ambos finalistas são conhecidos");
  assert.equal(insert.params[1], HOME);
  assert.equal(insert.params[2], QUALIFIED);
  assert.equal(insert.params[3], "Ginásio");
  assert.equal(insert.params[4], "Quadra 1");
  assert.equal(insert.params[5], "2026-11-22");
  assert.equal(insert.params[6], 2);
  assert.equal(insert.params[7], 8);
  assert.equal(insert.params[8], "14:00:00");
  assert.equal(insert.params[9], "15:30:00");
  assert.ok(
    calls.some((call) => call.sql.includes("SET match_id = $2") && call.params[1] === NEXT_MATCH),
  );
});

test("LAJE-150 does not materialize a future fixture while a qualifier is unknown", async () => {
  const { executor, calls } = mockKnockoutExecutor({ awayTeamId: null });
  await propagateExistingKnockoutResult(executor, finished);
  assert.equal(
    calls.some((call) => call.sql.includes("INSERT INTO public.matches")),
    false,
  );
});

test("LAJE-150 rejects a fully qualified exact-v8 fixture missing a planned court", async () => {
  const { executor } = mockKnockoutExecutor({ plannedCourt: null });
  await assert.rejects(
    propagateExistingKnockoutResult(executor, finished),
    (error: unknown) =>
      error instanceof Error && error.message.includes("programação estrutural completa"),
  );
});
