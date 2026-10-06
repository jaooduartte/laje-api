import type { DatabaseQueryExecutor } from "../../database/types.js";

export interface StandingsScope {
  championshipId: string;
  seasonYear: number;
  sportId: string;
  naipe: string;
  division: string | null;
}

export async function recalculateCollectiveStandings(
  executor: DatabaseQueryExecutor,
  scope: StandingsScope,
): Promise<void> {
  const scopeParameters = [
    scope.championshipId,
    scope.seasonYear,
    scope.sportId,
    scope.naipe,
    scope.division,
  ];
  const participants = await executor.query(
    `SELECT DISTINCT team_id AS "teamId" FROM (
       SELECT st.team_id
       FROM public.standings st
       WHERE st.championship_id = $1 AND st.season_year = $2 AND st.sport_id = $3
         AND st.naipe = $4::public.match_naipe AND st.division IS NOT DISTINCT FROM $5::public.team_division
       UNION ALL
       SELECT m.home_team_id
       FROM public.matches m
       WHERE m.championship_id = $1 AND m.season_year = $2 AND m.sport_id = $3
         AND m.naipe = $4::public.match_naipe AND m.division IS NOT DISTINCT FROM $5::public.team_division
       UNION ALL
       SELECT m.away_team_id
       FROM public.matches m
       WHERE m.championship_id = $1 AND m.season_year = $2 AND m.sport_id = $3
         AND m.naipe = $4::public.match_naipe AND m.division IS NOT DISTINCT FROM $5::public.team_division
     ) participants(team_id)`,
    scopeParameters,
  );
  const teamIds = participants.rows.map((row) => String(row.teamId));
  if (teamIds.length === 0) return;

  await executor.query(
    `DELETE FROM public.standings
     WHERE championship_id = $1 AND season_year = $2 AND sport_id = $3
       AND naipe = $4::public.match_naipe AND division IS NOT DISTINCT FROM $5::public.team_division`,
    scopeParameters,
  );

  await executor.query(
    `WITH participants AS (
       SELECT unnest($6::uuid[]) AS team_id
     ), finished AS (
       SELECT m.*
       FROM public.matches m
       WHERE m.championship_id = $1 AND m.season_year = $2 AND m.sport_id = $3
         AND m.naipe = $4::public.match_naipe AND m.division IS NOT DISTINCT FROM $5::public.team_division
         AND m.status = 'FINISHED'
     ), config AS (
       SELECT points_win, points_draw, points_loss FROM public.championship_sports
       WHERE championship_id = $1 AND sport_id = $3 LIMIT 1
     ), calculated AS (
       SELECT p.team_id,
         COUNT(m.id)::int AS played,
         COUNT(*) FILTER (WHERE m.id IS NOT NULL AND (
           (m.is_walkover AND NOT m.is_double_walkover AND m.walkover_loser_team_id IS DISTINCT FROM p.team_id)
           OR (NOT m.is_walkover AND ((m.home_team_id = p.team_id AND m.home_score > m.away_score) OR (m.away_team_id = p.team_id AND m.away_score > m.home_score)))
         ))::int AS wins,
         COUNT(*) FILTER (WHERE m.id IS NOT NULL AND NOT m.is_walkover AND m.home_score = m.away_score)::int AS draws,
         COUNT(*) FILTER (WHERE m.id IS NOT NULL AND (
           m.is_double_walkover
           OR (m.is_walkover AND m.walkover_loser_team_id = p.team_id)
           OR (NOT m.is_walkover AND ((m.home_team_id = p.team_id AND m.home_score < m.away_score) OR (m.away_team_id = p.team_id AND m.away_score < m.home_score)))
         ))::int AS losses,
         COALESCE(SUM(CASE WHEN m.home_team_id = p.team_id THEN m.home_score WHEN m.away_team_id = p.team_id THEN m.away_score ELSE 0 END), 0)::int AS goals_for,
         COALESCE(SUM(CASE WHEN m.home_team_id = p.team_id THEN m.away_score WHEN m.away_team_id = p.team_id THEN m.home_score ELSE 0 END), 0)::int AS goals_against,
         COALESCE(SUM(CASE WHEN m.home_team_id = p.team_id THEN m.home_yellow_cards WHEN m.away_team_id = p.team_id THEN m.away_yellow_cards ELSE 0 END), 0)::int AS yellow_cards,
         COALESCE(SUM(CASE WHEN m.home_team_id = p.team_id THEN m.home_red_cards WHEN m.away_team_id = p.team_id THEN m.away_red_cards ELSE 0 END), 0)::int AS red_cards,
         COALESCE(SUM(CASE WHEN m.home_team_id = p.team_id THEN m.home_blue_cards WHEN m.away_team_id = p.team_id THEN m.away_blue_cards ELSE 0 END), 0)::int AS blue_cards,
         COALESCE(SUM(CASE WHEN m.home_team_id = p.team_id THEN m.home_two_minute_penalties WHEN m.away_team_id = p.team_id THEN m.away_two_minute_penalties ELSE 0 END), 0)::int AS two_minute_penalties,
         COALESCE(SUM(CASE
           WHEN m.id IS NULL THEN 0
           WHEN m.is_double_walkover THEN COALESCE(c.points_loss, 0)
           WHEN m.is_walkover AND m.walkover_loser_team_id = p.team_id THEN COALESCE(c.points_loss, 0)
           WHEN m.is_walkover THEN COALESCE(c.points_win, 3)
           WHEN m.home_score = m.away_score THEN COALESCE(c.points_draw, 1)
           WHEN (m.home_team_id = p.team_id AND m.home_score > m.away_score) OR (m.away_team_id = p.team_id AND m.away_score > m.home_score) THEN COALESCE(c.points_win, 3)
           ELSE COALESCE(c.points_loss, 0)
         END), 0)::int AS points
       FROM participants p
       LEFT JOIN finished m ON m.home_team_id = p.team_id OR m.away_team_id = p.team_id
       CROSS JOIN (SELECT COALESCE((SELECT points_win FROM config), 3) AS points_win,
                          COALESCE((SELECT points_draw FROM config), 1) AS points_draw,
                          COALESCE((SELECT points_loss FROM config), 0) AS points_loss) c
       GROUP BY p.team_id
     )
     INSERT INTO public.standings
       (championship_id, season_year, sport_id, team_id, naipe, division, played, wins, draws, losses,
        goals_for, goals_against, goal_diff, points, yellow_cards, red_cards, blue_cards, two_minute_penalties,
        updated_at)
     SELECT $1, $2, $3, team_id, $4::public.match_naipe, $5::public.team_division,
       played, wins, draws, losses, goals_for, goals_against, goals_for - goals_against, points,
       yellow_cards, red_cards, blue_cards, two_minute_penalties, now()
     FROM calculated`,
    [...scopeParameters, teamIds],
  );
}
