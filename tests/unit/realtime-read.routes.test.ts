import assert from "node:assert/strict";
import test from "node:test";

import {
  buildRealtimeSnapshotQuery,
  isRealtimeSnapshotName,
} from "../../src/modules/realtime-read/realtime-read.routes.js";

const championshipId = "b37e22a1-8181-43b2-98a1-29db7e864f0a";
const sportId = "a67e69ea-6fb2-4245-a34a-02b36b4cda11";
const editionId = "aaaf5483-5602-4a89-b5dc-1eeb6b462519";

test("LAJE-89 exposes exactly the whitelisted read-only queries", () => {
  const allowed = [
    "pending-award-draws", "pending-tie-breaks",
    "interlaje-competition-standings", "interlaje-overall-standings",
    "awards-rankings", "corrected-group-standings",
    "resolved-tie-break-orders", "yellow-card-discipline",
    "interlaje-position-points", "competition-disqualifications",
  ];
  for (const name of allowed) assert.equal(isRealtimeSnapshotName(name), true);
  for (const invalid of ["", "__proto__", "update_password", "pg_catalog.pg_shadow", "admin-users"]) {
    assert.equal(isRealtimeSnapshotName(invalid), false);
  }
});

test("LAJE-89 JSON snapshots use parameterized uuid and integer", () => {
  const result = buildRealtimeSnapshotQuery("awards-rankings", {
    championshipId,
    seasonYear: 2026,
  });
  assert.equal(
    result.sql,
    "SELECT public.get_championship_score_sheet_awards_rankings($1::uuid, $2::integer) AS data",
  );
  assert.deepEqual(result.parameters, [championshipId, 2026]);
});

test("LAJE-89 pending tie breaks scope uses optional edition UUID", () => {
  const result = buildRealtimeSnapshotQuery("pending-tie-breaks", {
    championshipId,
    bracketEditionId: editionId,
  });
  assert.equal(
    result.sql,
    "SELECT public.get_championship_bracket_pending_tie_breaks($1::uuid, $2::uuid) AS data",
  );
  assert.deepEqual(result.parameters, [championshipId, editionId]);
});

test("LAJE-89 competition scope casts enum values and aggregates rows as JSONB numbers", () => {
  const result = buildRealtimeSnapshotQuery("interlaje-competition-standings", {
    championshipId,
    seasonYear: 2026,
    sportId,
    naipe: "MASCULINO",
    division: null,
  });
  assert.equal(result.sql,
    "SELECT COALESCE(jsonb_agg(to_jsonb(item)), '[]'::jsonb) AS data FROM public.get_interlaje_regulation_competition_standings($1::uuid, $2::integer, $3::uuid, $4::public.match_naipe, $5::public.team_division) AS item",
  );
  assert.deepEqual(result.parameters, [championshipId, 2026, sportId, "MASCULINO", null]);
});

test("LAJE-89 public rows use COALESCE to return [] when no records exist", () => {
  const result = buildRealtimeSnapshotQuery("interlaje-overall-standings", {
    championshipId,
    seasonYear: 2026,
  });
  assert.match(result.sql, /COALESCE\(jsonb_agg\(to_jsonb\(item\)\), '\[\]'::jsonb\)/);
  assert.deepEqual(result.parameters, [championshipId, 2026]);
});
