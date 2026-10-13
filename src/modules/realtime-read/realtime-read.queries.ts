/** Pure, environment-independent whitelist for LAJE-89 snapshot SQL. */
/**
 * Strict whitelist of existing PostgreSQL read-only procedures migrated from
 * Supabase. Never accept arbitrary procedure names or SQL from an HTTP caller.
 * The two operational pending queues require an AWS admin access token.
 */
export const SNAPSHOTS = {
  "pending-award-draws": {
    name: "get_championship_award_pending_draws",
    signature: "uuid,integer",
    type: "json",
    admin: true,
  },
  "pending-tie-breaks": {
    name: "get_championship_bracket_pending_tie_breaks",
    signature: "uuid,uuid",
    type: "json",
    admin: true,
  },
  "interlaje-competition-standings": {
    name: "get_interlaje_regulation_competition_standings",
    signature: "uuid,integer,uuid,match_naipe,team_division",
    type: "rows",
    admin: false,
  },
  "interlaje-overall-standings": {
    name: "get_interlaje_overall_standings",
    signature: "uuid,integer",
    type: "rows",
    admin: false,
  },
  "awards-rankings": {
    name: "get_championship_score_sheet_awards_rankings",
    signature: "uuid,integer",
    type: "json",
    admin: false,
  },
  "corrected-group-standings": {
    name: "get_championship_corrected_group_standings",
    signature: "uuid,integer",
    type: "rows",
    admin: false,
  },
  "resolved-tie-break-orders": {
    name: "get_championship_bracket_resolved_tie_break_orders",
    signature: "uuid,integer",
    type: "json",
    admin: false,
  },
  "yellow-card-discipline": {
    name: "get_championship_yellow_card_discipline",
    signature: "uuid,integer",
    type: "json",
    admin: false,
  },
  "interlaje-position-points": {
    name: "get_interlaje_position_point_settings",
    signature: "uuid,integer",
    type: "rows",
    admin: false,
  },
  "competition-disqualifications": {
    name: "list_championship_competition_team_disqualifications",
    signature: "uuid,integer",
    type: "rows",
    admin: false,
  },
} as const;

export type RealtimeSnapshotName = keyof typeof SNAPSHOTS;

export function isRealtimeSnapshotName(value: string): value is RealtimeSnapshotName {
  return Object.prototype.hasOwnProperty.call(SNAPSHOTS, value);
}

export function buildRealtimeSnapshotQuery(
  name: RealtimeSnapshotName,
  scope: {
    championshipId: string;
    seasonYear?: number | null | undefined;
    bracketEditionId?: string | undefined;
    sportId?: string | undefined;
    naipe?: string | undefined;
    division?: string | null | undefined;
  },
): { sql: string; parameters: unknown[] } {
  const spec = SNAPSHOTS[name];
  const parameters: unknown[] = [scope.championshipId];
  if (name === "pending-tie-breaks") {
    parameters.push(scope.bracketEditionId ?? null);
  } else {
    parameters.push(scope.seasonYear);
  }
  if (name === "interlaje-competition-standings") {
    parameters.push(scope.sportId, scope.naipe, scope.division ?? null);
  }

  const casts = spec.signature.split(",");
  const placeholders = casts
    .map(
      (cast, index) =>
        `$${index + 1}::${cast === "match_naipe" || cast === "team_division" ? `public.${cast}` : cast}`,
    )
    .join(", ");
  const expression = `public.${spec.name}(${placeholders})`;
  return {
    sql:
      spec.type === "json"
        ? `SELECT ${expression} AS data`
        : `SELECT COALESCE(jsonb_agg(to_jsonb(item)), '[]'::jsonb) AS data FROM ${expression} AS item`,
    parameters,
  };
}

