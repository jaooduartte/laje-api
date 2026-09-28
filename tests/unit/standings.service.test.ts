import assert from "node:assert/strict";
import test from "node:test";

import {
  rankStandings,
  resolveTieBreakCascade,
  type StandingRankingRow,
} from "../../src/modules/standings/standings.service.js";

function standing(
  teamId: string,
  teamName: string,
  overrides: Partial<StandingRankingRow> = {},
): StandingRankingRow {
  return {
    teamId,
    teamName,
    points: 0,
    wins: 0,
    goalDiff: 0,
    goalsFor: 0,
    goalsAgainst: 0,
    yellowCards: 0,
    redCards: 0,
    blueCards: 0,
    twoMinutePenalties: 0,
    setsFor: 0,
    setsAgainst: 0,
    rallyPointsFor: 0,
    rallyPointsAgainst: 0,
    ...overrides,
  };
}

test("classification policy overrides the legacy tie-break cascade", () => {
  assert.deepEqual(
    resolveTieBreakCascade("STANDARD", {
      criteria: ["POINTS", "SETS_AVERAGE", "RALLY_POINTS_FOR", "MANUAL_DRAW"],
    }),
    ["POINTS", "SETS_AVERAGE", "RALLY_POINTS_FOR", "MANUAL_DRAW"],
  );
});

test("head-to-head resolves a tie between exactly two teams", () => {
  const first = standing("team-a", "A", { points: 6, wins: 2 });
  const second = standing("team-b", "B", { points: 6, wins: 2 });

  const ranked = rankStandings([first, second], ["POINTS", "HEAD_TO_HEAD"], [
    {
      homeTeamId: "team-a",
      awayTeamId: "team-b",
      homeScore: 1,
      awayScore: 3,
    },
  ]);

  assert.deepEqual(
    ranked.map((row) => row.teamId),
    ["team-b", "team-a"],
  );
});

test("disciplinary criteria use ascending order", () => {
  const cleaner = standing("team-a", "A", { points: 6, yellowCards: 1 });
  const sanctioned = standing("team-b", "B", { points: 6, yellowCards: 4 });

  const ranked = rankStandings([sanctioned, cleaner], ["POINTS", "YELLOW_CARDS_ASC"]);

  assert.deepEqual(
    ranked.map((row) => row.teamId),
    ["team-a", "team-b"],
  );
});

test("manual draw is authoritative when previous criteria remain tied", () => {
  const first = standing("team-a", "A", { points: 6 });
  const second = standing("team-b", "B", { points: 6 });
  const drawOrder = new Map([
    ["team-a", 2],
    ["team-b", 1],
  ]);

  const ranked = rankStandings([first, second], ["POINTS", "MANUAL_DRAW"], [], drawOrder);

  assert.deepEqual(
    ranked.map((row) => row.teamId),
    ["team-b", "team-a"],
  );
});
