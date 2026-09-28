export type TieBreakCriterion =
  | "POINTS"
  | "WINS"
  | "HEAD_TO_HEAD"
  | "POINTS_AVERAGE"
  | "SETS_AVERAGE"
  | "SETS_FOR"
  | "SETS_AGAINST_ASC"
  | "RALLY_POINTS_FOR"
  | "RALLY_POINTS_AGAINST_ASC"
  | "GOAL_DIFF"
  | "GOALS_FOR"
  | "GOALS_AGAINST_ASC"
  | "YELLOW_CARDS_ASC"
  | "RED_CARDS_ASC"
  | "BLUE_CARDS_ASC"
  | "TWO_MINUTE_PENALTIES_ASC"
  | "MANUAL_DRAW";

export interface StandingRankingRow {
  teamId: string;
  teamName: string;
  points: number;
  wins: number;
  goalDiff: number;
  goalsFor: number;
  goalsAgainst: number;
  yellowCards: number;
  redCards: number;
  blueCards: number;
  twoMinutePenalties: number;
  setsFor: number;
  setsAgainst: number;
  rallyPointsFor: number;
  rallyPointsAgainst: number;
}

export interface FinishedMatchForTieBreak {
  homeTeamId: string;
  awayTeamId: string;
  homeScore: number;
  awayScore: number;
}

const POLICY_CRITERIA: Partial<Record<string, TieBreakCriterion>> = {
  POINTS: "POINTS",
  WINS: "WINS",
  POINTS_AVERAGE: "POINTS_AVERAGE",
  HEAD_TO_HEAD_EXACTLY_TWO: "HEAD_TO_HEAD",
  HEAD_TO_HEAD: "HEAD_TO_HEAD",
  POINT_DIFF: "GOAL_DIFF",
  GOAL_DIFF: "GOAL_DIFF",
  POINTS_FOR: "GOALS_FOR",
  GOALS_FOR: "GOALS_FOR",
  POINTS_AGAINST_ASC: "GOALS_AGAINST_ASC",
  GOALS_AGAINST_ASC: "GOALS_AGAINST_ASC",
  SETS_AVERAGE: "SETS_AVERAGE",
  SETS_FOR: "SETS_FOR",
  SETS_AGAINST_ASC: "SETS_AGAINST_ASC",
  RALLY_POINTS_FOR: "RALLY_POINTS_FOR",
  RALLY_POINTS_AGAINST_ASC: "RALLY_POINTS_AGAINST_ASC",
  YELLOW_CARDS_ASC: "YELLOW_CARDS_ASC",
  RED_CARDS_ASC: "RED_CARDS_ASC",
  BLUE_CARDS_ASC: "BLUE_CARDS_ASC",
  TWO_MINUTE_PENALTIES_ASC: "TWO_MINUTE_PENALTIES_ASC",
  MANUAL_DRAW: "MANUAL_DRAW",
};

const LEGACY_CASCADES: Record<string, TieBreakCriterion[]> = {
  BEACH_SOCCER: [
    "POINTS",
    "HEAD_TO_HEAD",
    "WINS",
    "GOAL_DIFF",
    "GOALS_FOR",
    "GOALS_AGAINST_ASC",
    "YELLOW_CARDS_ASC",
    "RED_CARDS_ASC",
    "MANUAL_DRAW",
  ],
  BEACH_TENNIS: ["POINTS", "WINS", "HEAD_TO_HEAD", "GOAL_DIFF", "GOALS_FOR", "MANUAL_DRAW"],
  FUTEBOL_SOCIETY: [
    "POINTS",
    "HEAD_TO_HEAD",
    "GOAL_DIFF",
    "GOALS_FOR",
    "YELLOW_CARDS_ASC",
    "RED_CARDS_ASC",
    "MANUAL_DRAW",
  ],
  HANDEBOL: [
    "POINTS",
    "HEAD_TO_HEAD",
    "GOAL_DIFF",
    "GOALS_AGAINST_ASC",
    "BLUE_CARDS_ASC",
    "RED_CARDS_ASC",
    "YELLOW_CARDS_ASC",
    "TWO_MINUTE_PENALTIES_ASC",
    "MANUAL_DRAW",
  ],
  POINTS_AVERAGE: [
    "POINTS",
    "HEAD_TO_HEAD",
    "POINTS_AVERAGE",
    "GOAL_DIFF",
    "GOALS_FOR",
    "WINS",
    "MANUAL_DRAW",
  ],
  STANDARD: ["POINTS", "HEAD_TO_HEAD", "GOAL_DIFF", "GOALS_FOR", "WINS", "MANUAL_DRAW"],
};

function policyCriteria(policy: unknown): TieBreakCriterion[] {
  if (!policy || typeof policy != "object" || Array.isArray(policy)) return [];
  const criteria = (policy as Record<string, unknown>).criteria;
  if (!Array.isArray(criteria)) return [];
  return criteria.flatMap((value) => {
    if (typeof value != "string") return [];
    const mapped = POLICY_CRITERIA[value];
    return mapped ? [mapped] : [];
  });
}

export function resolveTieBreakCascade(
  legacyRule: string | null,
  classificationPolicy: unknown,
): TieBreakCriterion[] {
  const configured = policyCriteria(classificationPolicy);
  if (configured.length > 0) return configured;
  return LEGACY_CASCADES[legacyRule ?? "STANDARD"] ?? LEGACY_CASCADES.STANDARD!;
}

