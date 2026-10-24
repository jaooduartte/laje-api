-- LAJE-150: original stage standings and qualification display functions for AWS-only frontend.

-- get_championship_group_stage_qualification_display_metrics(_championship_id uuid, _season_year integer)
CREATE OR REPLACE FUNCTION public.get_championship_group_stage_qualification_display_metrics(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS TABLE(competition_id uuid, sport_id uuid, sport_name text, naipe match_naipe, division team_division, group_id uuid, group_number integer, team_id uuid, team_name text, played bigint, wins bigint, draws bigint, losses bigint, goals_for bigint, goals_against bigint, goal_diff bigint, points bigint, comparison_points numeric, yellow_cards bigint, red_cards bigint, blue_cards bigint, two_minute_penalties bigint, sets_for bigint, sets_against bigint, rally_points_for bigint, rally_points_against bigint, group_rank integer, comparison_rank integer, comparison_goals_for numeric, comparison_goals_against numeric, comparison_goal_diff numeric, comparison_yellow_cards numeric, comparison_red_cards numeric, comparison_blue_cards numeric, comparison_two_minute_penalties numeric, comparison_sets_for numeric, comparison_sets_against numeric, comparison_rally_points_for numeric, comparison_rally_points_against numeric, qualification_rank integer, qualification_pool_rank integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH display_metrics AS (
    SELECT *
    FROM public.get_championship_group_stage_standings_display_metrics(
      _championship_id,
      _season_year
    )
  ), competition_context AS (
    SELECT DISTINCT
      display_metrics.competition_id,
      championships_table.code = 'INTERLAJE'::public.championship_code
        AND public.normalize_sport_name(sports_table.name) = 'voleibol'
        AS is_interlaje_volleyball
    FROM display_metrics
    JOIN public.championship_bracket_competitions AS competitions_table
      ON competitions_table.id = display_metrics.competition_id
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    JOIN public.championships AS championships_table
      ON championships_table.id = editions_table.championship_id
    JOIN public.sports AS sports_table
      ON sports_table.id = competitions_table.sport_id
  ), group_sizes AS (
    SELECT
      display_metrics.competition_id,
      display_metrics.group_id,
      count(*)::numeric AS group_size
    FROM display_metrics
    GROUP BY display_metrics.competition_id, display_metrics.group_id
  ), maximum_group_matches AS (
    SELECT
      group_sizes.competition_id,
      GREATEST(MAX(group_sizes.group_size - 1), 1)::numeric AS value
    FROM group_sizes
    GROUP BY group_sizes.competition_id
  ), qualification_pool AS (
    SELECT
      competition_context.competition_id,
      qualification_ranking.team_id,
      qualification_ranking.qualification_rank,
      qualification_ranking.pool_rank
    FROM competition_context
    CROSS JOIN LATERAL public.get_championship_bracket_competition_qualification_pool_ranking(
      _championship_id,
      competition_context.competition_id
    ) AS qualification_ranking
    WHERE competition_context.is_interlaje_volleyball
  ), normalized_metrics AS (
    SELECT
      display_metrics.*,
      competition_context.is_interlaje_volleyball,
      qualification_pool.pool_rank AS qualification_pool_rank,
      qualification_pool.qualification_rank,
      maximum_group_matches.value
        / GREATEST(group_sizes.group_size - 1, 1) AS comparison_factor
    FROM display_metrics
    JOIN competition_context
      ON competition_context.competition_id = display_metrics.competition_id
    JOIN group_sizes
      ON group_sizes.competition_id = display_metrics.competition_id
      AND group_sizes.group_id = display_metrics.group_id
    JOIN maximum_group_matches
      ON maximum_group_matches.competition_id = display_metrics.competition_id
    LEFT JOIN qualification_pool
      ON qualification_pool.competition_id = display_metrics.competition_id
      AND qualification_pool.team_id = display_metrics.team_id
  )
  SELECT
    normalized_metrics.competition_id,
    normalized_metrics.sport_id,
    normalized_metrics.sport_name,
    normalized_metrics.naipe,
    normalized_metrics.division,
    normalized_metrics.group_id,
    normalized_metrics.group_number,
    normalized_metrics.team_id,
    normalized_metrics.team_name,
    normalized_metrics.played,
    normalized_metrics.wins,
    normalized_metrics.draws,
    normalized_metrics.losses,
    normalized_metrics.goals_for,
    normalized_metrics.goals_against,
    normalized_metrics.goal_diff,
    normalized_metrics.points,
    normalized_metrics.comparison_points,
    normalized_metrics.yellow_cards,
    normalized_metrics.red_cards,
    normalized_metrics.blue_cards,
    normalized_metrics.two_minute_penalties,
    normalized_metrics.sets_for,
    normalized_metrics.sets_against,
    normalized_metrics.rally_points_for,
    normalized_metrics.rally_points_against,
    normalized_metrics.group_rank,
    normalized_metrics.comparison_rank,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.goals_for::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.goals_for::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.goals_against::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.goals_against::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.goal_diff::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.goal_diff::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.yellow_cards::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.yellow_cards::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.red_cards::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.red_cards::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.blue_cards::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.blue_cards::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.two_minute_penalties::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.two_minute_penalties::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.sets_for::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.sets_for::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.sets_against::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.sets_against::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.rally_points_for::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.rally_points_for::numeric
    END,
    CASE
      WHEN normalized_metrics.is_interlaje_volleyball
        AND normalized_metrics.qualification_pool_rank IS NOT NULL
        THEN normalized_metrics.rally_points_against::numeric * normalized_metrics.comparison_factor
      ELSE normalized_metrics.rally_points_against::numeric
    END,
    normalized_metrics.qualification_rank,
    normalized_metrics.qualification_pool_rank
  FROM normalized_metrics;
$function$;

-- get_championship_group_stage_standings(_championship_id uuid, _season_year integer)
CREATE OR REPLACE FUNCTION public.get_championship_group_stage_standings(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS TABLE(competition_id uuid, sport_id uuid, sport_name text, naipe match_naipe, division team_division, group_id uuid, group_number integer, team_id uuid, team_name text, played bigint, wins bigint, draws bigint, losses bigint, goals_for bigint, goals_against bigint, goal_diff bigint, points bigint, comparison_points numeric, yellow_cards bigint, red_cards bigint, blue_cards bigint, two_minute_penalties bigint, group_rank integer, comparison_rank integer)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH edition_context AS (
    SELECT editions_table.id, editions_table.season_year
    FROM public.championship_bracket_editions AS editions_table
    WHERE editions_table.championship_id = _championship_id
      AND (_season_year IS NULL OR editions_table.season_year = _season_year)
    ORDER BY editions_table.created_at DESC
    LIMIT 1
  ), competition_context AS (
    SELECT
      competitions_table.id AS competition_id,
      competitions_table.sport_id,
      sports_table.name AS sport_name,
      public.normalize_sport_name(sports_table.name) AS normalized_sport_name,
      competitions_table.naipe,
      competitions_table.division,
      editions_table.season_year,
      championships_table.code AS championship_code,
      COALESCE(championship_sports_table.result_rule, 'POINTS'::public.championship_sport_result_rule) AS result_rule,
      COALESCE(championship_sports_table.points_win, 3) AS points_win,
      COALESCE(championship_sports_table.points_draw, 1) AS points_draw,
      COALESCE(championship_sports_table.points_loss, 0) AS points_loss,
      COALESCE(championship_sports_table.tie_breaker_rule, 'STANDARD'::public.championship_sport_tie_breaker_rule) AS tie_breaker_rule
    FROM public.championship_bracket_competitions AS competitions_table
    JOIN edition_context AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    JOIN public.championships AS championships_table
      ON championships_table.id = _championship_id
    JOIN public.sports AS sports_table
      ON sports_table.id = competitions_table.sport_id
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = _championship_id
      AND championship_sports_table.sport_id = competitions_table.sport_id
  ), group_matches AS (
    SELECT
      competition_context.competition_id,
      bracket_matches_table.group_id,
      matches_table.home_team_id,
      matches_table.away_team_id,
      GREATEST(0, COALESCE(matches_table.home_score, 0))::bigint AS home_score,
      GREATEST(0, COALESCE(matches_table.away_score, 0))::bigint AS away_score,
      CASE
        WHEN competition_context.result_rule = 'SETS'::public.championship_sport_result_rule
          AND COALESCE(match_set_totals.sets_count, 0) > 0
        THEN match_set_totals.home_points_total
        ELSE GREATEST(0, COALESCE(matches_table.home_score, 0))::bigint
      END AS home_goals,
      CASE
        WHEN competition_context.result_rule = 'SETS'::public.championship_sport_result_rule
          AND COALESCE(match_set_totals.sets_count, 0) > 0
        THEN match_set_totals.away_points_total
        ELSE GREATEST(0, COALESCE(matches_table.away_score, 0))::bigint
      END AS away_goals,
      GREATEST(0, COALESCE(matches_table.home_yellow_cards, 0))::bigint AS home_yellow_cards,
      GREATEST(0, COALESCE(matches_table.home_red_cards, 0))::bigint AS home_red_cards,
      GREATEST(0, COALESCE(matches_table.home_blue_cards, 0))::bigint AS home_blue_cards,
      GREATEST(0, COALESCE(matches_table.home_two_minute_penalties, 0))::bigint AS home_two_minute_penalties,
      GREATEST(0, COALESCE(matches_table.away_yellow_cards, 0))::bigint AS away_yellow_cards,
      GREATEST(0, COALESCE(matches_table.away_red_cards, 0))::bigint AS away_red_cards,
      GREATEST(0, COALESCE(matches_table.away_blue_cards, 0))::bigint AS away_blue_cards,
      GREATEST(0, COALESCE(matches_table.away_two_minute_penalties, 0))::bigint AS away_two_minute_penalties,
      competition_context.championship_code,
      competition_context.normalized_sport_name,
      competition_context.points_win,
      competition_context.points_draw,
      competition_context.points_loss,
      CASE
        WHEN matches_table.home_score > matches_table.away_score THEN matches_table.home_team_id
        WHEN matches_table.away_score > matches_table.home_score THEN matches_table.away_team_id
        WHEN competition_context.championship_code = 'SOCIETY'::public.championship_code
          AND matches_table.home_penalty_score IS NOT NULL
          AND matches_table.away_penalty_score IS NOT NULL
          AND matches_table.home_penalty_score <> matches_table.away_penalty_score
        THEN matches_table.resolved_tie_break_winner_team_id
        ELSE NULL
      END AS winner_team_id
    FROM competition_context
    JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.competition_id = competition_context.competition_id
      AND bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
    JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
      AND matches_table.status = 'FINISHED'::public.match_status
      AND COALESCE(matches_table.is_double_walkover, false) = false
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(SUM(match_sets_table.home_points), 0)::bigint AS home_points_total,
        COALESCE(SUM(match_sets_table.away_points), 0)::bigint AS away_points_total,
        COUNT(*)::bigint AS sets_count
      FROM public.match_sets AS match_sets_table
      WHERE match_sets_table.match_id = matches_table.id
    ) AS match_set_totals ON TRUE
  ), score_rows AS (
    SELECT
      group_matches.competition_id,
      group_matches.group_id,
      group_matches.home_team_id AS team_id,
      1::bigint AS played,
      CASE WHEN group_matches.winner_team_id = group_matches.home_team_id THEN 1 ELSE 0 END::bigint AS wins,
      CASE WHEN group_matches.winner_team_id IS NULL AND group_matches.home_score = group_matches.away_score THEN 1 ELSE 0 END::bigint AS draws,
      CASE WHEN group_matches.winner_team_id = group_matches.away_team_id THEN 1 ELSE 0 END::bigint AS losses,
      group_matches.home_goals AS goals_for,
      group_matches.away_goals AS goals_against,
      CASE
        WHEN group_matches.championship_code = 'INTERLAJE'::public.championship_code
          AND group_matches.normalized_sport_name = 'voleibol'
          AND group_matches.home_score = 2 AND group_matches.away_score = 0 THEN 3
        WHEN group_matches.championship_code = 'INTERLAJE'::public.championship_code
          AND group_matches.normalized_sport_name = 'voleibol'
          AND group_matches.home_score = 2 AND group_matches.away_score = 1 THEN 2
        WHEN group_matches.championship_code = 'INTERLAJE'::public.championship_code
          AND group_matches.normalized_sport_name = 'voleibol'
          AND group_matches.home_score = 1 AND group_matches.away_score = 2 THEN 1
        WHEN group_matches.championship_code = 'INTERLAJE'::public.championship_code
          AND group_matches.normalized_sport_name = 'voleibol' THEN 0
        WHEN group_matches.winner_team_id = group_matches.home_team_id THEN group_matches.points_win
        WHEN group_matches.winner_team_id = group_matches.away_team_id THEN group_matches.points_loss
        ELSE group_matches.points_draw
      END::bigint AS points,
      group_matches.home_yellow_cards AS yellow_cards,
      group_matches.home_red_cards AS red_cards,
      group_matches.home_blue_cards AS blue_cards,
      group_matches.home_two_minute_penalties AS two_minute_penalties
    FROM group_matches
    UNION ALL
    SELECT
      group_matches.competition_id,
      group_matches.group_id,
      group_matches.away_team_id,
      1::bigint,
      CASE WHEN group_matches.winner_team_id = group_matches.away_team_id THEN 1 ELSE 0 END::bigint,
      CASE WHEN group_matches.winner_team_id IS NULL AND group_matches.home_score = group_matches.away_score THEN 1 ELSE 0 END::bigint,
      CASE WHEN group_matches.winner_team_id = group_matches.home_team_id THEN 1 ELSE 0 END::bigint,
      group_matches.away_goals,
      group_matches.home_goals,
      CASE
        WHEN group_matches.championship_code = 'INTERLAJE'::public.championship_code
          AND group_matches.normalized_sport_name = 'voleibol'
          AND group_matches.home_score = 0 AND group_matches.away_score = 2 THEN 3
        WHEN group_matches.championship_code = 'INTERLAJE'::public.championship_code
          AND group_matches.normalized_sport_name = 'voleibol'
          AND group_matches.home_score = 1 AND group_matches.away_score = 2 THEN 2
        WHEN group_matches.championship_code = 'INTERLAJE'::public.championship_code
          AND group_matches.normalized_sport_name = 'voleibol'
          AND group_matches.home_score = 2 AND group_matches.away_score = 1 THEN 1
        WHEN group_matches.championship_code = 'INTERLAJE'::public.championship_code
          AND group_matches.normalized_sport_name = 'voleibol' THEN 0
        WHEN group_matches.winner_team_id = group_matches.away_team_id THEN group_matches.points_win
        WHEN group_matches.winner_team_id = group_matches.home_team_id THEN group_matches.points_loss
        ELSE group_matches.points_draw
      END::bigint,
      group_matches.away_yellow_cards,
      group_matches.away_red_cards,
      group_matches.away_blue_cards,
      group_matches.away_two_minute_penalties
    FROM group_matches
  ), group_rows AS (
    SELECT
      competition_context.competition_id,
      competition_context.sport_id,
      competition_context.sport_name,
      competition_context.naipe,
      competition_context.division,
      competition_context.tie_breaker_rule,
      groups_table.id AS group_id,
      groups_table.group_number,
      group_teams_table.team_id,
      teams_table.name AS team_name,
      COALESCE(SUM(score_rows.played), 0)::bigint AS played,
      COALESCE(SUM(score_rows.wins), 0)::bigint AS wins,
      COALESCE(SUM(score_rows.draws), 0)::bigint AS draws,
      COALESCE(SUM(score_rows.losses), 0)::bigint AS losses,
      COALESCE(SUM(score_rows.goals_for), 0)::bigint AS goals_for,
      COALESCE(SUM(score_rows.goals_against), 0)::bigint AS goals_against,
      COALESCE(SUM(score_rows.goals_for - score_rows.goals_against), 0)::bigint AS goal_diff,
      COALESCE(SUM(score_rows.points), 0)::bigint AS points,
      COALESCE(SUM(score_rows.yellow_cards), 0)::bigint AS yellow_cards,
      COALESCE(SUM(score_rows.red_cards), 0)::bigint AS red_cards,
      COALESCE(SUM(score_rows.blue_cards), 0)::bigint AS blue_cards,
      COALESCE(SUM(score_rows.two_minute_penalties), 0)::bigint AS two_minute_penalties,
      COUNT(*) OVER (PARTITION BY groups_table.id)::bigint AS group_size
    FROM competition_context
    JOIN public.championship_bracket_groups AS groups_table
      ON groups_table.competition_id = competition_context.competition_id
    JOIN public.championship_bracket_group_teams AS group_teams_table
      ON group_teams_table.group_id = groups_table.id
    JOIN public.teams AS teams_table
      ON teams_table.id = group_teams_table.team_id
    LEFT JOIN score_rows
      ON score_rows.competition_id = competition_context.competition_id
      AND score_rows.group_id = groups_table.id
      AND score_rows.team_id = group_teams_table.team_id
    GROUP BY
      competition_context.competition_id, competition_context.sport_id, competition_context.sport_name,
      competition_context.naipe, competition_context.division, competition_context.tie_breaker_rule,
      groups_table.id, groups_table.group_number, group_teams_table.team_id, teams_table.name
  ), group_metric_ties AS (
    SELECT
      group_rows.group_id,
      string_agg(group_rows.team_id::text, '|' ORDER BY group_rows.team_id::text) AS tied_team_signature,
      array_agg(group_rows.team_id ORDER BY group_rows.team_id::text) AS team_ids
    FROM group_rows
    GROUP BY group_rows.group_id, group_rows.points, group_rows.wins, group_rows.goal_diff,
      group_rows.goals_for, group_rows.goals_against, group_rows.yellow_cards,
      group_rows.red_cards, group_rows.blue_cards, group_rows.two_minute_penalties
    HAVING COUNT(*) > 1
  ), group_draw_orders AS (
    SELECT
      group_metric_ties.group_id,
      tied_team.team_id,
      resolution_teams_table.draw_order
    FROM group_metric_ties
    JOIN LATERAL unnest(group_metric_ties.team_ids) AS tied_team(team_id) ON TRUE
    LEFT JOIN public.championship_bracket_tie_break_resolutions AS resolutions_table
      ON resolutions_table.context_key = public.build_championship_bracket_tie_break_context_key(
        'GROUP'::public.championship_bracket_tie_break_context_type,
        (SELECT competition_id FROM group_rows WHERE group_rows.group_id = group_metric_ties.group_id LIMIT 1),
        group_metric_ties.group_id,
        NULL,
        group_metric_ties.tied_team_signature
      )
    LEFT JOIN public.championship_bracket_tie_break_resolution_teams AS resolution_teams_table
      ON resolution_teams_table.resolution_id = resolutions_table.id
      AND resolution_teams_table.team_id = tied_team.team_id
  ), ranked_groups AS (
    SELECT
      group_rows.*,
      ROW_NUMBER() OVER (
        PARTITION BY group_rows.group_id
        ORDER BY
          group_rows.points DESC,
          CASE WHEN group_rows.tie_breaker_rule IN ('BEACH_SOCCER'::public.championship_sport_tie_breaker_rule, 'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule, 'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule, 'STANDARD'::public.championship_sport_tie_breaker_rule) THEN group_rows.wins END DESC NULLS LAST,
          CASE WHEN group_rows.tie_breaker_rule = 'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule AND group_rows.goals_against > 0 THEN group_rows.goals_for::numeric / group_rows.goals_against END DESC NULLS LAST,
          group_rows.goal_diff DESC,
          group_rows.goals_for DESC,
          CASE WHEN group_rows.tie_breaker_rule = 'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule THEN group_rows.goals_against END ASC NULLS LAST,
          CASE WHEN group_rows.tie_breaker_rule = 'HANDEBOL'::public.championship_sport_tie_breaker_rule THEN group_rows.blue_cards END ASC NULLS LAST,
          CASE WHEN group_rows.tie_breaker_rule = 'HANDEBOL'::public.championship_sport_tie_breaker_rule THEN group_rows.two_minute_penalties END ASC NULLS LAST,
          CASE WHEN group_rows.tie_breaker_rule IN ('BEACH_SOCCER'::public.championship_sport_tie_breaker_rule, 'STANDARD'::public.championship_sport_tie_breaker_rule, 'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule) THEN group_rows.yellow_cards END ASC NULLS LAST,
          CASE WHEN group_rows.tie_breaker_rule IN ('BEACH_SOCCER'::public.championship_sport_tie_breaker_rule, 'STANDARD'::public.championship_sport_tie_breaker_rule, 'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule) THEN group_rows.red_cards END ASC NULLS LAST,
          COALESCE(group_draw_orders.draw_order, 2147483647),
          group_rows.team_name
      )::integer AS group_rank
    FROM group_rows
    LEFT JOIN group_draw_orders
      ON group_draw_orders.group_id = group_rows.group_id
      AND group_draw_orders.team_id = group_rows.team_id
  ), comparison_rows AS (
    SELECT
      ranked_groups.*,
      GREATEST(MAX(ranked_groups.group_size - 1) OVER (PARTITION BY ranked_groups.competition_id), 1)::numeric AS maximum_group_matches,
      MIN(ranked_groups.group_size) OVER (PARTITION BY ranked_groups.competition_id)
        IS DISTINCT FROM MAX(ranked_groups.group_size) OVER (PARTITION BY ranked_groups.competition_id)
        AS uses_proportional_points
    FROM ranked_groups
  ), compared_points AS (
    SELECT
      comparison_rows.*,
      CASE
        WHEN comparison_rows.uses_proportional_points THEN
          comparison_rows.points::numeric
          * comparison_rows.maximum_group_matches
          / GREATEST(comparison_rows.group_size - 1, 1)
        ELSE comparison_rows.points::numeric
      END AS comparison_points
    FROM comparison_rows
  ), ranked_comparisons AS (
    SELECT
      compared_points.*,
      ROW_NUMBER() OVER (
        PARTITION BY compared_points.competition_id, compared_points.group_rank
        ORDER BY
          compared_points.comparison_points DESC,
          CASE
            WHEN compared_points.uses_proportional_points THEN NULL::bigint
            WHEN compared_points.tie_breaker_rule IN (
              'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
              'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule,
              'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule,
              'STANDARD'::public.championship_sport_tie_breaker_rule
            ) THEN compared_points.wins
            ELSE NULL::bigint
          END DESC NULLS LAST,
          CASE
            WHEN compared_points.uses_proportional_points THEN NULL::numeric
            WHEN compared_points.tie_breaker_rule = 'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule
              AND compared_points.goals_against > 0
            THEN compared_points.goals_for::numeric / compared_points.goals_against
            ELSE NULL::numeric
          END DESC NULLS LAST,
          compared_points.goal_diff DESC,
          compared_points.goals_for DESC,
          CASE
            WHEN compared_points.tie_breaker_rule = 'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule
            THEN compared_points.goals_against
            ELSE NULL::bigint
          END ASC NULLS LAST,
          CASE
            WHEN compared_points.uses_proportional_points THEN NULL::bigint
            WHEN compared_points.tie_breaker_rule = 'HANDEBOL'::public.championship_sport_tie_breaker_rule
            THEN compared_points.blue_cards
            ELSE NULL::bigint
          END ASC NULLS LAST,
          CASE
            WHEN compared_points.uses_proportional_points THEN NULL::bigint
            WHEN compared_points.tie_breaker_rule = 'HANDEBOL'::public.championship_sport_tie_breaker_rule
            THEN compared_points.two_minute_penalties
            ELSE NULL::bigint
          END ASC NULLS LAST,
          CASE
            WHEN compared_points.tie_breaker_rule IN (
              'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
              'STANDARD'::public.championship_sport_tie_breaker_rule,
              'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule
            ) THEN compared_points.yellow_cards
            ELSE NULL::bigint
          END ASC NULLS LAST,
          CASE
            WHEN compared_points.tie_breaker_rule IN (
              'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
              'STANDARD'::public.championship_sport_tie_breaker_rule,
              'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule
            ) THEN compared_points.red_cards
            ELSE NULL::bigint
          END ASC NULLS LAST,
          compared_points.team_name
      )::integer AS comparison_rank
    FROM compared_points
  )
  SELECT
    ranked_comparisons.competition_id, ranked_comparisons.sport_id, ranked_comparisons.sport_name,
    ranked_comparisons.naipe, ranked_comparisons.division, ranked_comparisons.group_id,
    ranked_comparisons.group_number, ranked_comparisons.team_id, ranked_comparisons.team_name,
    ranked_comparisons.played, ranked_comparisons.wins, ranked_comparisons.draws,
    ranked_comparisons.losses, ranked_comparisons.goals_for, ranked_comparisons.goals_against,
    ranked_comparisons.goal_diff, ranked_comparisons.points, ranked_comparisons.comparison_points, ranked_comparisons.yellow_cards,
    ranked_comparisons.red_cards, ranked_comparisons.blue_cards, ranked_comparisons.two_minute_penalties,
    ranked_comparisons.group_rank, ranked_comparisons.comparison_rank
  FROM ranked_comparisons
  ORDER BY ranked_comparisons.sport_name, ranked_comparisons.naipe, ranked_comparisons.division NULLS FIRST,
    ranked_comparisons.group_rank, ranked_comparisons.comparison_rank, ranked_comparisons.team_name;
$function$;

-- get_championship_group_stage_standings_display_metrics(_championship_id uuid, _season_year integer)
CREATE OR REPLACE FUNCTION public.get_championship_group_stage_standings_display_metrics(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS TABLE(competition_id uuid, sport_id uuid, sport_name text, naipe match_naipe, division team_division, group_id uuid, group_number integer, team_id uuid, team_name text, played bigint, wins bigint, draws bigint, losses bigint, goals_for bigint, goals_against bigint, goal_diff bigint, points bigint, comparison_points numeric, yellow_cards bigint, red_cards bigint, blue_cards bigint, two_minute_penalties bigint, sets_for bigint, sets_against bigint, rally_points_for bigint, rally_points_against bigint, group_rank integer, comparison_rank integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH group_stage_standings AS (
    SELECT *
    FROM public.get_championship_group_stage_standings(
      _championship_id,
      _season_year
    )
  ), set_metrics AS (
    SELECT
      bracket_matches_table.competition_id,
      bracket_matches_table.group_id,
      matches_table.home_team_id AS team_id,
      COUNT(*) FILTER (
        WHERE match_sets_table.home_points > match_sets_table.away_points
      )::bigint AS sets_for,
      COUNT(*) FILTER (
        WHERE match_sets_table.home_points < match_sets_table.away_points
      )::bigint AS sets_against,
      COALESCE(SUM(match_sets_table.home_points), 0)::bigint AS rally_points_for,
      COALESCE(SUM(match_sets_table.away_points), 0)::bigint AS rally_points_against
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    JOIN public.match_sets AS match_sets_table
      ON match_sets_table.match_id = matches_table.id
    WHERE bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
      AND matches_table.championship_id = _championship_id
      AND (_season_year IS NULL OR matches_table.season_year = _season_year)
      AND matches_table.status = 'FINISHED'::public.match_status
      AND COALESCE(matches_table.is_double_walkover, false) = false
    GROUP BY
      bracket_matches_table.competition_id,
      bracket_matches_table.group_id,
      matches_table.home_team_id

    UNION ALL

    SELECT
      bracket_matches_table.competition_id,
      bracket_matches_table.group_id,
      matches_table.away_team_id,
      COUNT(*) FILTER (
        WHERE match_sets_table.away_points > match_sets_table.home_points
      )::bigint,
      COUNT(*) FILTER (
        WHERE match_sets_table.away_points < match_sets_table.home_points
      )::bigint,
      COALESCE(SUM(match_sets_table.away_points), 0)::bigint,
      COALESCE(SUM(match_sets_table.home_points), 0)::bigint
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    JOIN public.match_sets AS match_sets_table
      ON match_sets_table.match_id = matches_table.id
    WHERE bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
      AND matches_table.championship_id = _championship_id
      AND (_season_year IS NULL OR matches_table.season_year = _season_year)
      AND matches_table.status = 'FINISHED'::public.match_status
      AND COALESCE(matches_table.is_double_walkover, false) = false
    GROUP BY
      bracket_matches_table.competition_id,
      bracket_matches_table.group_id,
      matches_table.away_team_id
  ), aggregated_set_metrics AS (
    SELECT
      set_metrics.competition_id,
      set_metrics.group_id,
      set_metrics.team_id,
      SUM(set_metrics.sets_for)::bigint AS sets_for,
      SUM(set_metrics.sets_against)::bigint AS sets_against,
      SUM(set_metrics.rally_points_for)::bigint AS rally_points_for,
      SUM(set_metrics.rally_points_against)::bigint AS rally_points_against
    FROM set_metrics
    GROUP BY
      set_metrics.competition_id,
      set_metrics.group_id,
      set_metrics.team_id
  )
  SELECT
    group_stage_standings.competition_id,
    group_stage_standings.sport_id,
    group_stage_standings.sport_name,
    group_stage_standings.naipe,
    group_stage_standings.division,
    group_stage_standings.group_id,
    group_stage_standings.group_number,
    group_stage_standings.team_id,
    group_stage_standings.team_name,
    group_stage_standings.played,
    group_stage_standings.wins,
    group_stage_standings.draws,
    group_stage_standings.losses,
    group_stage_standings.goals_for,
    group_stage_standings.goals_against,
    group_stage_standings.goal_diff,
    group_stage_standings.points,
    group_stage_standings.comparison_points,
    group_stage_standings.yellow_cards,
    group_stage_standings.red_cards,
    group_stage_standings.blue_cards,
    group_stage_standings.two_minute_penalties,
    COALESCE(aggregated_set_metrics.sets_for, 0)::bigint,
    COALESCE(aggregated_set_metrics.sets_against, 0)::bigint,
    COALESCE(aggregated_set_metrics.rally_points_for, 0)::bigint,
    COALESCE(aggregated_set_metrics.rally_points_against, 0)::bigint,
    group_stage_standings.group_rank,
    group_stage_standings.comparison_rank
  FROM group_stage_standings
  LEFT JOIN aggregated_set_metrics
    ON aggregated_set_metrics.competition_id = group_stage_standings.competition_id
    AND aggregated_set_metrics.group_id = group_stage_standings.group_id
    AND aggregated_set_metrics.team_id = group_stage_standings.team_id;
$function$;