function ratio(forValue: number, againstValue: number): number {
  if (againstValue === 0) return forValue === 0 ? 0 : Number.POSITIVE_INFINITY;
  return forValue / againstValue;
}

function numericValue(criterion: TieBreakCriterion, row: StandingRankingRow): number {
  switch (criterion) {
    case "POINTS": return row.points;
    case "WINS": return row.wins;
    case "POINTS_AVERAGE": return ratio(row.goalsFor, row.goalsAgainst);
    case "SETS_AVERAGE": return ratio(row.setsFor, row.setsAgainst);
    case "SETS_FOR": return row.setsFor;
    case "SETS_AGAINST_ASC": return row.setsAgainst;
    case "RALLY_POINTS_FOR": return row.rallyPointsFor;
    case "RALLY_POINTS_AGAINST_ASC": return row.rallyPointsAgainst;
    case "GOAL_DIFF": return row.goalDiff;
    case "GOALS_FOR": return row.goalsFor;
    case "GOALS_AGAINST_ASC": return row.goalsAgainst;
    case "YELLOW_CARDS_ASC": return row.yellowCards;
    case "RED_CARDS_ASC": return row.redCards;
    case "BLUE_CARDS_ASC": return row.blueCards;
    case "TWO_MINUTE_PENALTIES_ASC": return row.twoMinutePenalties;
    default: return 0;
  }
}

function isAscending(criterion: TieBreakCriterion): boolean {
  return criterion.endsWith("_ASC");
}

function partitionByValue<T>(rows: T[], valueOf: (row: T) => number): T[][] {
  if (rows.length === 0) return [];
  const partitions: T[][] = [[rows[0]!]];
  for (let index = 1; index < rows.length; index += 1) {
    const previous = valueOf(rows[index - 1]!);
    const current = valueOf(rows[index]!);
    const same =
      (!Number.isFinite(previous) && !Number.isFinite(current)) || Math.abs(previous - current) < 1e-9;
    if (same) partitions[partitions.length - 1]!.push(rows[index]!);
    else partitions.push([rows[index]!]);
  }
  return partitions;
}

function headToHeadCompare(
  firstTeamId: string,
  secondTeamId: string,
  matches: readonly FinishedMatchForTieBreak[],
): number {
  let firstPoints = 0;
  let secondPoints = 0;
  let firstScore = 0;
  let secondScore = 0;
  let found = false;
  for (const match of matches) {
    const normal = match.homeTeamId === firstTeamId && match.awayTeamId === secondTeamId;
    const reverse = match.homeTeamId === secondTeamId && match.awayTeamId === firstTeamId;
    if (!normal && !reverse) continue;
    found = true;
    const firstGoals = normal ? match.homeScore : match.awayScore;
    const secondGoals = normal ? match.awayScore : match.homeScore;
    firstScore += firstGoals;
    secondScore += secondGoals;
    if (firstGoals > secondGoals) firstPoints += 3;
    else if (secondGoals > firstGoals) secondPoints += 3;
    else { firstPoints += 1; secondPoints += 1; }
  }
  if (!found) return 0;
  if (firstPoints !== secondPoints) return secondPoints - firstPoints;
  return secondScore - firstScore;
}

export function rankStandings<Row extends StandingRankingRow>(
  rows: readonly Row[],
  cascade: readonly TieBreakCriterion[],
  matches: readonly FinishedMatchForTieBreak[] = [],
  manualDrawOrder: ReadonlyMap<string, number> = new Map(),
): Row[] {
  let buckets: Row[][] = [[...rows]];
  for (const criterion of cascade) {
    const next: Row[][] = [];
    for (const bucket of buckets) {
      if (bucket.length <= 1) { next.push(bucket); continue; }
      if (criterion === "HEAD_TO_HEAD") {
        if (bucket.length !== 2) { next.push(bucket); continue; }
        const [first, second] = bucket as [Row, Row];
        const comparison = headToHeadCompare(first.teamId, second.teamId, matches);
        next.push(comparison < 0 ? [first, second] : comparison > 0 ? [second, first] : bucket);
        continue;
      }
      if (criterion === "MANUAL_DRAW") {
        const sorted = [...bucket].sort((a, b) => {
          const aOrder = manualDrawOrder.get(a.teamId);
          const bOrder = manualDrawOrder.get(b.teamId);
          if (aOrder == null && bOrder == null) return a.teamName.localeCompare(b.teamName, "pt-BR");
          if (aOrder == null) return 1;
          if (bOrder == null) return -1;
          return aOrder - bOrder;
        });
        next.push(...sorted.map((row) => [row]));
        continue;
      }
      const ascending = isAscending(criterion);
      const sorted = [...bucket].sort((a, b) => {
        const first = numericValue(criterion, a);
        const second = numericValue(criterion, b);
        if (!Number.isFinite(first) && !Number.isFinite(second)) return 0;
        if (!Number.isFinite(first)) return ascending ? 1 : -1;
        if (!Number.isFinite(second)) return ascending ? -1 : 1;
        return ascending ? first - second : second - first;
      });
      next.push(...partitionByValue(sorted, (row) => numericValue(criterion, row)));
    }
    buckets = next;
  }
  return buckets.flat();
}
