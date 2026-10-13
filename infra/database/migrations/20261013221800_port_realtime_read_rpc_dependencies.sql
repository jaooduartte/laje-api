-- LAJE-89: read-only PostgreSQL RPC parity for AWS staging and future cutover.
-- Functions obtained via pg_get_functiondef from Supabase public schema on 2026-10-13.
-- Additive migration; never modify previously applied migrations.
-- Exact source function definitions retained, including security definer and timeouts.
-- All invoked SQL functions must exist after the transactional migration finishes.
SET check_function_bodies = off;

-- Supabase source RPC: build_championship_bracket_tie_break_context_key
CREATE OR REPLACE FUNCTION public.build_championship_bracket_tie_break_context_key(_context_type championship_bracket_tie_break_context_type, _competition_id uuid, _group_id uuid DEFAULT NULL::uuid, _qualification_rank integer DEFAULT NULL::integer, _tied_team_signature text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF _context_type = 'GROUP'::public.championship_bracket_tie_break_context_type THEN
    RETURN format(
      'GROUP:%s:%s:%s',
      _competition_id,
      COALESCE(_group_id::text, 'NONE'),
      COALESCE(_tied_team_signature, '')
    );
  END IF;

  RETURN format(
    'QUALIFICATION_POOL:%s:%s:%s',
    _competition_id,
    COALESCE(_qualification_rank::text, '0'),
    COALESCE(_tied_team_signature, '')
  );
END;
$function$;

-- Supabase source RPC: get_interlaje_classification_policy
CREATE OR REPLACE FUNCTION public.get_interlaje_classification_policy(_championship_id uuid, _sport_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT championship_sports_table.classification_policy
  FROM public.championship_sports AS championship_sports_table
  JOIN public.championships AS championships_table
    ON championships_table.id = championship_sports_table.championship_id
  WHERE championship_sports_table.championship_id = _championship_id
    AND championship_sports_table.sport_id = _sport_id
    AND championships_table.code = 'INTERLAJE'::public.championship_code
$function$;

-- Supabase source RPC: is_championship_competition_team_disqualified
CREATE OR REPLACE FUNCTION public.is_championship_competition_team_disqualified(_championship_id uuid, _season_year integer, _sport_id uuid, _naipe match_naipe, _division team_division, _team_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.championship_competition_team_disqualifications AS disqualifications_table
    WHERE disqualifications_table.championship_id = _championship_id
      AND disqualifications_table.season_year = _season_year
      AND disqualifications_table.sport_id = _sport_id
      AND disqualifications_table.naipe = _naipe
      AND disqualifications_table.division IS NOT DISTINCT FROM _division
      AND disqualifications_table.team_id = _team_id
  );
$function$;

-- Supabase source RPC: normalize_sport_name
CREATE OR REPLACE FUNCTION public.normalize_sport_name(sport_name text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
BEGIN
  RETURN trim(
    lower(
      translate(
        COALESCE(sport_name, ''),
        'ÁÀÃÂÉÈÊÍÌÎÓÒÕÔÚÙÛÇáàãâéèêíìîóòõôúùûç',
        'AAAAEEEIIIOOOOUUUCaaaaeeeiiioooouuuc'
      )
    )
  );
END;
$function$;

-- Supabase source RPC: resolve_championship_competition_expected_knockout_rounds
CREATE OR REPLACE FUNCTION public.resolve_championship_competition_expected_knockout_rounds(_competition_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  competition_record RECORD;
  group_count_value INTEGER;
  direct_qualified_team_count INTEGER;
  target_bracket_size INTEGER := 1;
  total_rounds INTEGER := 0;
BEGIN
  SELECT
    competitions_table.qualifiers_per_group,
    competitions_table
      .should_complete_knockout_with_best_second_placed_teams
  INTO competition_record
  FROM public.championship_bracket_competitions
    AS competitions_table
  WHERE competitions_table.id = _competition_id
  LIMIT 1;

  IF competition_record.qualifiers_per_group IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COUNT(*)::integer
  INTO group_count_value
  FROM public.championship_bracket_groups
    AS groups_table
  WHERE groups_table.competition_id = _competition_id;

  direct_qualified_team_count := GREATEST(
    0,
    group_count_value
      * competition_record.qualifiers_per_group
  );

  IF competition_record.qualifiers_per_group = 1
    AND competition_record
      .should_complete_knockout_with_best_second_placed_teams =
        true
  THEN
    WHILE
      target_bracket_size <= direct_qualified_team_count
    LOOP
      target_bracket_size := target_bracket_size * 2;
    END LOOP;
  ELSE
    WHILE
      target_bracket_size < direct_qualified_team_count
    LOOP
      target_bracket_size := target_bracket_size * 2;
    END LOOP;
  END IF;

  IF target_bracket_size < 2 THEN
    RETURN 0;
  END IF;

  WHILE target_bracket_size > 1 LOOP
    target_bracket_size := target_bracket_size / 2;
    total_rounds := total_rounds + 1;
  END LOOP;

  RETURN total_rounds;
END;
$function$;

-- Supabase source RPC: resolve_interlaje_match_winner
CREATE OR REPLACE FUNCTION public.resolve_interlaje_match_winner(_match_id uuid, _home_team_id uuid, _away_team_id uuid, _structural_winner_team_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  match_record RECORD;
BEGIN
  IF _home_team_id IS NULL OR _away_team_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF _match_id IS NOT NULL THEN
    SELECT
      matches_table.status,
      matches_table.home_score,
      matches_table.away_score,
      matches_table.home_penalty_score,
      matches_table.away_penalty_score,
      matches_table.resolved_tie_break_winner_team_id,
      matches_table.is_walkover,
      matches_table.walkover_loser_team_id,
      matches_table.is_double_walkover
    INTO match_record
    FROM public.matches AS matches_table
    WHERE matches_table.id = _match_id
    LIMIT 1;

    IF match_record.status = 'FINISHED'::public.match_status THEN
      IF COALESCE(match_record.is_double_walkover, false) THEN
        RETURN CASE
          WHEN _structural_winner_team_id IN (_home_team_id, _away_team_id)
            THEN _structural_winner_team_id
          ELSE NULL
        END;
      END IF;

      IF match_record.resolved_tie_break_winner_team_id IN (_home_team_id, _away_team_id) THEN
        RETURN match_record.resolved_tie_break_winner_team_id;
      END IF;

      IF COALESCE(match_record.is_walkover, false)
        AND match_record.walkover_loser_team_id IN (_home_team_id, _away_team_id)
      THEN
        RETURN CASE
          WHEN match_record.walkover_loser_team_id = _home_team_id THEN _away_team_id
          ELSE _home_team_id
        END;
      END IF;

      IF match_record.home_score > match_record.away_score THEN
        RETURN _home_team_id;
      END IF;

      IF match_record.away_score > match_record.home_score THEN
        RETURN _away_team_id;
      END IF;

      IF match_record.home_penalty_score IS NOT NULL
        AND match_record.away_penalty_score IS NOT NULL
        AND match_record.home_penalty_score <> match_record.away_penalty_score
      THEN
        RETURN CASE
          WHEN match_record.home_penalty_score > match_record.away_penalty_score
            THEN _home_team_id
          ELSE _away_team_id
        END;
      END IF;

      -- Uma partida encerrada nunca é decidida por seed. Se o resultado real
      -- ainda não identifica um vencedor, aceitamos apenas o vencedor estrutural
      -- que já tenha sido explicitamente gravado na chave.
      RETURN CASE
        WHEN _structural_winner_team_id IN (_home_team_id, _away_team_id)
          THEN _structural_winner_team_id
        ELSE NULL
      END;
    END IF;
  END IF;

  RETURN CASE
    WHEN _structural_winner_team_id IN (_home_team_id, _away_team_id)
      THEN _structural_winner_team_id
    ELSE NULL
  END;
END;
$function$;

-- Supabase source RPC: get_interlaje_position_point_settings
CREATE OR REPLACE FUNCTION public.get_interlaje_position_point_settings(_championship_id uuid, _season_year integer)
 RETURNS TABLE(final_position integer, points integer)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT settings_table.final_position, settings_table.points
  FROM public.championship_overall_position_point_settings AS settings_table
  WHERE settings_table.championship_id = _championship_id
    AND settings_table.season_year = _season_year
  ORDER BY settings_table.final_position;
$function$;

-- Supabase source RPC: get_championship_effective_standings_base
CREATE OR REPLACE FUNCTION public.get_championship_effective_standings_base(_championship_id uuid DEFAULT NULL::uuid, _season_year integer DEFAULT NULL::integer, _division_filter text DEFAULT NULL::text, _naipe match_naipe DEFAULT NULL::match_naipe, _sport_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, championship_id uuid, season_year integer, division team_division, naipe match_naipe, sport_id uuid, team_id uuid, played integer, wins integer, draws integer, losses integer, goals_for integer, goals_against integer, goal_diff integer, points numeric, yellow_cards integer, red_cards integer, blue_cards integer, two_minute_penalties integer, updated_at timestamp with time zone, is_individual_sport boolean, scored_events_count integer, first_places integer, second_places integer, third_places integer, fourth_places integer, fifth_places integer, sixth_places integer, seventh_places integer, eighth_places integer, ninth_places integer, tenth_places integer, eleventh_places integer, twelfth_places integer, thirteenth_places integer, fourteenth_places integer, fifteenth_places integer, sixteenth_places integer, seventeenth_places integer, eighteenth_places integer, nineteenth_places integer, twentieth_places integer, relay_points_total numeric, team_name text, team_city text, sport_name text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH collective_standings AS (
    SELECT
      standings_table.id,
      standings_table.championship_id,
      standings_table.season_year,
      standings_table.division,
      standings_table.naipe,
      standings_table.sport_id,
      standings_table.team_id,
      standings_table.played,
      standings_table.wins,
      standings_table.draws,
      standings_table.losses,
      standings_table.goals_for,
      standings_table.goals_against,
      standings_table.goal_diff,
      standings_table.points::numeric AS points,
      standings_table.yellow_cards,
      standings_table.red_cards,
      standings_table.blue_cards,
      standings_table.two_minute_penalties,
      standings_table.updated_at,
      false AS is_individual_sport,
      0 AS scored_events_count,
      0 AS first_places,
      0 AS second_places,
      0 AS third_places,
      0 AS fourth_places,
      0 AS fifth_places,
      0 AS sixth_places,
      0 AS seventh_places,
      0 AS eighth_places,
      0 AS ninth_places,
      0 AS tenth_places,
      0 AS eleventh_places,
      0 AS twelfth_places,
      0 AS thirteenth_places,
      0 AS fourteenth_places,
      0 AS fifteenth_places,
      0 AS sixteenth_places,
      0 AS seventeenth_places,
      0 AS eighteenth_places,
      0 AS nineteenth_places,
      0 AS twentieth_places,
      0::numeric AS relay_points_total
    FROM public.standings AS standings_table
    WHERE (_championship_id IS NULL OR standings_table.championship_id = _championship_id)
      AND (_season_year IS NULL OR standings_table.season_year = _season_year)
      AND (_sport_id IS NULL OR standings_table.sport_id = _sport_id)
      AND (_naipe IS NULL OR standings_table.naipe = _naipe)
      AND (
        _division_filter IS NULL
        OR (_division_filter = 'WITHOUT_DIVISION' AND standings_table.division IS NULL)
        OR (_division_filter NOT IN ('WITHOUT_DIVISION') AND standings_table.division::text = _division_filter)
      )
  ),
  individual_standings AS (
    SELECT
      standings_table.id,
      standings_table.championship_id,
      standings_table.season_year,
      standings_table.division,
      standings_table.naipe,
      standings_table.sport_id,
      standings_table.team_id,
      standings_table.scored_events_count AS played,
      standings_table.first_places AS wins,
      standings_table.second_places AS draws,
      0 AS losses,
      0 AS goals_for,
      0 AS goals_against,
      0 AS goal_diff,
      standings_table.total_points AS points,
      0 AS yellow_cards,
      0 AS red_cards,
      0 AS blue_cards,
      0 AS two_minute_penalties,
      standings_table.updated_at,
      true AS is_individual_sport,
      standings_table.scored_events_count,
      standings_table.first_places,
      standings_table.second_places,
      standings_table.third_places,
      standings_table.fourth_places,
      standings_table.fifth_places,
      standings_table.sixth_places,
      standings_table.seventh_places,
      standings_table.eighth_places,
      standings_table.ninth_places,
      standings_table.tenth_places,
      standings_table.eleventh_places,
      standings_table.twelfth_places,
      standings_table.thirteenth_places,
      standings_table.fourteenth_places,
      standings_table.fifteenth_places,
      standings_table.sixteenth_places,
      standings_table.seventeenth_places,
      standings_table.eighteenth_places,
      standings_table.nineteenth_places,
      standings_table.twentieth_places,
      standings_table.relay_points_total
    FROM public.championship_individual_team_standings AS standings_table
    WHERE (_championship_id IS NULL OR standings_table.championship_id = _championship_id)
      AND (_season_year IS NULL OR standings_table.season_year = _season_year)
      AND (_sport_id IS NULL OR standings_table.sport_id = _sport_id)
      AND (_naipe IS NULL OR standings_table.naipe = _naipe)
      AND (
        _division_filter IS NULL
        OR (_division_filter = 'WITHOUT_DIVISION' AND standings_table.division IS NULL)
        OR (_division_filter NOT IN ('WITHOUT_DIVISION') AND standings_table.division::text = _division_filter)
      )
  ),
  effective_standings AS (
    SELECT * FROM collective_standings
    UNION ALL
    SELECT * FROM individual_standings
  )
  SELECT
    effective_standings.id,
    effective_standings.championship_id,
    effective_standings.season_year,
    effective_standings.division,
    effective_standings.naipe,
    effective_standings.sport_id,
    effective_standings.team_id,
    effective_standings.played,
    effective_standings.wins,
    effective_standings.draws,
    effective_standings.losses,
    effective_standings.goals_for,
    effective_standings.goals_against,
    effective_standings.goal_diff,
    effective_standings.points,
    effective_standings.yellow_cards,
    effective_standings.red_cards,
    effective_standings.blue_cards,
    effective_standings.two_minute_penalties,
    effective_standings.updated_at,
    effective_standings.is_individual_sport,
    effective_standings.scored_events_count,
    effective_standings.first_places,
    effective_standings.second_places,
    effective_standings.third_places,
    effective_standings.fourth_places,
    effective_standings.fifth_places,
    effective_standings.sixth_places,
    effective_standings.seventh_places,
    effective_standings.eighth_places,
    effective_standings.ninth_places,
    effective_standings.tenth_places,
    effective_standings.eleventh_places,
    effective_standings.twelfth_places,
    effective_standings.thirteenth_places,
    effective_standings.fourteenth_places,
    effective_standings.fifteenth_places,
    effective_standings.sixteenth_places,
    effective_standings.seventeenth_places,
    effective_standings.eighteenth_places,
    effective_standings.nineteenth_places,
    effective_standings.twentieth_places,
    effective_standings.relay_points_total,
    teams_table.name AS team_name,
    teams_table.city AS team_city,
    sports_table.name AS sport_name
  FROM effective_standings
  JOIN public.teams AS teams_table
    ON teams_table.id = effective_standings.team_id
  JOIN public.sports AS sports_table
    ON sports_table.id = effective_standings.sport_id;
$function$;

-- Supabase source RPC: get_championship_bracket_competition_group_rankings
CREATE OR REPLACE FUNCTION public.get_championship_bracket_competition_group_rankings(_championship_id uuid, _competition_id uuid)
 RETURNS TABLE(competition_id uuid, group_id uuid, group_number integer, team_id uuid, team_name text, points bigint, wins bigint, goal_diff bigint, goals_for bigint, team_rank integer)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH competition_context AS (
    SELECT
      competitions_table.id,
      competitions_table.sport_id,
      competitions_table.naipe,
      competitions_table.division,
      editions_table.season_year,
      COALESCE(championship_sports_table.points_win, 3) AS points_win,
      COALESCE(championship_sports_table.points_draw, 1) AS points_draw,
      COALESCE(championship_sports_table.points_loss, 0) AS points_loss,
      COALESCE(
        championship_sports_table.tie_breaker_rule,
        'STANDARD'::public.championship_sport_tie_breaker_rule
      ) AS tie_breaker_rule
    FROM public.championship_bracket_competitions AS competitions_table
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = _championship_id
      AND championship_sports_table.sport_id = competitions_table.sport_id
    WHERE competitions_table.id = _competition_id
    LIMIT 1
  ),
  group_scores AS (
    SELECT
      bracket_matches_table.group_id,
      matches_table.home_team_id AS team_id,
      matches_table.home_score::bigint AS goals_for,
      matches_table.away_score::bigint AS goals_against,
      CASE
        WHEN EXISTS (
          SELECT 1
          FROM public.championship_bracket_competitions AS competitions_table
          JOIN public.championships AS championships_table
            ON championships_table.id = _championship_id
          JOIN public.sports AS sports_table
            ON sports_table.id = competitions_table.sport_id
          WHERE competitions_table.id = _competition_id
            AND championships_table.code = 'INTERLAJE'::public.championship_code
            AND public.normalize_sport_name(sports_table.name) = 'voleibol'
        ) THEN CASE
          WHEN matches_table.home_score = 2 AND matches_table.away_score = 0 THEN 3
          WHEN matches_table.home_score = 2 AND matches_table.away_score = 1 THEN 2
          WHEN matches_table.home_score = 1 AND matches_table.away_score = 2 THEN 1
          ELSE 0
        END
        WHEN matches_table.home_score > matches_table.away_score THEN (SELECT points_win FROM competition_context)
        WHEN matches_table.home_score = matches_table.away_score THEN (SELECT points_draw FROM competition_context)
        ELSE (SELECT points_loss FROM competition_context)
      END::bigint AS points,
      CASE WHEN matches_table.home_score > matches_table.away_score THEN 1 ELSE 0 END::bigint AS wins,
      GREATEST(0, COALESCE(matches_table.home_yellow_cards, 0))::bigint AS yellow_cards,
      GREATEST(0, COALESCE(matches_table.home_red_cards, 0))::bigint AS red_cards,
      GREATEST(0, COALESCE(matches_table.home_blue_cards, 0))::bigint AS blue_cards,
      GREATEST(0, COALESCE(matches_table.home_two_minute_penalties, 0))::bigint AS two_minute_penalties
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    WHERE bracket_matches_table.competition_id = _competition_id
      AND bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
      AND matches_table.status = 'FINISHED'::public.match_status
      AND COALESCE(matches_table.is_double_walkover, false) = false

    UNION ALL

    SELECT
      bracket_matches_table.group_id,
      matches_table.away_team_id AS team_id,
      matches_table.away_score::bigint AS goals_for,
      matches_table.home_score::bigint AS goals_against,
      CASE
        WHEN EXISTS (
          SELECT 1
          FROM public.championship_bracket_competitions AS competitions_table
          JOIN public.championships AS championships_table
            ON championships_table.id = _championship_id
          JOIN public.sports AS sports_table
            ON sports_table.id = competitions_table.sport_id
          WHERE competitions_table.id = _competition_id
            AND championships_table.code = 'INTERLAJE'::public.championship_code
            AND public.normalize_sport_name(sports_table.name) = 'voleibol'
        ) THEN CASE
          WHEN matches_table.home_score = 0 AND matches_table.away_score = 2 THEN 3
          WHEN matches_table.home_score = 1 AND matches_table.away_score = 2 THEN 2
          WHEN matches_table.home_score = 2 AND matches_table.away_score = 1 THEN 1
          ELSE 0
        END
        WHEN matches_table.away_score > matches_table.home_score THEN (SELECT points_win FROM competition_context)
        WHEN matches_table.away_score = matches_table.home_score THEN (SELECT points_draw FROM competition_context)
        ELSE (SELECT points_loss FROM competition_context)
      END::bigint AS points,
      CASE WHEN matches_table.away_score > matches_table.home_score THEN 1 ELSE 0 END::bigint AS wins,
      GREATEST(0, COALESCE(matches_table.away_yellow_cards, 0))::bigint AS yellow_cards,
      GREATEST(0, COALESCE(matches_table.away_red_cards, 0))::bigint AS red_cards,
      GREATEST(0, COALESCE(matches_table.away_blue_cards, 0))::bigint AS blue_cards,
      GREATEST(0, COALESCE(matches_table.away_two_minute_penalties, 0))::bigint AS two_minute_penalties
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    WHERE bracket_matches_table.competition_id = _competition_id
      AND bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
      AND matches_table.status = 'FINISHED'::public.match_status
      AND COALESCE(matches_table.is_double_walkover, false) = false
  ),
  raw_group_rows AS (
    SELECT
      groups_table.id AS group_id,
      groups_table.group_number,
      group_teams_table.team_id,
      COALESCE(sum(group_scores.points), 0)::bigint AS points,
      COALESCE(sum(group_scores.wins), 0)::bigint AS wins,
      COALESCE(sum(group_scores.goals_for - group_scores.goals_against), 0)::bigint AS goal_diff,
      COALESCE(sum(group_scores.goals_for), 0)::bigint AS goals_for,
      COALESCE(sum(group_scores.goals_against), 0)::bigint AS goals_against,
      COALESCE(sum(group_scores.yellow_cards), 0)::bigint AS yellow_cards,
      COALESCE(sum(group_scores.red_cards), 0)::bigint AS red_cards,
      COALESCE(sum(group_scores.blue_cards), 0)::bigint AS blue_cards,
      COALESCE(sum(group_scores.two_minute_penalties), 0)::bigint AS two_minute_penalties
    FROM public.championship_bracket_groups AS groups_table
    JOIN public.championship_bracket_group_teams AS group_teams_table
      ON group_teams_table.group_id = groups_table.id
    LEFT JOIN group_scores
      ON group_scores.group_id = groups_table.id
      AND group_scores.team_id = group_teams_table.team_id
    WHERE groups_table.competition_id = _competition_id
    GROUP BY groups_table.id, groups_table.group_number, group_teams_table.team_id
  ),
  group_rows AS (
    SELECT
      raw_group_rows.group_id,
      raw_group_rows.group_number,
      raw_group_rows.team_id,
      raw_group_rows.points,
      raw_group_rows.wins,
      COALESCE(standings_table.goal_diff, raw_group_rows.goal_diff)::bigint AS goal_diff,
      COALESCE(standings_table.goals_for, raw_group_rows.goals_for)::bigint AS goals_for,
      COALESCE(standings_table.goals_against, GREATEST(raw_group_rows.goals_for - COALESCE(standings_table.goal_diff, raw_group_rows.goal_diff), 0))::bigint AS goals_against,
      COALESCE(standings_table.yellow_cards, raw_group_rows.yellow_cards)::bigint AS yellow_cards,
      COALESCE(standings_table.red_cards, raw_group_rows.red_cards)::bigint AS red_cards,
      COALESCE(standings_table.blue_cards, raw_group_rows.blue_cards)::bigint AS blue_cards,
      COALESCE(standings_table.two_minute_penalties, raw_group_rows.two_minute_penalties)::bigint AS two_minute_penalties,
      CASE
        WHEN COALESCE(standings_table.goals_against, GREATEST(raw_group_rows.goals_for - COALESCE(standings_table.goal_diff, raw_group_rows.goal_diff), 0)) = 0 THEN
          CASE
            WHEN COALESCE(standings_table.goals_for, raw_group_rows.goals_for) = 0 THEN 0::numeric
            ELSE 1000000000::numeric
          END
        ELSE COALESCE(standings_table.goals_for, raw_group_rows.goals_for)::numeric / COALESCE(standings_table.goals_against, GREATEST(raw_group_rows.goals_for - COALESCE(standings_table.goal_diff, raw_group_rows.goal_diff), 0))::numeric
      END AS points_average
    FROM raw_group_rows
    CROSS JOIN competition_context
    LEFT JOIN public.standings AS standings_table
      ON standings_table.championship_id = _championship_id
      AND standings_table.season_year = competition_context.season_year
      AND standings_table.sport_id = competition_context.sport_id
      AND standings_table.naipe = competition_context.naipe
      AND standings_table.division IS NOT DISTINCT FROM competition_context.division
      AND standings_table.team_id = raw_group_rows.team_id
  ),
  unresolved_metric_tie_sets AS (
    SELECT
      group_rows.group_id,
      string_agg(group_rows.team_id::text, '|' ORDER BY group_rows.team_id::text) AS tied_team_signature,
      array_agg(group_rows.team_id ORDER BY group_rows.team_id::text) AS tied_team_ids
    FROM group_rows
    CROSS JOIN competition_context
    GROUP BY
      group_rows.group_id,
      group_rows.points,
      CASE
        WHEN competition_context.tie_breaker_rule IN (
          'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
          'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule,
          'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule,
          'STANDARD'::public.championship_sport_tie_breaker_rule
        ) THEN group_rows.wins
        ELSE NULL::bigint
      END,
      group_rows.goal_diff,
      group_rows.goals_for,
      CASE
        WHEN competition_context.tie_breaker_rule = 'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule
          THEN group_rows.points_average
        ELSE NULL::numeric
      END,
      CASE
        WHEN competition_context.tie_breaker_rule = 'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule
          THEN group_rows.goals_against
        ELSE NULL::bigint
      END,
      CASE
        WHEN competition_context.tie_breaker_rule = 'HANDEBOL'::public.championship_sport_tie_breaker_rule
          THEN group_rows.blue_cards
        ELSE NULL::bigint
      END,
      CASE
        WHEN competition_context.tie_breaker_rule = 'HANDEBOL'::public.championship_sport_tie_breaker_rule
          THEN group_rows.two_minute_penalties
        ELSE NULL::bigint
      END,
      CASE
        WHEN competition_context.tie_breaker_rule IN (
          'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
          'STANDARD'::public.championship_sport_tie_breaker_rule,
          'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule
        ) THEN group_rows.yellow_cards
        ELSE NULL::bigint
      END,
      CASE
        WHEN competition_context.tie_breaker_rule IN (
          'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
          'STANDARD'::public.championship_sport_tie_breaker_rule,
          'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule
        ) THEN group_rows.red_cards
        ELSE NULL::bigint
      END,
      competition_context.tie_breaker_rule
    HAVING count(*) > 1
  ),
  unresolved_tie_context_members AS (
    SELECT
      unresolved_metric_tie_sets.group_id,
      unnest(unresolved_metric_tie_sets.tied_team_ids) AS team_id,
      public.build_championship_bracket_tie_break_context_key(
        'GROUP'::public.championship_bracket_tie_break_context_type,
        _competition_id,
        unresolved_metric_tie_sets.group_id,
        NULL,
        unresolved_metric_tie_sets.tied_team_signature
      ) AS context_key
    FROM unresolved_metric_tie_sets
  ),
  unresolved_tie_resolution_orders AS (
    SELECT
      unresolved_tie_context_members.group_id,
      unresolved_tie_context_members.team_id,
      resolution_teams_table.draw_order
    FROM unresolved_tie_context_members
    LEFT JOIN public.championship_bracket_tie_break_resolutions AS resolutions_table
      ON resolutions_table.context_key = unresolved_tie_context_members.context_key
    LEFT JOIN public.championship_bracket_tie_break_resolution_teams AS resolution_teams_table
      ON resolution_teams_table.resolution_id = resolutions_table.id
      AND resolution_teams_table.team_id = unresolved_tie_context_members.team_id
  ),
  direct_confrontation_pair_candidates AS (
    SELECT
      group_rows.group_id,
      array_agg(group_rows.team_id ORDER BY group_rows.team_id::text) AS team_ids
    FROM group_rows
    CROSS JOIN competition_context
    GROUP BY
      group_rows.group_id,
      group_rows.points,
      CASE
        WHEN competition_context.tie_breaker_rule = 'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule
          THEN group_rows.wins
        ELSE NULL::bigint
      END,
      competition_context.tie_breaker_rule
    HAVING count(*) = 2
      AND competition_context.tie_breaker_rule IN (
        'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
        'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule,
        'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule,
        'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule,
        'HANDEBOL'::public.championship_sport_tie_breaker_rule
      )
  ),
  direct_confrontation_pair_stats AS (
    SELECT
      direct_confrontation_pair_candidates.group_id,
      direct_confrontation_pair_candidates.team_ids[1] AS first_team_id,
      direct_confrontation_pair_candidates.team_ids[2] AS second_team_id,
      COALESCE(sum(
        CASE
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.home_score > matches_table.away_score THEN 3
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.home_score = matches_table.away_score THEN 1
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.away_score > matches_table.home_score THEN 3
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.away_score = matches_table.home_score THEN 1
          ELSE 0
        END
      ), 0)::int AS first_team_points,
      COALESCE(sum(
        CASE
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.home_score > matches_table.away_score THEN 3
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.home_score = matches_table.away_score THEN 1
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.away_score > matches_table.home_score THEN 3
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.away_score = matches_table.home_score THEN 1
          ELSE 0
        END
      ), 0)::int AS second_team_points,
      COALESCE(sum(
        CASE
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[2] THEN matches_table.home_score
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[1] THEN matches_table.away_score
          ELSE 0
        END
      ), 0)::int AS first_team_goals,
      COALESCE(sum(
        CASE
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[2]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[1] THEN matches_table.home_score
          WHEN matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[1]
            AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[2] THEN matches_table.away_score
          ELSE 0
        END
      ), 0)::int AS second_team_goals
    FROM direct_confrontation_pair_candidates
    LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.group_id = direct_confrontation_pair_candidates.group_id
      AND bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
    LEFT JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
      AND matches_table.status = 'FINISHED'::public.match_status
      AND COALESCE(matches_table.is_double_walkover, false) = false
      AND (
        (
          matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[1]
          AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[2]
        )
        OR
        (
          matches_table.home_team_id = direct_confrontation_pair_candidates.team_ids[2]
          AND matches_table.away_team_id = direct_confrontation_pair_candidates.team_ids[1]
        )
      )
    GROUP BY direct_confrontation_pair_candidates.group_id, direct_confrontation_pair_candidates.team_ids
  ),
  direct_confrontation_orders AS (
    SELECT
      direct_confrontation_pair_stats.group_id,
      direct_confrontation_pair_stats.first_team_id AS team_id,
      CASE
        WHEN
          direct_confrontation_pair_stats.first_team_points > direct_confrontation_pair_stats.second_team_points
          OR (
            direct_confrontation_pair_stats.first_team_points = direct_confrontation_pair_stats.second_team_points
            AND direct_confrontation_pair_stats.first_team_goals > direct_confrontation_pair_stats.second_team_goals
          ) THEN 0
        WHEN
          direct_confrontation_pair_stats.second_team_points > direct_confrontation_pair_stats.first_team_points
          OR (
            direct_confrontation_pair_stats.second_team_points = direct_confrontation_pair_stats.first_team_points
            AND direct_confrontation_pair_stats.second_team_goals > direct_confrontation_pair_stats.first_team_goals
          ) THEN 1
        ELSE NULL::int
      END AS direct_order
    FROM direct_confrontation_pair_stats

    UNION ALL

    SELECT
      direct_confrontation_pair_stats.group_id,
      direct_confrontation_pair_stats.second_team_id AS team_id,
      CASE
        WHEN
          direct_confrontation_pair_stats.second_team_points > direct_confrontation_pair_stats.first_team_points
          OR (
            direct_confrontation_pair_stats.second_team_points = direct_confrontation_pair_stats.first_team_points
            AND direct_confrontation_pair_stats.second_team_goals > direct_confrontation_pair_stats.first_team_goals
          ) THEN 0
        WHEN
          direct_confrontation_pair_stats.first_team_points > direct_confrontation_pair_stats.second_team_points
          OR (
            direct_confrontation_pair_stats.first_team_points = direct_confrontation_pair_stats.second_team_points
            AND direct_confrontation_pair_stats.first_team_goals > direct_confrontation_pair_stats.second_team_goals
          ) THEN 1
        ELSE NULL::int
      END AS direct_order
    FROM direct_confrontation_pair_stats
  ),
  ranked AS (
    SELECT
      _competition_id AS competition_id,
      group_rows.group_id,
      group_rows.group_number,
      group_rows.team_id,
      teams_table.name AS team_name,
      group_rows.points,
      group_rows.wins,
      group_rows.goal_diff,
      group_rows.goals_for,
      row_number() OVER (
        PARTITION BY group_rows.group_id
        ORDER BY
          group_rows.points DESC,
          CASE
            WHEN competition_context.tie_breaker_rule IN (
              'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
              'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule,
              'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule,
              'HANDEBOL'::public.championship_sport_tie_breaker_rule
            ) THEN direct_confrontation_orders.direct_order
            ELSE NULL::int
          END ASC NULLS LAST,
          CASE
            WHEN competition_context.tie_breaker_rule IN (
              'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
              'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule
            ) THEN group_rows.wins
            ELSE NULL::bigint
          END DESC NULLS LAST,
          CASE
            WHEN competition_context.tie_breaker_rule = 'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule
              THEN direct_confrontation_orders.direct_order
            ELSE NULL::int
          END ASC NULLS LAST,
          CASE
            WHEN competition_context.tie_breaker_rule = 'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule
              THEN group_rows.points_average
            ELSE NULL::numeric
          END DESC NULLS LAST,
          group_rows.goal_diff DESC,
          group_rows.goals_for DESC,
          CASE
            WHEN competition_context.tie_breaker_rule = 'HANDEBOL'::public.championship_sport_tie_breaker_rule
              THEN group_rows.blue_cards
            ELSE NULL::bigint
          END ASC NULLS LAST,
          CASE
            WHEN competition_context.tie_breaker_rule = 'HANDEBOL'::public.championship_sport_tie_breaker_rule
              THEN group_rows.two_minute_penalties
            ELSE NULL::bigint
          END ASC NULLS LAST,
          CASE
            WHEN competition_context.tie_breaker_rule IN (
              'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule,
              'STANDARD'::public.championship_sport_tie_breaker_rule
            ) THEN group_rows.wins
            ELSE NULL::bigint
          END DESC NULLS LAST,
          CASE
            WHEN competition_context.tie_breaker_rule = 'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule
              THEN group_rows.goals_against
            ELSE NULL::bigint
          END ASC NULLS LAST,
          CASE
            WHEN competition_context.tie_breaker_rule IN (
              'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
              'STANDARD'::public.championship_sport_tie_breaker_rule,
              'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule
            ) THEN group_rows.yellow_cards
            ELSE NULL::bigint
          END ASC NULLS LAST,
          CASE
            WHEN competition_context.tie_breaker_rule IN (
              'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
              'STANDARD'::public.championship_sport_tie_breaker_rule,
              'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule
            ) THEN group_rows.red_cards
            ELSE NULL::bigint
          END ASC NULLS LAST,
          COALESCE(unresolved_tie_resolution_orders.draw_order, 2147483647) ASC,
          teams_table.name ASC
      ) AS team_rank
    FROM group_rows
    JOIN public.teams AS teams_table
      ON teams_table.id = group_rows.team_id
    CROSS JOIN competition_context
    LEFT JOIN unresolved_tie_resolution_orders
      ON unresolved_tie_resolution_orders.group_id = group_rows.group_id
      AND unresolved_tie_resolution_orders.team_id = group_rows.team_id
    LEFT JOIN direct_confrontation_orders
      ON direct_confrontation_orders.group_id = group_rows.group_id
      AND direct_confrontation_orders.team_id = group_rows.team_id
  )
  SELECT
    ranked.competition_id,
    ranked.group_id,
    ranked.group_number,
    ranked.team_id,
    ranked.team_name,
    ranked.points,
    ranked.wins,
    ranked.goal_diff,
    ranked.goals_for,
    ranked.team_rank
  FROM ranked
  ORDER BY ranked.group_number ASC, ranked.team_rank ASC, ranked.team_name ASC;
$function$;

-- Supabase source RPC: get_championship_bracket_tie_break_contexts
CREATE OR REPLACE FUNCTION public.get_championship_bracket_tie_break_contexts(_championship_id uuid, _competition_id uuid DEFAULT NULL::uuid, _bracket_edition_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(bracket_edition_id uuid, competition_id uuid, sport_name text, naipe match_naipe, division team_division, context_type championship_bracket_tie_break_context_type, group_id uuid, group_number integer, qualification_rank integer, context_key text, tied_team_signature text, team_ids uuid[], team_names text[], title text, description text, is_resolved boolean)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH edition_context AS (
    SELECT
      COALESCE(
        _bracket_edition_id,
        (
          SELECT editions_table.id
          FROM public.championship_bracket_editions AS editions_table
          WHERE editions_table.championship_id = _championship_id
          ORDER BY editions_table.created_at DESC
          LIMIT 1
        )
      ) AS bracket_edition_id
  ),
  group_statuses AS (
    SELECT
      groups_table.id AS group_id,
      groups_table.competition_id,
      groups_table.group_number,
      count(bracket_matches_table.id)::int AS total_matches,
      count(*) FILTER (
        WHERE matches_table.status = 'FINISHED'::public.match_status
      )::int AS finished_matches,
      (
        count(bracket_matches_table.id) > 0
        AND count(*) FILTER (
          WHERE matches_table.status = 'FINISHED'::public.match_status
        ) = count(bracket_matches_table.id)
      ) AS is_group_finished
    FROM public.championship_bracket_groups AS groups_table
    LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.group_id = groups_table.id
      AND bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
    LEFT JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    GROUP BY groups_table.id, groups_table.competition_id, groups_table.group_number
  ),
  competition_context AS (
    SELECT
      competitions_table.id,
      competitions_table.bracket_edition_id,
      competitions_table.qualifiers_per_group,
      competitions_table.should_complete_knockout_with_best_second_placed_teams,
      competitions_table.naipe,
      competitions_table.division,
      sports_table.name AS sport_name,
      COALESCE(
        championship_sports_table.tie_breaker_rule,
        'STANDARD'::public.championship_sport_tie_breaker_rule
      ) AS tie_breaker_rule,
      group_aggregates.group_count,
      group_aggregates.finished_group_count,
      group_aggregates.all_groups_finished,
      CASE
        WHEN (group_aggregates.group_count * competitions_table.qualifiers_per_group) < 2 THEN
          (group_aggregates.group_count * competitions_table.qualifiers_per_group)
        WHEN competitions_table.qualifiers_per_group = 1
          AND competitions_table.should_complete_knockout_with_best_second_placed_teams = true THEN
          power(
            2,
            floor(log(2, (group_aggregates.group_count * competitions_table.qualifiers_per_group)::numeric)) + 1
          )::int
        ELSE
          power(2, ceil(log(2, (group_aggregates.group_count * competitions_table.qualifiers_per_group)::numeric)))::int
      END AS target_bracket_size
    FROM public.championship_bracket_competitions AS competitions_table
    JOIN edition_context
      ON edition_context.bracket_edition_id = competitions_table.bracket_edition_id
    JOIN public.sports AS sports_table
      ON sports_table.id = competitions_table.sport_id
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = _championship_id
      AND championship_sports_table.sport_id = competitions_table.sport_id
    JOIN (
      SELECT
        group_statuses.competition_id,
        count(*)::int AS group_count,
        count(*) FILTER (WHERE group_statuses.is_group_finished)::int AS finished_group_count,
        bool_and(group_statuses.is_group_finished) AS all_groups_finished
      FROM group_statuses
      GROUP BY group_statuses.competition_id
    ) AS group_aggregates
      ON group_aggregates.competition_id = competitions_table.id
    WHERE (_competition_id IS NULL OR competitions_table.id = _competition_id)
  ),
  group_score_rows AS (
    SELECT
      bracket_matches_table.group_id,
      matches_table.home_team_id AS team_id,
      matches_table.home_score::bigint AS goals_for,
      matches_table.away_score::bigint AS goals_against,
      CASE
        WHEN matches_table.home_score > matches_table.away_score THEN COALESCE(championship_sports_table.points_win, 3)
        WHEN matches_table.home_score = matches_table.away_score THEN COALESCE(championship_sports_table.points_draw, 1)
        ELSE COALESCE(championship_sports_table.points_loss, 0)
      END::bigint AS points,
      CASE WHEN matches_table.home_score > matches_table.away_score THEN 1 ELSE 0 END::bigint AS wins,
      GREATEST(0, COALESCE(matches_table.home_yellow_cards, 0))::bigint AS yellow_cards,
      GREATEST(0, COALESCE(matches_table.home_red_cards, 0))::bigint AS red_cards
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    JOIN public.championship_bracket_competitions AS competitions_table
      ON competitions_table.id = bracket_matches_table.competition_id
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = _championship_id
      AND championship_sports_table.sport_id = competitions_table.sport_id
    WHERE bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
      AND matches_table.status = 'FINISHED'::public.match_status
      AND (_competition_id IS NULL OR bracket_matches_table.competition_id = _competition_id)

    UNION ALL

    SELECT
      bracket_matches_table.group_id,
      matches_table.away_team_id AS team_id,
      matches_table.away_score::bigint AS goals_for,
      matches_table.home_score::bigint AS goals_against,
      CASE
        WHEN matches_table.away_score > matches_table.home_score THEN COALESCE(championship_sports_table.points_win, 3)
        WHEN matches_table.away_score = matches_table.home_score THEN COALESCE(championship_sports_table.points_draw, 1)
        ELSE COALESCE(championship_sports_table.points_loss, 0)
      END::bigint AS points,
      CASE WHEN matches_table.away_score > matches_table.home_score THEN 1 ELSE 0 END::bigint AS wins,
      GREATEST(0, COALESCE(matches_table.away_yellow_cards, 0))::bigint AS yellow_cards,
      GREATEST(0, COALESCE(matches_table.away_red_cards, 0))::bigint AS red_cards
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    JOIN public.championship_bracket_competitions AS competitions_table
      ON competitions_table.id = bracket_matches_table.competition_id
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = _championship_id
      AND championship_sports_table.sport_id = competitions_table.sport_id
    WHERE bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
      AND matches_table.status = 'FINISHED'::public.match_status
      AND (_competition_id IS NULL OR bracket_matches_table.competition_id = _competition_id)
  ),
  group_metrics AS (
    SELECT
      groups_table.id AS group_id,
      groups_table.competition_id,
      groups_table.group_number,
      group_teams_table.team_id,
      COALESCE(sum(group_score_rows.points), 0)::bigint AS points,
      COALESCE(sum(group_score_rows.wins), 0)::bigint AS wins,
      COALESCE(sum(group_score_rows.goals_for - group_score_rows.goals_against), 0)::bigint AS goal_diff,
      COALESCE(sum(group_score_rows.goals_for), 0)::bigint AS goals_for,
      COALESCE(sum(group_score_rows.goals_against), 0)::bigint AS goals_against,
      COALESCE(sum(group_score_rows.yellow_cards), 0)::bigint AS yellow_cards,
      COALESCE(sum(group_score_rows.red_cards), 0)::bigint AS red_cards,
      CASE
        WHEN COALESCE(sum(group_score_rows.goals_against), 0) = 0 THEN
          CASE
            WHEN COALESCE(sum(group_score_rows.goals_for), 0) = 0 THEN 0::numeric
            ELSE 1000000000::numeric
          END
        ELSE COALESCE(sum(group_score_rows.goals_for), 0)::numeric / COALESCE(sum(group_score_rows.goals_against), 0)::numeric
      END AS points_average
    FROM public.championship_bracket_groups AS groups_table
    JOIN public.championship_bracket_group_teams AS group_teams_table
      ON group_teams_table.group_id = groups_table.id
    LEFT JOIN group_score_rows
      ON group_score_rows.group_id = groups_table.id
      AND group_score_rows.team_id = group_teams_table.team_id
    WHERE (_competition_id IS NULL OR groups_table.competition_id = _competition_id)
    GROUP BY groups_table.id, groups_table.competition_id, groups_table.group_number, group_teams_table.team_id
  ),
  group_rankings AS (
    SELECT
      competition_context.bracket_edition_id,
      competition_context.id AS competition_id,
      competition_context.sport_name,
      competition_context.naipe,
      competition_context.division,
      competition_context.tie_breaker_rule,
      competition_context.qualifiers_per_group,
      competition_context.should_complete_knockout_with_best_second_placed_teams,
      competition_context.target_bracket_size,
      competition_context.group_count,
      competition_context.all_groups_finished,
      rankings_table.group_id,
      rankings_table.group_number,
      rankings_table.team_id,
      rankings_table.team_name,
      rankings_table.points,
      rankings_table.wins,
      rankings_table.goal_diff,
      rankings_table.goals_for,
      rankings_table.team_rank,
      group_metrics.goals_against,
      group_metrics.yellow_cards,
      group_metrics.red_cards,
      group_metrics.points_average,
      group_statuses.is_group_finished
    FROM competition_context
    CROSS JOIN LATERAL public.get_championship_bracket_competition_group_rankings(
      _championship_id,
      competition_context.id
    ) AS rankings_table
    JOIN group_metrics
      ON group_metrics.group_id = rankings_table.group_id
      AND group_metrics.team_id = rankings_table.team_id
    JOIN group_statuses
      ON group_statuses.group_id = rankings_table.group_id
  ),
  group_tie_sets AS (
    SELECT
      group_rankings.bracket_edition_id,
      group_rankings.competition_id,
      group_rankings.sport_name,
      group_rankings.naipe,
      group_rankings.division,
      group_rankings.tie_breaker_rule,
      group_rankings.qualifiers_per_group,
      group_rankings.should_complete_knockout_with_best_second_placed_teams,
      bool_or(group_rankings.all_groups_finished) AS all_groups_finished,
      group_rankings.group_id,
      group_rankings.group_number,
      string_agg(group_rankings.team_id::text, '|' ORDER BY group_rankings.team_id::text) AS tied_team_signature,
      array_agg(group_rankings.team_id ORDER BY group_rankings.team_name ASC) AS team_ids,
      array_agg(group_rankings.team_name ORDER BY group_rankings.team_name ASC) AS team_names,
      min(group_rankings.team_rank)::int AS start_rank,
      max(group_rankings.team_rank)::int AS end_rank
    FROM group_rankings
    WHERE group_rankings.is_group_finished = true
    GROUP BY
      group_rankings.bracket_edition_id,
      group_rankings.competition_id,
      group_rankings.sport_name,
      group_rankings.naipe,
      group_rankings.division,
      group_rankings.tie_breaker_rule,
      group_rankings.qualifiers_per_group,
      group_rankings.should_complete_knockout_with_best_second_placed_teams,
      group_rankings.group_id,
      group_rankings.group_number,
      group_rankings.points,
      group_rankings.wins,
      group_rankings.goal_diff,
      group_rankings.goals_for,
      CASE
        WHEN group_rankings.tie_breaker_rule = 'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule
          THEN group_rankings.points_average
        ELSE NULL::numeric
      END,
      CASE
        WHEN group_rankings.tie_breaker_rule = 'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule
          THEN group_rankings.goals_against
        ELSE NULL::bigint
      END,
      CASE
        WHEN group_rankings.tie_breaker_rule IN (
          'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
          'STANDARD'::public.championship_sport_tie_breaker_rule
        ) THEN group_rankings.yellow_cards
        ELSE NULL::bigint
      END,
      CASE
        WHEN group_rankings.tie_breaker_rule IN (
          'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
          'STANDARD'::public.championship_sport_tie_breaker_rule
        ) THEN group_rankings.red_cards
        ELSE NULL::bigint
      END
    HAVING count(*) > 1
  ),
  group_two_team_head_to_head AS (
    SELECT
      group_tie_sets.group_id,
      group_tie_sets.tied_team_signature,
      group_tie_sets.team_ids[1] AS first_team_id,
      group_tie_sets.team_ids[2] AS second_team_id,
      COALESCE(sum(
        CASE
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[1]
            AND matches_table.away_team_id = group_tie_sets.team_ids[2]
            AND matches_table.home_score > matches_table.away_score THEN 3
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[1]
            AND matches_table.away_team_id = group_tie_sets.team_ids[2]
            AND matches_table.home_score = matches_table.away_score THEN 1
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[2]
            AND matches_table.away_team_id = group_tie_sets.team_ids[1]
            AND matches_table.away_score > matches_table.home_score THEN 3
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[2]
            AND matches_table.away_team_id = group_tie_sets.team_ids[1]
            AND matches_table.home_score = matches_table.away_score THEN 1
          ELSE 0
        END
      ), 0)::int AS first_team_points,
      COALESCE(sum(
        CASE
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[2]
            AND matches_table.away_team_id = group_tie_sets.team_ids[1]
            AND matches_table.home_score > matches_table.away_score THEN 3
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[2]
            AND matches_table.away_team_id = group_tie_sets.team_ids[1]
            AND matches_table.home_score = matches_table.away_score THEN 1
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[1]
            AND matches_table.away_team_id = group_tie_sets.team_ids[2]
            AND matches_table.away_score > matches_table.home_score THEN 3
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[1]
            AND matches_table.away_team_id = group_tie_sets.team_ids[2]
            AND matches_table.away_score = matches_table.home_score THEN 1
          ELSE 0
        END
      ), 0)::int AS second_team_points,
      COALESCE(sum(
        CASE
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[1]
            AND matches_table.away_team_id = group_tie_sets.team_ids[2] THEN matches_table.home_score
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[2]
            AND matches_table.away_team_id = group_tie_sets.team_ids[1] THEN matches_table.away_score
          ELSE 0
        END
      ), 0)::int AS first_team_goals,
      COALESCE(sum(
        CASE
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[2]
            AND matches_table.away_team_id = group_tie_sets.team_ids[1] THEN matches_table.home_score
          WHEN matches_table.home_team_id = group_tie_sets.team_ids[1]
            AND matches_table.away_team_id = group_tie_sets.team_ids[2] THEN matches_table.away_score
          ELSE 0
        END
      ), 0)::int AS second_team_goals
    FROM group_tie_sets
    LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.group_id = group_tie_sets.group_id
      AND bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
    LEFT JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
      AND matches_table.status = 'FINISHED'::public.match_status
      AND (
        (
          matches_table.home_team_id = group_tie_sets.team_ids[1]
          AND matches_table.away_team_id = group_tie_sets.team_ids[2]
        )
        OR
        (
          matches_table.home_team_id = group_tie_sets.team_ids[2]
          AND matches_table.away_team_id = group_tie_sets.team_ids[1]
        )
      )
    WHERE cardinality(group_tie_sets.team_ids) = 2
      AND group_tie_sets.tie_breaker_rule IN (
        'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
        'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule,
        'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule
      )
    GROUP BY group_tie_sets.group_id, group_tie_sets.tied_team_signature, group_tie_sets.team_ids
  ),
  group_contexts AS (
    SELECT
      group_tie_sets.bracket_edition_id,
      group_tie_sets.competition_id,
      group_tie_sets.sport_name,
      group_tie_sets.naipe,
      group_tie_sets.division,
      'GROUP'::public.championship_bracket_tie_break_context_type AS context_type,
      group_tie_sets.group_id,
      group_tie_sets.group_number,
      NULL::integer AS qualification_rank,
      public.build_championship_bracket_tie_break_context_key(
        'GROUP'::public.championship_bracket_tie_break_context_type,
        group_tie_sets.competition_id,
        group_tie_sets.group_id,
        NULL,
        group_tie_sets.tied_team_signature
      ) AS context_key,
      group_tie_sets.tied_team_signature,
      group_tie_sets.team_ids,
      group_tie_sets.team_names,
      CASE
        WHEN group_tie_sets.group_number BETWEEN 1 AND 26
          THEN format('Sorteio manual do Grupo %s', chr(64 + group_tie_sets.group_number))
        ELSE format('Sorteio manual do Grupo %s', group_tie_sets.group_number)
      END AS title,
      format(
        '%s • %s%s. As atléticas seguem empatadas após todos os critérios automáticos que influenciam a classificação do grupo.',
        group_tie_sets.sport_name,
        initcap(lower(group_tie_sets.naipe::text)),
        CASE
          WHEN group_tie_sets.division IS NULL THEN ''
          WHEN group_tie_sets.division = 'DIVISAO_PRINCIPAL'::public.team_division THEN ' • Divisão Principal'
          ELSE ' • Divisão de Acesso'
        END
      ) AS description
    FROM group_tie_sets
    LEFT JOIN group_two_team_head_to_head
      ON group_two_team_head_to_head.group_id = group_tie_sets.group_id
      AND group_two_team_head_to_head.tied_team_signature = group_tie_sets.tied_team_signature
    WHERE (
      (group_tie_sets.start_rank <= group_tie_sets.qualifiers_per_group)
      OR (
        group_tie_sets.qualifiers_per_group = 1
        AND group_tie_sets.should_complete_knockout_with_best_second_placed_teams = true
        AND group_tie_sets.start_rank = 2
        AND group_tie_sets.all_groups_finished = true
      )
    )
    AND NOT (
      cardinality(group_tie_sets.team_ids) = 2
      AND group_tie_sets.tie_breaker_rule IN (
        'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
        'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule,
        'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule
      )
      AND group_two_team_head_to_head.group_id IS NOT NULL
      AND (
        group_two_team_head_to_head.first_team_points != group_two_team_head_to_head.second_team_points
        OR group_two_team_head_to_head.first_team_goals != group_two_team_head_to_head.second_team_goals
      )
    )
  ),
  qualification_pool_rankings AS (
    SELECT
      competition_context.bracket_edition_id,
      competition_context.id AS competition_id,
      competition_context.sport_name,
      competition_context.naipe,
      competition_context.division,
      competition_context.tie_breaker_rule,
      competition_context.all_groups_finished,
      GREATEST(
        competition_context.target_bracket_size - (competition_context.group_count * competition_context.qualifiers_per_group),
        0
      ) AS required_additional_qualifiers,
      competition_context.should_complete_knockout_with_best_second_placed_teams,
      pool_rankings_table.team_id,
      pool_rankings_table.team_name,
      pool_rankings_table.qualification_rank,
      pool_rankings_table.points,
      pool_rankings_table.wins,
      pool_rankings_table.goal_diff,
      pool_rankings_table.goals_for,
      pool_rankings_table.pool_rank,
      group_metrics.goals_against,
      group_metrics.yellow_cards,
      group_metrics.red_cards,
      group_metrics.points_average
    FROM competition_context
    CROSS JOIN LATERAL public.get_championship_bracket_competition_qualification_pool_rankings(
      _championship_id,
      competition_context.id
    ) AS pool_rankings_table
    LEFT JOIN group_rankings
      ON group_rankings.competition_id = competition_context.id
      AND group_rankings.team_id = pool_rankings_table.team_id
      AND group_rankings.team_rank = pool_rankings_table.qualification_rank
    LEFT JOIN group_metrics
      ON group_metrics.group_id = group_rankings.group_id
      AND group_metrics.team_id = pool_rankings_table.team_id
  ),
  qualification_pool_tie_sets AS (
    SELECT
      qualification_pool_rankings.bracket_edition_id,
      qualification_pool_rankings.competition_id,
      qualification_pool_rankings.sport_name,
      qualification_pool_rankings.naipe,
      qualification_pool_rankings.division,
      qualification_pool_rankings.tie_breaker_rule,
      qualification_pool_rankings.required_additional_qualifiers,
      qualification_pool_rankings.should_complete_knockout_with_best_second_placed_teams,
      qualification_pool_rankings.all_groups_finished,
      qualification_pool_rankings.qualification_rank,
      string_agg(qualification_pool_rankings.team_id::text, '|' ORDER BY qualification_pool_rankings.team_id::text) AS tied_team_signature,
      array_agg(qualification_pool_rankings.team_id ORDER BY qualification_pool_rankings.team_name ASC) AS team_ids,
      array_agg(qualification_pool_rankings.team_name ORDER BY qualification_pool_rankings.team_name ASC) AS team_names,
      min(qualification_pool_rankings.pool_rank)::int AS start_rank,
      max(qualification_pool_rankings.pool_rank)::int AS end_rank
    FROM qualification_pool_rankings
    GROUP BY
      qualification_pool_rankings.bracket_edition_id,
      qualification_pool_rankings.competition_id,
      qualification_pool_rankings.sport_name,
      qualification_pool_rankings.naipe,
      qualification_pool_rankings.division,
      qualification_pool_rankings.tie_breaker_rule,
      qualification_pool_rankings.required_additional_qualifiers,
      qualification_pool_rankings.should_complete_knockout_with_best_second_placed_teams,
      qualification_pool_rankings.all_groups_finished,
      qualification_pool_rankings.qualification_rank,
      qualification_pool_rankings.points,
      qualification_pool_rankings.wins,
      qualification_pool_rankings.goal_diff,
      qualification_pool_rankings.goals_for,
      CASE
        WHEN qualification_pool_rankings.tie_breaker_rule = 'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule
          THEN qualification_pool_rankings.points_average
        ELSE NULL::numeric
      END,
      CASE
        WHEN qualification_pool_rankings.tie_breaker_rule = 'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule
          THEN qualification_pool_rankings.goals_against
        ELSE NULL::bigint
      END,
      CASE
        WHEN qualification_pool_rankings.tie_breaker_rule IN (
          'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
          'STANDARD'::public.championship_sport_tie_breaker_rule
        ) THEN qualification_pool_rankings.yellow_cards
        ELSE NULL::bigint
      END,
      CASE
        WHEN qualification_pool_rankings.tie_breaker_rule IN (
          'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
          'STANDARD'::public.championship_sport_tie_breaker_rule
        ) THEN qualification_pool_rankings.red_cards
        ELSE NULL::bigint
      END
    HAVING count(*) > 1
  ),
  qualification_pool_contexts AS (
    SELECT
      qualification_pool_tie_sets.bracket_edition_id,
      qualification_pool_tie_sets.competition_id,
      qualification_pool_tie_sets.sport_name,
      qualification_pool_tie_sets.naipe,
      qualification_pool_tie_sets.division,
      'QUALIFICATION_POOL'::public.championship_bracket_tie_break_context_type AS context_type,
      NULL::uuid AS group_id,
      NULL::integer AS group_number,
      qualification_pool_tie_sets.qualification_rank,
      public.build_championship_bracket_tie_break_context_key(
        'QUALIFICATION_POOL'::public.championship_bracket_tie_break_context_type,
        qualification_pool_tie_sets.competition_id,
        NULL,
        qualification_pool_tie_sets.qualification_rank,
        qualification_pool_tie_sets.tied_team_signature
      ) AS context_key,
      qualification_pool_tie_sets.tied_team_signature,
      qualification_pool_tie_sets.team_ids,
      qualification_pool_tie_sets.team_names,
      format(
        'Sorteio manual dos melhores %sº colocados',
        qualification_pool_tie_sets.qualification_rank
      ) AS title,
      format(
        '%s • %s%s. As atléticas seguem empatadas na definição do ranking geral (melhor %sº) e/ou disputa por vagas.',
        qualification_pool_tie_sets.sport_name,
        initcap(lower(qualification_pool_tie_sets.naipe::text)),
        CASE
          WHEN qualification_pool_tie_sets.division IS NULL THEN ''
          WHEN qualification_pool_tie_sets.division = 'DIVISAO_PRINCIPAL'::public.team_division THEN ' • Divisão Principal'
          ELSE ' • Divisão de Acesso'
        END,
        qualification_pool_tie_sets.qualification_rank
      ) AS description
    FROM qualification_pool_tie_sets
    WHERE qualification_pool_tie_sets.all_groups_finished = true
  ),
  all_contexts AS (
    SELECT * FROM group_contexts

    UNION ALL

    SELECT * FROM qualification_pool_contexts
  )
  SELECT
    all_contexts.bracket_edition_id,
    all_contexts.competition_id,
    all_contexts.sport_name,
    all_contexts.naipe,
    all_contexts.division,
    all_contexts.context_type,
    all_contexts.group_id,
    all_contexts.group_number,
    all_contexts.qualification_rank,
    all_contexts.context_key,
    all_contexts.tied_team_signature,
    all_contexts.team_ids,
    all_contexts.team_names,
    all_contexts.title,
    all_contexts.description,
    EXISTS (
      SELECT 1
      FROM public.championship_bracket_tie_break_resolutions AS resolutions_table
      WHERE resolutions_table.context_key = all_contexts.context_key
    ) AS is_resolved
  FROM all_contexts;
$function$;

-- Supabase source RPC: get_interlaje_collective_ranking
CREATE OR REPLACE FUNCTION public.get_interlaje_collective_ranking(_championship_id uuid, _season_year integer, _sport_id uuid, _naipe match_naipe, _division team_division DEFAULT NULL::team_division)
 RETURNS TABLE(team_id uuid, team_name text, division team_division, played integer, wins integer, draws integer, losses integer, goals_for integer, goals_against integer, goal_diff integer, points numeric, yellow_cards integer, red_cards integer, blue_cards integer, two_minute_penalties integer, sets_for integer, sets_against integer, rally_points_for integer, rally_points_against integer, classification_rank integer, has_pending_tie_break boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH policy AS (
    SELECT public.get_interlaje_classification_policy(_championship_id, _sport_id) AS value
  ), group_sizes AS (
    SELECT
      groups_table.id AS group_id,
      count(*)::integer AS group_size
    FROM public.championship_bracket_competitions AS competitions_table
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    JOIN public.championship_bracket_groups AS groups_table
      ON groups_table.competition_id = competitions_table.id
    JOIN public.championship_bracket_group_teams AS group_teams_table
      ON group_teams_table.group_id = groups_table.id
    WHERE editions_table.championship_id = _championship_id
      AND editions_table.season_year = _season_year
      AND competitions_table.sport_id = _sport_id
      AND competitions_table.naipe = _naipe
      AND competitions_table.division IS NOT DISTINCT FROM _division
    GROUP BY groups_table.id
  ), group_size_range AS (
    SELECT
      min(group_sizes.group_size)::integer AS minimum_group_size,
      max(group_sizes.group_size)::integer AS maximum_group_size
    FROM group_sizes
  ), group_context AS (
    SELECT
      group_teams_table.team_id,
      groups_table.id AS group_id,
      GREATEST(group_sizes.group_size - 1, 1)::numeric AS expected_matches,
      group_size_range.minimum_group_size IS DISTINCT FROM group_size_range.maximum_group_size AS has_uneven_groups
    FROM public.championship_bracket_competitions AS competitions_table
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    JOIN public.championship_bracket_groups AS groups_table
      ON groups_table.competition_id = competitions_table.id
    JOIN public.championship_bracket_group_teams AS group_teams_table
      ON group_teams_table.group_id = groups_table.id
    JOIN group_sizes
      ON group_sizes.group_id = groups_table.id
    CROSS JOIN group_size_range
    WHERE editions_table.championship_id = _championship_id
      AND editions_table.season_year = _season_year
      AND competitions_table.sport_id = _sport_id
      AND competitions_table.naipe = _naipe
      AND competitions_table.division IS NOT DISTINCT FROM _division
  ), effective AS (
    SELECT
      standings_table.team_id,
      standings_table.team_name,
      standings_table.division,
      standings_table.played,
      standings_table.wins,
      standings_table.draws,
      standings_table.losses,
      standings_table.goals_for,
      standings_table.goals_against,
      standings_table.goal_diff,
      standings_table.points
        + COALESCE(
          corrected_standings_table.corrected_points
          - corrected_standings_table.points_base,
          0
        ) AS points,
      standings_table.yellow_cards,
      standings_table.red_cards,
      COALESCE(source_standings.blue_cards, 0) AS blue_cards,
      COALESCE(source_standings.two_minute_penalties, 0) AS two_minute_penalties
    FROM public.get_championship_effective_standings(
      _championship_id,
      _season_year,
      _division::text,
      _naipe,
      _sport_id
    ) AS standings_table
    LEFT JOIN public.get_championship_corrected_group_standings(
      _championship_id,
      _season_year
    ) AS corrected_standings_table
      ON corrected_standings_table.team_id = standings_table.team_id
      AND corrected_standings_table.sport_id = _sport_id
      AND corrected_standings_table.naipe = _naipe
      AND corrected_standings_table.division IS NOT DISTINCT FROM standings_table.division
    LEFT JOIN public.standings AS source_standings
      ON source_standings.championship_id = _championship_id
      AND source_standings.season_year = _season_year
      AND source_standings.sport_id = _sport_id
      AND source_standings.naipe = _naipe
      AND source_standings.division IS NOT DISTINCT FROM standings_table.division
      AND source_standings.team_id = standings_table.team_id
  ), volleyball_metrics AS (
    SELECT
      participant.team_id,
      COALESCE(SUM(participant.sets_for), 0)::integer AS sets_for,
      COALESCE(SUM(participant.sets_against), 0)::integer AS sets_against,
      COALESCE(SUM(participant.rally_points_for), 0)::integer AS rally_points_for,
      COALESCE(SUM(participant.rally_points_against), 0)::integer AS rally_points_against
    FROM (
      SELECT
        matches_table.home_team_id AS team_id,
        COUNT(*) FILTER (WHERE match_sets_table.home_points > match_sets_table.away_points)::integer AS sets_for,
        COUNT(*) FILTER (WHERE match_sets_table.home_points < match_sets_table.away_points)::integer AS sets_against,
        COALESCE(SUM(match_sets_table.home_points), 0)::integer AS rally_points_for,
        COALESCE(SUM(match_sets_table.away_points), 0)::integer AS rally_points_against
      FROM public.matches AS matches_table
      LEFT JOIN public.match_sets AS match_sets_table ON match_sets_table.match_id = matches_table.id
      WHERE matches_table.championship_id = _championship_id
        AND matches_table.season_year = _season_year
        AND matches_table.sport_id = _sport_id
        AND matches_table.naipe = _naipe
        AND matches_table.division IS NOT DISTINCT FROM _division
        AND matches_table.status = 'FINISHED'::public.match_status
        AND COALESCE(matches_table.is_double_walkover, false) = false
      GROUP BY matches_table.home_team_id
      UNION ALL
      SELECT
        matches_table.away_team_id,
        COUNT(*) FILTER (WHERE match_sets_table.away_points > match_sets_table.home_points)::integer,
        COUNT(*) FILTER (WHERE match_sets_table.away_points < match_sets_table.home_points)::integer,
        COALESCE(SUM(match_sets_table.away_points), 0)::integer,
        COALESCE(SUM(match_sets_table.home_points), 0)::integer
      FROM public.matches AS matches_table
      LEFT JOIN public.match_sets AS match_sets_table ON match_sets_table.match_id = matches_table.id
      WHERE matches_table.championship_id = _championship_id
        AND matches_table.season_year = _season_year
        AND matches_table.sport_id = _sport_id
        AND matches_table.naipe = _naipe
        AND matches_table.division IS NOT DISTINCT FROM _division
        AND matches_table.status = 'FINISHED'::public.match_status
        AND COALESCE(matches_table.is_double_walkover, false) = false
      GROUP BY matches_table.away_team_id
    ) AS participant
    GROUP BY participant.team_id
  ), metrics AS (
    SELECT
      effective.*,
      COALESCE(volleyball_metrics.sets_for, 0) AS sets_for,
      COALESCE(volleyball_metrics.sets_against, 0) AS sets_against,
      COALESCE(volleyball_metrics.rally_points_for, 0) AS rally_points_for,
      COALESCE(volleyball_metrics.rally_points_against, 0) AS rally_points_against,
      CASE
        WHEN effective.goals_against = 0 AND effective.goals_for > 0 THEN 1000000000::numeric
        WHEN effective.goals_against = 0 THEN 0::numeric
        ELSE effective.goals_for::numeric / effective.goals_against
      END AS points_average
    FROM effective
    LEFT JOIN volleyball_metrics ON volleyball_metrics.team_id = effective.team_id
  ), prepared AS (
    SELECT
      metrics.*,
      group_context.group_id,
      COALESCE(group_context.expected_matches, 1::numeric) AS expected_matches,
      COALESCE(group_context.has_uneven_groups, false) AS has_uneven_groups,
      CASE
        WHEN metrics.sets_against = 0 AND metrics.sets_for > 0 THEN 1000000000::numeric
        WHEN metrics.sets_against = 0 THEN 0::numeric
        ELSE metrics.sets_for::numeric / metrics.sets_against
      END AS sets_average,
      public.normalize_sport_name(sports_table.name) AS sport_name
    FROM metrics
    JOIN public.sports AS sports_table ON sports_table.id = _sport_id
    LEFT JOIN group_context ON group_context.team_id = metrics.team_id
  ), comparison_metrics AS (
    SELECT
      prepared.*,
      prepared.points AS comparison_points,
      prepared.sets_for::numeric / prepared.expected_matches AS sets_for_per_match,
      prepared.sets_against::numeric / prepared.expected_matches AS sets_against_per_match,
      prepared.rally_points_for::numeric / prepared.expected_matches AS rally_points_for_per_match,
      prepared.rally_points_against::numeric / prepared.expected_matches AS rally_points_against_per_match,
      prepared.red_cards::numeric / prepared.expected_matches AS red_cards_per_match,
      prepared.yellow_cards::numeric / prepared.expected_matches AS yellow_cards_per_match
    FROM prepared
  ), h2h_scope AS (
    SELECT
      comparison_metrics.*,
      COUNT(*) OVER (
        PARTITION BY
          CASE WHEN comparison_metrics.sport_name = 'voleibol' AND comparison_metrics.has_uneven_groups THEN comparison_metrics.group_id END,
          comparison_metrics.comparison_points,
          CASE WHEN comparison_metrics.sport_name = 'basquetebol' THEN comparison_metrics.points_average WHEN comparison_metrics.sport_name = 'voleibol' THEN comparison_metrics.sets_average ELSE 0 END
      ) AS h2h_candidate_count
    FROM comparison_metrics
  ), h2h AS (
    SELECT
      h2h_scope.*,
      COALESCE((
        SELECT SUM(CASE
          WHEN matches_table.home_team_id = h2h_scope.team_id AND matches_table.home_score > matches_table.away_score THEN 3
          WHEN matches_table.away_team_id = h2h_scope.team_id AND matches_table.away_score > matches_table.home_score THEN 3
          WHEN matches_table.home_score = matches_table.away_score THEN 1
          ELSE 0
        END)
        FROM public.matches AS matches_table
        WHERE matches_table.championship_id = _championship_id
          AND matches_table.season_year = _season_year
          AND matches_table.sport_id = _sport_id
          AND matches_table.naipe = _naipe
          AND matches_table.division IS NOT DISTINCT FROM _division
          AND matches_table.status = 'FINISHED'::public.match_status
          AND COALESCE(matches_table.is_double_walkover, false) = false
          AND (matches_table.home_team_id = h2h_scope.team_id OR matches_table.away_team_id = h2h_scope.team_id)
          AND (matches_table.home_team_id = counterpart.team_id OR matches_table.away_team_id = counterpart.team_id)
      ), 0)::numeric AS head_to_head_points
    FROM h2h_scope
    LEFT JOIN h2h_scope AS counterpart
      ON counterpart.team_id <> h2h_scope.team_id
      AND counterpart.comparison_points = h2h_scope.comparison_points
      AND (
        (h2h_scope.sport_name = 'basquetebol' AND counterpart.points_average = h2h_scope.points_average)
        OR (h2h_scope.sport_name = 'voleibol' AND counterpart.sets_average = h2h_scope.sets_average)
        OR (h2h_scope.sport_name NOT IN ('basquetebol', 'voleibol'))
      )
      AND (
        h2h_scope.sport_name <> 'voleibol'
        OR NOT h2h_scope.has_uneven_groups
        OR counterpart.group_id IS NOT DISTINCT FROM h2h_scope.group_id
      )
      AND h2h_scope.h2h_candidate_count = 2
  ), ordered AS (
    SELECT
      h2h.*,
      COALESCE(resolutions_table.draw_order, 2147483647) AS draw_order,
      ROW_NUMBER() OVER (
        ORDER BY
          h2h.comparison_points DESC,
          CASE WHEN h2h.sport_name = 'basquetebol' THEN h2h.points_average END DESC NULLS LAST,
          CASE WHEN h2h.sport_name = 'voleibol' THEN h2h.sets_average END DESC NULLS LAST,
          CASE WHEN h2h.h2h_candidate_count = 2 THEN h2h.head_to_head_points END DESC NULLS LAST,
          CASE WHEN h2h.sport_name IN ('futsal', 'handebol') THEN h2h.goal_diff WHEN h2h.sport_name = 'basquetebol' THEN h2h.goal_diff END DESC NULLS LAST,
          CASE WHEN h2h.sport_name = 'futsal' THEN h2h.goals_for WHEN h2h.sport_name = 'basquetebol' THEN h2h.goals_for END DESC NULLS LAST,
          CASE WHEN h2h.sport_name = 'handebol' THEN h2h.goals_against WHEN h2h.sport_name = 'basquetebol' THEN h2h.goals_against END ASC NULLS LAST,
          CASE WHEN h2h.sport_name = 'handebol' THEN h2h.blue_cards END ASC NULLS LAST,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.sets_for_per_match WHEN h2h.sport_name = 'voleibol' THEN h2h.sets_for END DESC NULLS LAST,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.rally_points_for_per_match WHEN h2h.sport_name = 'voleibol' THEN h2h.rally_points_for END DESC NULLS LAST,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.sets_against_per_match WHEN h2h.sport_name = 'voleibol' THEN h2h.sets_against END ASC NULLS LAST,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.rally_points_against_per_match WHEN h2h.sport_name = 'voleibol' THEN h2h.rally_points_against END ASC NULLS LAST,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.red_cards_per_match WHEN h2h.sport_name IN ('basquetebol', 'futsal', 'handebol', 'voleibol') THEN h2h.red_cards END ASC NULLS LAST,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.yellow_cards_per_match WHEN h2h.sport_name IN ('futsal', 'handebol', 'voleibol') THEN h2h.yellow_cards END ASC NULLS LAST,
          CASE WHEN h2h.sport_name = 'handebol' THEN h2h.two_minute_penalties END ASC NULLS LAST,
          COALESCE(resolutions_table.draw_order, 2147483647) ASC,
          h2h.team_id ASC
      )::integer AS classification_rank,
      COUNT(*) OVER (
        PARTITION BY
          h2h.comparison_points,
          CASE WHEN h2h.sport_name = 'basquetebol' THEN h2h.points_average END,
          CASE WHEN h2h.sport_name = 'voleibol' THEN h2h.sets_average END,
          CASE WHEN h2h.h2h_candidate_count = 2 THEN h2h.head_to_head_points END,
          CASE WHEN h2h.sport_name IN ('futsal', 'handebol', 'basquetebol') THEN h2h.goal_diff END,
          CASE WHEN h2h.sport_name IN ('futsal', 'basquetebol') THEN h2h.goals_for END,
          CASE WHEN h2h.sport_name IN ('handebol', 'basquetebol') THEN h2h.goals_against END,
          CASE WHEN h2h.sport_name = 'handebol' THEN h2h.blue_cards END,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.sets_for_per_match WHEN h2h.sport_name = 'voleibol' THEN h2h.sets_for END,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.rally_points_for_per_match WHEN h2h.sport_name = 'voleibol' THEN h2h.rally_points_for END,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.sets_against_per_match WHEN h2h.sport_name = 'voleibol' THEN h2h.sets_against END,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.rally_points_against_per_match WHEN h2h.sport_name = 'voleibol' THEN h2h.rally_points_against END,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.red_cards_per_match WHEN h2h.sport_name IN ('basquetebol', 'futsal', 'handebol', 'voleibol') THEN h2h.red_cards END,
          CASE WHEN h2h.sport_name = 'voleibol' AND h2h.has_uneven_groups THEN h2h.yellow_cards_per_match WHEN h2h.sport_name IN ('futsal', 'handebol', 'voleibol') THEN h2h.yellow_cards END,
          CASE WHEN h2h.sport_name = 'handebol' THEN h2h.two_minute_penalties END
      ) AS unresolved_count
    FROM h2h
    LEFT JOIN public.championship_interlaje_tie_break_resolutions AS resolutions_table
      ON resolutions_table.championship_id = _championship_id
      AND resolutions_table.season_year = _season_year
      AND resolutions_table.sport_id = _sport_id
      AND resolutions_table.naipe = _naipe
      AND resolutions_table.division IS NOT DISTINCT FROM _division
      AND resolutions_table.group_id IS NULL
      AND resolutions_table.team_id = h2h.team_id
  )
  SELECT
    ordered.team_id, ordered.team_name, ordered.division, ordered.played, ordered.wins,
    ordered.draws, ordered.losses, ordered.goals_for, ordered.goals_against,
    ordered.goal_diff, ordered.points, ordered.yellow_cards, ordered.red_cards,
    ordered.blue_cards, ordered.two_minute_penalties, ordered.sets_for,
    ordered.sets_against, ordered.rally_points_for, ordered.rally_points_against,
    ordered.classification_rank,
    ordered.unresolved_count > 1 AND ordered.draw_order = 2147483647
  FROM ordered
  ORDER BY ordered.classification_rank;
$function$;

-- Supabase source RPC: get_interlaje_knockout_final_placements
CREATE OR REPLACE FUNCTION public.get_interlaje_knockout_final_placements(_competition_id uuid, _ranked_teams jsonb)
 RETURNS TABLE(team_id uuid, final_position integer, placement_status text, placement_basis text, placement_stage text, eliminated_by_team_id uuid, eliminated_by_final_position integer, placement_reason text)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  ranked_positions JSONB;
  virtual_matches JSONB := '{}'::JSONB;
  resolved_positions JSONB := '{}'::JSONB;
  eliminated_by JSONB := '{}'::JSONB;
  elimination_stage JSONB := '{}'::JSONB;
  first_round_number INTEGER;
  final_round_number INTEGER;
  participant_count INTEGER;
  current_round_number INTEGER;
  current_round_matches INTEGER;
  next_round_matches INTEGER;
  current_slot_number INTEGER;
  current_match RECORD;
  home_team_id UUID;
  away_team_id UUID;
  winner_team_id UUID;
  loser_team_id UUID;
  champion_team_id UUID;
  runner_up_team_id UUID;
  third_place_team_id UUID;
  fourth_place_team_id UUID;
  match_is_confirmed BOOLEAN;
  all_results_confirmed BOOLEAN := true;
BEGIN
  SELECT COALESCE(
    jsonb_object_agg(ranked_team.team_id::TEXT, ranked_team.final_position),
    '{}'::JSONB
  )
  INTO ranked_positions
  FROM jsonb_to_recordset(_ranked_teams) AS ranked_team(
    team_id UUID,
    final_position INTEGER
  );

  SELECT MIN(bracket_matches_table.round_number)
  INTO first_round_number
  FROM public.championship_bracket_matches AS bracket_matches_table
  WHERE bracket_matches_table.competition_id = _competition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_third_place = false;

  IF first_round_number IS NULL THEN
    RETURN;
  END IF;

  SELECT COUNT(DISTINCT participants.team_id)::INTEGER
  INTO participant_count
  FROM (
    SELECT bracket_matches_table.home_team_id AS team_id
    FROM public.championship_bracket_matches AS bracket_matches_table
    WHERE bracket_matches_table.competition_id = _competition_id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND bracket_matches_table.is_third_place = false
      AND bracket_matches_table.round_number = first_round_number
      AND bracket_matches_table.home_team_id IS NOT NULL

    UNION ALL

    SELECT bracket_matches_table.away_team_id AS team_id
    FROM public.championship_bracket_matches AS bracket_matches_table
    WHERE bracket_matches_table.competition_id = _competition_id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND bracket_matches_table.is_third_place = false
      AND bracket_matches_table.round_number = first_round_number
      AND bracket_matches_table.away_team_id IS NOT NULL
  ) AS participants;

  IF participant_count NOT IN (4, 8) THEN
    RETURN;
  END IF;

  final_round_number := first_round_number
    + CASE participant_count WHEN 4 THEN 1 ELSE 2 END;
  current_round_number := first_round_number;
  current_round_matches := participant_count / 2;

  FOR current_match IN
    SELECT
      bracket_matches_table.slot_number,
      bracket_matches_table.home_team_id,
      bracket_matches_table.away_team_id,
      bracket_matches_table.winner_team_id,
      bracket_matches_table.match_id,
      matches_table.status
    FROM public.championship_bracket_matches AS bracket_matches_table
    LEFT JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    WHERE bracket_matches_table.competition_id = _competition_id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND bracket_matches_table.is_third_place = false
      AND bracket_matches_table.round_number = first_round_number
    ORDER BY bracket_matches_table.slot_number
  LOOP
    home_team_id := current_match.home_team_id;
    away_team_id := current_match.away_team_id;

    IF home_team_id IS NULL OR away_team_id IS NULL THEN
      RETURN;
    END IF;

    winner_team_id := public.resolve_interlaje_match_winner(
      current_match.match_id,
      home_team_id,
      away_team_id,
      current_match.winner_team_id
    );

    match_is_confirmed := winner_team_id IS NOT NULL
      AND (
        current_match.status = 'FINISHED'::public.match_status
        OR current_match.winner_team_id IS NOT NULL
      );

    IF winner_team_id IS NULL THEN
      -- Seed só pode projetar partida que ainda não foi finalizada.
      IF current_match.status = 'FINISHED'::public.match_status THEN
        RETURN;
      END IF;

      winner_team_id := CASE
        WHEN COALESCE((ranked_positions ->> home_team_id::TEXT)::INTEGER, 2147483647)
          <= COALESCE((ranked_positions ->> away_team_id::TEXT)::INTEGER, 2147483647)
        THEN home_team_id
        ELSE away_team_id
      END;
      match_is_confirmed := false;
    END IF;

    loser_team_id := CASE
      WHEN winner_team_id = home_team_id THEN away_team_id
      ELSE home_team_id
    END;

    all_results_confirmed := all_results_confirmed AND match_is_confirmed;

    virtual_matches := virtual_matches || jsonb_build_object(
      format('%s:%s', current_round_number, current_match.slot_number),
      jsonb_build_object(
        'winner_team_id', winner_team_id,
        'loser_team_id', loser_team_id,
        'confirmed', match_is_confirmed
      )
    );
    eliminated_by := eliminated_by || jsonb_build_object(
      loser_team_id::TEXT,
      winner_team_id::TEXT
    );
    elimination_stage := elimination_stage || jsonb_build_object(
      loser_team_id::TEXT,
      CASE participant_count
        WHEN 8 THEN 'QUARTERFINAL'
        ELSE 'SEMIFINAL'
      END
    );
  END LOOP;

  WHILE current_round_number < final_round_number LOOP
    next_round_matches := current_round_matches / 2;

    FOR current_slot_number IN 1..next_round_matches LOOP
      home_team_id := (
        virtual_matches -> format('%s:%s', current_round_number, (current_slot_number * 2) - 1)
      ) ->> 'winner_team_id';
      away_team_id := (
        virtual_matches -> format('%s:%s', current_round_number, current_slot_number * 2)
      ) ->> 'winner_team_id';

      SELECT
        bracket_matches_table.winner_team_id,
        bracket_matches_table.match_id,
        matches_table.status
      INTO current_match
      FROM public.championship_bracket_matches AS bracket_matches_table
      LEFT JOIN public.matches AS matches_table
        ON matches_table.id = bracket_matches_table.match_id
      WHERE bracket_matches_table.competition_id = _competition_id
        AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
        AND bracket_matches_table.is_third_place = false
        AND bracket_matches_table.round_number = current_round_number + 1
        AND bracket_matches_table.slot_number = current_slot_number
      LIMIT 1;

      winner_team_id := public.resolve_interlaje_match_winner(
        current_match.match_id,
        home_team_id,
        away_team_id,
        current_match.winner_team_id
      );

      match_is_confirmed := winner_team_id IS NOT NULL
        AND (
          current_match.status = 'FINISHED'::public.match_status
          OR current_match.winner_team_id IS NOT NULL
        );

      IF winner_team_id IS NULL THEN
        IF current_match.status = 'FINISHED'::public.match_status THEN
          RETURN;
        END IF;

        winner_team_id := CASE
          WHEN COALESCE((ranked_positions ->> home_team_id::TEXT)::INTEGER, 2147483647)
            <= COALESCE((ranked_positions ->> away_team_id::TEXT)::INTEGER, 2147483647)
          THEN home_team_id
          ELSE away_team_id
        END;
        match_is_confirmed := false;
      END IF;

      loser_team_id := CASE
        WHEN winner_team_id = home_team_id THEN away_team_id
        ELSE home_team_id
      END;

      all_results_confirmed := all_results_confirmed AND match_is_confirmed;

      virtual_matches := virtual_matches || jsonb_build_object(
        format('%s:%s', current_round_number + 1, current_slot_number),
        jsonb_build_object(
          'winner_team_id', winner_team_id,
          'loser_team_id', loser_team_id,
          'confirmed', match_is_confirmed
        )
      );
      eliminated_by := eliminated_by || jsonb_build_object(
        loser_team_id::TEXT,
        winner_team_id::TEXT
      );
      elimination_stage := elimination_stage || jsonb_build_object(
        loser_team_id::TEXT,
        CASE
          WHEN current_round_number + 1 = final_round_number THEN 'FINAL'
          ELSE 'SEMIFINAL'
        END
      );
    END LOOP;

    current_round_number := current_round_number + 1;
    current_round_matches := next_round_matches;
  END LOOP;

  champion_team_id := (
    virtual_matches -> format('%s:%s', final_round_number, 1)
  ) ->> 'winner_team_id';
  runner_up_team_id := (
    virtual_matches -> format('%s:%s', final_round_number, 1)
  ) ->> 'loser_team_id';

  IF champion_team_id IS NULL OR runner_up_team_id IS NULL THEN
    RETURN;
  END IF;

  resolved_positions := jsonb_build_object(
    champion_team_id::TEXT, 1,
    runner_up_team_id::TEXT, 2
  );

  FOR current_slot_number IN 1..2 LOOP
    winner_team_id := (
      virtual_matches -> format('%s:%s', final_round_number - 1, current_slot_number)
    ) ->> 'winner_team_id';
    loser_team_id := (
      virtual_matches -> format('%s:%s', final_round_number - 1, current_slot_number)
    ) ->> 'loser_team_id';

    IF winner_team_id = champion_team_id THEN
      third_place_team_id := loser_team_id;
    ELSE
      fourth_place_team_id := loser_team_id;
    END IF;
  END LOOP;

  IF third_place_team_id IS NULL OR fourth_place_team_id IS NULL THEN
    RETURN;
  END IF;

  resolved_positions := resolved_positions || jsonb_build_object(
    third_place_team_id::TEXT, 3,
    fourth_place_team_id::TEXT, 4
  );

  IF participant_count = 8 THEN
    FOR current_slot_number IN 1..4 LOOP
      winner_team_id := (
        virtual_matches -> format('%s:%s', first_round_number, current_slot_number)
      ) ->> 'winner_team_id';
      loser_team_id := (
        virtual_matches -> format('%s:%s', first_round_number, current_slot_number)
      ) ->> 'loser_team_id';

      resolved_positions := resolved_positions || jsonb_build_object(
        loser_team_id::TEXT,
        CASE winner_team_id
          WHEN champion_team_id THEN 5
          WHEN runner_up_team_id THEN 6
          WHEN third_place_team_id THEN 7
          WHEN fourth_place_team_id THEN 8
          ELSE NULL
        END
      );
    END LOOP;
  END IF;

  RETURN QUERY
  SELECT
    placements.key::UUID AS team_id,
    placements.value::INTEGER AS final_position,
    CASE WHEN all_results_confirmed THEN 'CONFIRMED' ELSE 'PROJECTED' END AS placement_status,
    'KNOCKOUT'::TEXT AS placement_basis,
    COALESCE(
      elimination_stage ->> placements.key,
      CASE WHEN placements.value::INTEGER = 1 THEN 'FINAL' ELSE NULL END
    ) AS placement_stage,
    NULLIF(eliminated_by ->> placements.key, '')::UUID AS eliminated_by_team_id,
    CASE
      WHEN eliminated_by ? placements.key
      THEN (resolved_positions ->> (eliminated_by ->> placements.key))::INTEGER
      ELSE NULL
    END AS eliminated_by_final_position,
    CASE placements.value::INTEGER
      WHEN 1 THEN 'CHAMPION'
      WHEN 2 THEN 'RUNNER_UP'
      WHEN 3 THEN 'SEMIFINAL_LOSS_TO_CHAMPION'
      WHEN 4 THEN 'SEMIFINAL_LOSS_TO_RUNNER_UP'
      WHEN 5 THEN 'QUARTERFINAL_LOSS_TO_CHAMPION'
      WHEN 6 THEN 'QUARTERFINAL_LOSS_TO_RUNNER_UP'
      WHEN 7 THEN 'QUARTERFINAL_LOSS_TO_THIRD'
      WHEN 8 THEN 'QUARTERFINAL_LOSS_TO_FOURTH'
      ELSE 'KNOCKOUT'
    END AS placement_reason
  FROM jsonb_each_text(resolved_positions) AS placements(key, value)
  WHERE placements.value IS NOT NULL
  ORDER BY placements.value::INTEGER;
END;
$function$;

-- Supabase source RPC: get_championship_yellow_card_discipline_raw
CREATE OR REPLACE FUNCTION public.get_championship_yellow_card_discipline_raw(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH resolved_season AS (
    SELECT COALESCE(_season_year, championships_table.current_season_year) AS season_year
    FROM public.championships AS championships_table
    WHERE championships_table.id = _championship_id
    LIMIT 1
  ),
  reset_settings AS (
    SELECT COALESCE(settings_table.yellow_card_reset_phase, 'NONE') AS reset_phase
    FROM resolved_season
    LEFT JOIN public.championship_season_settings AS settings_table
      ON settings_table.championship_id = _championship_id
      AND settings_table.season_year = resolved_season.season_year
  ),
  competition_phases AS (
    SELECT matches_table.sport_id, matches_table.naipe, matches_table.division,
      bool_or(bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) - 2) AS has_quarterfinal,
      bool_or(bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) - 1) AS has_semifinal,
      bool_or(bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id)) AS has_final
    FROM public.matches AS matches_table
    JOIN public.championship_bracket_matches AS bracket_matches_table ON bracket_matches_table.match_id = matches_table.id
    JOIN resolved_season ON resolved_season.season_year = matches_table.season_year
    WHERE matches_table.championship_id = _championship_id
    GROUP BY matches_table.sport_id, matches_table.naipe, matches_table.division
  ),
  effective_resets AS (
    SELECT competition_phases.*, CASE reset_settings.reset_phase
      WHEN 'QUARTERFINAL' THEN CASE WHEN has_quarterfinal THEN 'QUARTERFINAL' WHEN has_semifinal THEN 'SEMIFINAL' WHEN has_final THEN 'FINAL' ELSE 'NONE' END
      WHEN 'SEMIFINAL' THEN CASE WHEN has_semifinal THEN 'SEMIFINAL' WHEN has_final THEN 'FINAL' ELSE 'NONE' END
      ELSE 'NONE'
    END AS effective_reset_phase
    FROM competition_phases
    CROSS JOIN reset_settings
  ),
  match_base AS (
    SELECT matches_table.id AS match_id, matches_table.championship_id, matches_table.season_year, matches_table.sport_id, matches_table.naipe, matches_table.division, matches_table.home_team_id, matches_table.away_team_id, matches_table.status, matches_table.scheduled_date, matches_table.start_time, matches_table.queue_position,
      CASE
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase AND bracket_matches_table.is_third_place THEN 'THIRD_PLACE'
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) THEN 'FINAL'
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) - 1 THEN 'SEMIFINAL'
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) - 2 THEN 'QUARTERFINAL'
        ELSE 'GROUP_STAGE'
      END AS phase,
      COALESCE(effective_resets.effective_reset_phase, 'NONE') AS effective_reset_phase
    FROM public.matches AS matches_table
    JOIN resolved_season ON resolved_season.season_year = matches_table.season_year
    LEFT JOIN public.championship_bracket_matches AS bracket_matches_table ON bracket_matches_table.match_id = matches_table.id
    LEFT JOIN effective_resets ON effective_resets.sport_id = matches_table.sport_id AND effective_resets.naipe = matches_table.naipe AND effective_resets.division IS NOT DISTINCT FROM matches_table.division
    WHERE matches_table.championship_id = _championship_id
  ),
  team_match_sequence AS (
    SELECT match_base.*, match_base.home_team_id AS team_id,
      row_number() OVER (PARTITION BY match_base.sport_id, match_base.naipe, match_base.division, match_base.home_team_id ORDER BY match_base.scheduled_date NULLS LAST, match_base.start_time NULLS LAST, match_base.queue_position NULLS LAST, match_base.match_id) AS match_sequence
    FROM match_base
    UNION ALL
    SELECT match_base.*, match_base.away_team_id AS team_id,
      row_number() OVER (PARTITION BY match_base.sport_id, match_base.naipe, match_base.division, match_base.away_team_id ORDER BY match_base.scheduled_date NULLS LAST, match_base.start_time NULLS LAST, match_base.queue_position NULLS LAST, match_base.match_id) AS match_sequence
    FROM match_base
  ),
  yellow_events AS (
    SELECT yellow_cards_table.player_id, yellow_cards_table.card_order, team_match_sequence.*, award_players_table.name AS player_name, teams_table.name AS team_name, sports_table.name AS sport_name,
      CASE WHEN team_match_sequence.effective_reset_phase = 'NONE' THEN 0 WHEN team_match_sequence.effective_reset_phase = 'QUARTERFINAL' AND team_match_sequence.phase IN ('QUARTERFINAL', 'SEMIFINAL', 'FINAL', 'THIRD_PLACE') THEN 1 WHEN team_match_sequence.effective_reset_phase = 'SEMIFINAL' AND team_match_sequence.phase IN ('SEMIFINAL', 'FINAL', 'THIRD_PLACE') THEN 1 WHEN team_match_sequence.effective_reset_phase = 'FINAL' AND team_match_sequence.phase IN ('FINAL', 'THIRD_PLACE') THEN 1 ELSE 0 END AS yellow_period
    FROM public.match_yellow_card_players AS yellow_cards_table
    JOIN team_match_sequence ON team_match_sequence.match_id = yellow_cards_table.match_id AND team_match_sequence.team_id = yellow_cards_table.team_id
    JOIN public.championship_award_players AS award_players_table ON award_players_table.id = yellow_cards_table.player_id
    JOIN public.teams AS teams_table ON teams_table.id = yellow_cards_table.team_id
    JOIN public.sports AS sports_table ON sports_table.id = team_match_sequence.sport_id
    WHERE team_match_sequence.status = 'FINISHED'::public.match_status
  ),
  ordered_yellow_events AS (
    SELECT yellow_events.*, row_number() OVER (PARTITION BY player_id, team_id, sport_id, naipe, division, yellow_period ORDER BY match_sequence, card_order) AS yellow_sequence
    FROM yellow_events
  ),
  yellow_pair_events AS (
    SELECT ordered_yellow_events.*, ((yellow_sequence + 1) / 2)::integer AS yellow_pair_number
    FROM ordered_yellow_events
    WHERE yellow_sequence % 2 = 0
  ),
  direct_red_events AS (
    SELECT red_cards_table.player_id, red_cards_table.team_id, team_match_sequence.match_id, team_match_sequence.sport_id, team_match_sequence.naipe, team_match_sequence.division, team_match_sequence.match_sequence,
      1 AS red_cards_direct, 0 AS red_cards_derived
    FROM public.match_red_card_players AS red_cards_table
    JOIN team_match_sequence ON team_match_sequence.match_id = red_cards_table.match_id AND team_match_sequence.team_id = red_cards_table.team_id
    WHERE team_match_sequence.status = 'FINISHED'::public.match_status
  ),
  derived_red_events AS (
    SELECT yellow_pair_events.player_id, yellow_pair_events.team_id, yellow_pair_events.match_id, yellow_pair_events.sport_id, yellow_pair_events.naipe, yellow_pair_events.division, yellow_pair_events.match_sequence,
      0 AS red_cards_direct, 1 AS red_cards_derived
    FROM yellow_pair_events
  ),
  suspension_events AS (
    SELECT player_id, team_id, match_id, sport_id, naipe, division, match_sequence, sum(red_cards_direct)::integer AS red_cards_direct, sum(red_cards_derived)::integer AS red_cards_derived
    FROM (
      SELECT * FROM direct_red_events
      UNION ALL
      SELECT * FROM derived_red_events
    ) AS events
    GROUP BY player_id, team_id, match_id, sport_id, naipe, division, match_sequence
  ),
  suspension_event_status AS (
    SELECT suspension_events.*, next_match.match_id AS next_match_id, next_match.scheduled_date AS next_match_scheduled_date, next_match.start_time AS next_match_start_time, next_match.status AS next_match_status, next_match.opponent_name,
      COALESCE(next_match.status = 'FINISHED'::public.match_status, false) AS is_served
    FROM suspension_events
    LEFT JOIN LATERAL (
      SELECT following_matches.match_id, following_matches.scheduled_date, following_matches.start_time, following_matches.status,
        CASE WHEN following_matches.home_team_id = suspension_events.team_id THEN away_teams_table.name ELSE home_teams_table.name END AS opponent_name
      FROM team_match_sequence AS following_matches
      LEFT JOIN public.teams AS home_teams_table ON home_teams_table.id = following_matches.home_team_id
      LEFT JOIN public.teams AS away_teams_table ON away_teams_table.id = following_matches.away_team_id
      WHERE following_matches.team_id = suspension_events.team_id
        AND following_matches.sport_id = suspension_events.sport_id
        AND following_matches.naipe = suspension_events.naipe
        AND following_matches.division IS NOT DISTINCT FROM suspension_events.division
        AND following_matches.match_sequence > suspension_events.match_sequence
      ORDER BY following_matches.match_sequence
      LIMIT 1
    ) AS next_match ON true
  ),
  yellow_pair_status AS (
    SELECT yellow_pair_events.player_id, yellow_pair_events.team_id, yellow_pair_events.sport_id, yellow_pair_events.naipe, yellow_pair_events.division, yellow_pair_events.yellow_period, yellow_pair_events.yellow_pair_number,
      COALESCE(suspension_event_status.is_served, false) AS is_served
    FROM yellow_pair_events
    LEFT JOIN suspension_event_status ON suspension_event_status.player_id = yellow_pair_events.player_id
      AND suspension_event_status.team_id = yellow_pair_events.team_id
      AND suspension_event_status.match_id = yellow_pair_events.match_id
      AND suspension_event_status.sport_id = yellow_pair_events.sport_id
      AND suspension_event_status.naipe = yellow_pair_events.naipe
      AND suspension_event_status.division IS NOT DISTINCT FROM yellow_pair_events.division
  ),
  yellow_active_counts AS (
    SELECT ordered_yellow_events.player_id, ordered_yellow_events.team_id, ordered_yellow_events.sport_id, ordered_yellow_events.naipe, ordered_yellow_events.division,
      sum(CASE WHEN ordered_yellow_events.yellow_sequence % 2 = 1 AND NOT EXISTS (SELECT 1 FROM ordered_yellow_events AS next_yellow_event WHERE next_yellow_event.player_id = ordered_yellow_events.player_id AND next_yellow_event.team_id = ordered_yellow_events.team_id AND next_yellow_event.sport_id = ordered_yellow_events.sport_id AND next_yellow_event.naipe = ordered_yellow_events.naipe AND next_yellow_event.division IS NOT DISTINCT FROM ordered_yellow_events.division AND next_yellow_event.yellow_period = ordered_yellow_events.yellow_period AND next_yellow_event.yellow_sequence = ordered_yellow_events.yellow_sequence + 1) THEN 1 WHEN ordered_yellow_events.yellow_sequence % 2 = 0 AND NOT COALESCE((SELECT yellow_pair_status.is_served FROM yellow_pair_status WHERE yellow_pair_status.player_id = ordered_yellow_events.player_id AND yellow_pair_status.team_id = ordered_yellow_events.team_id AND yellow_pair_status.sport_id = ordered_yellow_events.sport_id AND yellow_pair_status.naipe = ordered_yellow_events.naipe AND yellow_pair_status.division IS NOT DISTINCT FROM ordered_yellow_events.division AND yellow_pair_status.yellow_period = ordered_yellow_events.yellow_period AND yellow_pair_status.yellow_pair_number = ((ordered_yellow_events.yellow_sequence + 1) / 2)::integer), false) THEN 2 ELSE 0 END)::integer AS yellow_cards_active
    FROM ordered_yellow_events
    WHERE ordered_yellow_events.yellow_period = CASE WHEN ordered_yellow_events.effective_reset_phase = 'NONE' THEN 0 ELSE 1 END
    GROUP BY ordered_yellow_events.player_id, ordered_yellow_events.team_id, ordered_yellow_events.sport_id, ordered_yellow_events.naipe, ordered_yellow_events.division
  ),
  athlete_contexts AS (
    SELECT player_id, team_id, sport_id, naipe, division, max(player_name) AS player_name, max(team_name) AS team_name, max(sport_name) AS sport_name, max(effective_reset_phase) AS effective_reset_phase,
      count(*)::integer AS yellow_cards_total, 0::integer AS red_cards_direct_total
    FROM yellow_events
    GROUP BY player_id, team_id, sport_id, naipe, division
    UNION ALL
    SELECT red_cards_table.player_id, red_cards_table.team_id, team_match_sequence.sport_id, team_match_sequence.naipe, team_match_sequence.division, max(award_players_table.name) AS player_name, max(teams_table.name) AS team_name, max(sports_table.name) AS sport_name, max(team_match_sequence.effective_reset_phase) AS effective_reset_phase,
      0::integer AS yellow_cards_total, count(*)::integer AS red_cards_direct_total
    FROM public.match_red_card_players AS red_cards_table
    JOIN team_match_sequence ON team_match_sequence.match_id = red_cards_table.match_id AND team_match_sequence.team_id = red_cards_table.team_id
    JOIN public.championship_award_players AS award_players_table ON award_players_table.id = red_cards_table.player_id
    JOIN public.teams AS teams_table ON teams_table.id = red_cards_table.team_id
    JOIN public.sports AS sports_table ON sports_table.id = team_match_sequence.sport_id
    WHERE team_match_sequence.status = 'FINISHED'::public.match_status
    GROUP BY red_cards_table.player_id, red_cards_table.team_id, team_match_sequence.sport_id, team_match_sequence.naipe, team_match_sequence.division
  ),
  athletes AS (
    SELECT athlete_contexts.player_id, athlete_contexts.team_id, athlete_contexts.sport_id, athlete_contexts.naipe, athlete_contexts.division, max(athlete_contexts.player_name) AS player_name, max(athlete_contexts.team_name) AS team_name, max(athlete_contexts.sport_name) AS sport_name, max(athlete_contexts.effective_reset_phase) AS effective_reset_phase,
      sum(athlete_contexts.yellow_cards_total)::integer AS yellow_cards_total, sum(athlete_contexts.red_cards_direct_total)::integer AS red_cards_direct_total
    FROM athlete_contexts
    GROUP BY athlete_contexts.player_id, athlete_contexts.team_id, athlete_contexts.sport_id, athlete_contexts.naipe, athlete_contexts.division
  ),
  card_history_events AS (
    SELECT player_id, team_id, match_id, sport_id, naipe, division, 1::integer AS yellow_cards, 0::integer AS red_cards_direct, 0::integer AS red_cards_derived
    FROM yellow_events
    UNION ALL
    SELECT player_id, team_id, match_id, sport_id, naipe, division, 0::integer, 1::integer, 0::integer
    FROM direct_red_events
    UNION ALL
    SELECT player_id, team_id, match_id, sport_id, naipe, division, 0::integer, 0::integer, 1::integer
    FROM derived_red_events
  ),
  card_history AS (
    SELECT card_history_events.player_id, card_history_events.team_id, card_history_events.sport_id, card_history_events.naipe, card_history_events.division, card_history_events.match_id, max(team_match_sequence.scheduled_date) AS scheduled_date, max(team_match_sequence.start_time) AS start_time, max(team_match_sequence.phase) AS phase,
      sum(card_history_events.yellow_cards)::integer AS yellow_cards, sum(card_history_events.red_cards_direct)::integer AS red_cards_direct, sum(card_history_events.red_cards_derived)::integer AS red_cards_derived
    FROM card_history_events
    JOIN team_match_sequence ON team_match_sequence.match_id = card_history_events.match_id AND team_match_sequence.team_id = card_history_events.team_id
    GROUP BY card_history_events.player_id, card_history_events.team_id, card_history_events.sport_id, card_history_events.naipe, card_history_events.division, card_history_events.match_id
  )
  SELECT jsonb_build_object(
    'season_year', (SELECT season_year FROM resolved_season),
    'athletes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'player_id', athletes.player_id,
        'player_name', athletes.player_name,
        'team_id', athletes.team_id,
        'team_name', athletes.team_name,
        'sport_id', athletes.sport_id,
        'sport_name', athletes.sport_name,
        'naipe', athletes.naipe,
        'division', athletes.division,
        'yellow_cards_total', athletes.yellow_cards_total,
        'yellow_cards_active', COALESCE(yellow_active_counts.yellow_cards_active, 0),
        'red_cards_direct_total', athletes.red_cards_direct_total,
        'red_cards_derived_total', COALESCE((SELECT sum(suspension_events.red_cards_derived)::integer FROM suspension_events WHERE suspension_events.player_id = athletes.player_id AND suspension_events.team_id = athletes.team_id AND suspension_events.sport_id = athletes.sport_id AND suspension_events.naipe = athletes.naipe AND suspension_events.division IS NOT DISTINCT FROM athletes.division), 0),
        'is_suspended', EXISTS (SELECT 1 FROM suspension_event_status WHERE suspension_event_status.player_id = athletes.player_id AND suspension_event_status.team_id = athletes.team_id AND suspension_event_status.sport_id = athletes.sport_id AND suspension_event_status.naipe = athletes.naipe AND suspension_event_status.division IS NOT DISTINCT FROM athletes.division AND NOT suspension_event_status.is_served),
        'suspension_causes', COALESCE((SELECT jsonb_agg(jsonb_build_object('match_id', suspension_event_status.match_id, 'direct_red', suspension_event_status.red_cards_direct > 0, 'yellow_accumulation', suspension_event_status.red_cards_derived > 0) ORDER BY suspension_event_status.match_sequence) FROM suspension_event_status WHERE suspension_event_status.player_id = athletes.player_id AND suspension_event_status.team_id = athletes.team_id AND suspension_event_status.sport_id = athletes.sport_id AND suspension_event_status.naipe = athletes.naipe AND suspension_event_status.division IS NOT DISTINCT FROM athletes.division AND NOT suspension_event_status.is_served), '[]'::jsonb),
        'effective_reset_phase', athletes.effective_reset_phase,
        'next_match', COALESCE((SELECT jsonb_build_object('match_id', suspension_event_status.next_match_id, 'scheduled_date', suspension_event_status.next_match_scheduled_date, 'start_time', suspension_event_status.next_match_start_time, 'opponent_name', suspension_event_status.opponent_name) FROM suspension_event_status WHERE suspension_event_status.player_id = athletes.player_id AND suspension_event_status.team_id = athletes.team_id AND suspension_event_status.sport_id = athletes.sport_id AND suspension_event_status.naipe = athletes.naipe AND suspension_event_status.division IS NOT DISTINCT FROM athletes.division AND NOT suspension_event_status.is_served ORDER BY suspension_event_status.match_sequence LIMIT 1), 'null'::jsonb),
        'matches', COALESCE((SELECT jsonb_agg(jsonb_build_object('match_id', card_history.match_id, 'scheduled_date', card_history.scheduled_date, 'start_time', card_history.start_time, 'phase', card_history.phase, 'yellow_cards', card_history.yellow_cards, 'red_cards_direct', card_history.red_cards_direct, 'red_cards_derived', card_history.red_cards_derived) ORDER BY card_history.scheduled_date NULLS LAST, card_history.start_time NULLS LAST, card_history.match_id) FROM card_history WHERE card_history.player_id = athletes.player_id AND card_history.team_id = athletes.team_id AND card_history.sport_id = athletes.sport_id AND card_history.naipe = athletes.naipe AND card_history.division IS NOT DISTINCT FROM athletes.division), '[]'::jsonb)
      ) ORDER BY EXISTS (SELECT 1 FROM suspension_event_status WHERE suspension_event_status.player_id = athletes.player_id AND suspension_event_status.team_id = athletes.team_id AND suspension_event_status.sport_id = athletes.sport_id AND suspension_event_status.naipe = athletes.naipe AND suspension_event_status.division IS NOT DISTINCT FROM athletes.division AND NOT suspension_event_status.is_served) DESC, athletes.red_cards_direct_total DESC, athletes.yellow_cards_total DESC, athletes.player_name, athletes.team_name)
      FROM athletes
      LEFT JOIN yellow_active_counts ON yellow_active_counts.player_id = athletes.player_id AND yellow_active_counts.team_id = athletes.team_id AND yellow_active_counts.sport_id = athletes.sport_id AND yellow_active_counts.naipe = athletes.naipe AND yellow_active_counts.division IS NOT DISTINCT FROM athletes.division
    ), '[]'::jsonb)
  );
$function$;

-- Supabase source RPC: get_championship_effective_standings
CREATE OR REPLACE FUNCTION public.get_championship_effective_standings(_championship_id uuid DEFAULT NULL::uuid, _season_year integer DEFAULT NULL::integer, _division_filter text DEFAULT NULL::text, _naipe match_naipe DEFAULT NULL::match_naipe, _sport_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, championship_id uuid, season_year integer, division team_division, naipe match_naipe, sport_id uuid, team_id uuid, played integer, wins integer, draws integer, losses integer, goals_for integer, goals_against integer, goal_diff integer, points numeric, yellow_cards integer, red_cards integer, blue_cards integer, two_minute_penalties integer, updated_at timestamp with time zone, is_individual_sport boolean, scored_events_count integer, first_places integer, second_places integer, third_places integer, fourth_places integer, fifth_places integer, sixth_places integer, seventh_places integer, eighth_places integer, ninth_places integer, tenth_places integer, eleventh_places integer, twelfth_places integer, thirteenth_places integer, fourteenth_places integer, fifteenth_places integer, sixteenth_places integer, seventeenth_places integer, eighteenth_places integer, nineteenth_places integer, twentieth_places integer, relay_points_total numeric, team_name text, team_city text, sport_name text)
 LANGUAGE sql
 STABLE
AS $function$
  WITH base_standings AS (
    SELECT *
    FROM public.get_championship_effective_standings_base(
      _championship_id,
      _season_year,
      _division_filter,
      _naipe,
      _sport_id
    )
  ), individual_disqualifications AS (
    SELECT disqualifications_table.*
    FROM public.championship_competition_team_disqualifications AS disqualifications_table
    WHERE (_championship_id IS NULL OR disqualifications_table.championship_id = _championship_id)
      AND (_season_year IS NULL OR disqualifications_table.season_year = _season_year)
      AND (_sport_id IS NULL OR disqualifications_table.sport_id = _sport_id)
      AND (_naipe IS NULL OR disqualifications_table.naipe = _naipe)
      AND (
        _division_filter IS NULL
        OR (_division_filter = 'WITHOUT_DIVISION' AND disqualifications_table.division IS NULL)
        OR (_division_filter <> 'WITHOUT_DIVISION' AND disqualifications_table.division::text = _division_filter)
      )
      AND EXISTS (
        SELECT 1
        FROM public.championship_individual_sessions AS sessions_table
        WHERE sessions_table.championship_id = disqualifications_table.championship_id
          AND sessions_table.season_year = disqualifications_table.season_year
          AND sessions_table.sport_id = disqualifications_table.sport_id
          AND sessions_table.naipe = disqualifications_table.naipe
          AND sessions_table.division IS NOT DISTINCT FROM disqualifications_table.division
      )
  )
  SELECT * FROM base_standings

  UNION ALL

  SELECT
    individual_disqualifications.id,
    individual_disqualifications.championship_id,
    individual_disqualifications.season_year,
    individual_disqualifications.division,
    individual_disqualifications.naipe,
    individual_disqualifications.sport_id,
    individual_disqualifications.team_id,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0::numeric,
    0,
    0,
    0,
    0,
    individual_disqualifications.created_at,
    true,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0::numeric,
    teams_table.name,
    teams_table.city,
    sports_table.name
  FROM individual_disqualifications
  JOIN public.teams AS teams_table
    ON teams_table.id = individual_disqualifications.team_id
  JOIN public.sports AS sports_table
    ON sports_table.id = individual_disqualifications.sport_id
  WHERE NOT EXISTS (
    SELECT 1
    FROM base_standings
    WHERE base_standings.championship_id = individual_disqualifications.championship_id
      AND base_standings.season_year = individual_disqualifications.season_year
      AND base_standings.sport_id = individual_disqualifications.sport_id
      AND base_standings.naipe = individual_disqualifications.naipe
      AND base_standings.division IS NOT DISTINCT FROM individual_disqualifications.division
      AND base_standings.team_id = individual_disqualifications.team_id
  );
$function$;

-- Supabase source RPC: get_championship_award_pending_draws
CREATE OR REPLACE FUNCTION public.get_championship_award_pending_draws(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '2s'
AS $function$
DECLARE
  resolved_season_year INTEGER;
  v_result             JSONB := '[]'::JSONB;
  v_sport              RECORD;
  v_group              RECORD;
  v_pending_count      INTEGER;
  v_tied_participants  JSONB;
  v_signature          TEXT;
  v_existing_draw_id   UUID;
  v_naipe_label        TEXT;
  v_division_suffix    TEXT;
BEGIN
  SELECT COALESCE(_season_year, c.current_season_year)
  INTO resolved_season_year
  FROM public.championships c
  WHERE c.id = _championship_id
  LIMIT 1;

  IF resolved_season_year IS NULL THEN
    RETURN '[]'::JSONB;
  END IF;

  FOR v_sport IN
    SELECT cs.sport_id, cs.awards_include_knockout_phase, s.name AS sport_name
    FROM public.championship_sports cs
    JOIN public.sports s ON s.id = cs.sport_id
    WHERE cs.championship_id = _championship_id
      AND cs.supports_individual_awards = true
    ORDER BY s.name
  LOOP
    FOR v_group IN
      SELECT DISTINCT m.naipe, m.division
      FROM public.matches m
      JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
      WHERE m.championship_id = _championship_id
        AND m.sport_id = v_sport.sport_id
        AND m.season_year = resolved_season_year
        AND m.status = 'FINISHED'::public.match_status
        AND COALESCE(m.is_walkover, false) = false
        AND (
          bm.phase = 'GROUP_STAGE'::public.bracket_phase
          OR (v_sport.awards_include_knockout_phase = true AND bm.phase = 'KNOCKOUT'::public.bracket_phase)
        )
      ORDER BY m.naipe, m.division
    LOOP
      SELECT COUNT(*)::int INTO v_pending_count
      FROM public.matches m
      JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
      WHERE m.championship_id = _championship_id
        AND m.sport_id = v_sport.sport_id
        AND m.season_year = resolved_season_year
        AND m.naipe = v_group.naipe
        AND m.division IS NOT DISTINCT FROM v_group.division
        AND COALESCE(m.is_walkover, false) = false
        AND (
          m.status <> 'FINISHED'::public.match_status
          OR COALESCE(m.is_score_sheet_reviewed, false) = false
        )
        AND (
          bm.phase = 'GROUP_STAGE'::public.bracket_phase
          OR (v_sport.awards_include_knockout_phase = true AND bm.phase = 'KNOCKOUT'::public.bracket_phase)
        );

      CONTINUE WHEN v_pending_count > 0;

      v_naipe_label := CASE v_group.naipe
        WHEN 'MASCULINO' THEN 'Masculino'
        WHEN 'FEMININO'  THEN 'Feminino'
        ELSE v_group.naipe::text
      END;
      v_division_suffix := CASE
        WHEN v_group.division IS NULL THEN ''
        WHEN v_group.division::text = 'PRINCIPAL' THEN ' • Divisão Principal'
        WHEN v_group.division::text = 'ACESSO'    THEN ' • Divisão de Acesso'
        ELSE ' • ' || v_group.division::text
      END;

      v_tied_participants := NULL;
      v_signature := NULL;

      WITH knockout_eligible_teams AS (
        SELECT DISTINCT
          knockout_rows.team_id,
          knockout_rows.naipe,
          knockout_rows.division
        FROM (
          SELECT
            m.home_team_id AS team_id,
            m.naipe,
            m.division
          FROM public.matches m
          JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
          WHERE m.championship_id = _championship_id
            AND m.sport_id = v_sport.sport_id
            AND m.season_year = resolved_season_year
            AND m.naipe = v_group.naipe
            AND m.division IS NOT DISTINCT FROM v_group.division
            AND m.status = 'FINISHED'::public.match_status
            AND COALESCE(m.is_walkover, false) = false
            AND bm.phase = 'KNOCKOUT'::public.bracket_phase
            AND m.home_team_id IS NOT NULL

          UNION ALL

          SELECT
            m.away_team_id AS team_id,
            m.naipe,
            m.division
          FROM public.matches m
          JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
          WHERE m.championship_id = _championship_id
            AND m.sport_id = v_sport.sport_id
            AND m.season_year = resolved_season_year
            AND m.naipe = v_group.naipe
            AND m.division IS NOT DISTINCT FROM v_group.division
            AND m.status = 'FINISHED'::public.match_status
            AND COALESCE(m.is_walkover, false) = false
            AND bm.phase = 'KNOCKOUT'::public.bracket_phase
            AND m.away_team_id IS NOT NULL
        ) AS knockout_rows
      ),
      scorer_team_advancement_rows AS (
        SELECT
          knockout_team_rows.team_id,
          knockout_team_rows.naipe,
          knockout_team_rows.division,
          MAX(knockout_team_rows.round_number)::int AS team_advancement_rank
        FROM (
          SELECT
            matches_table.home_team_id AS team_id,
            matches_table.naipe,
            matches_table.division,
            bracket_matches_table.round_number
          FROM public.championship_bracket_matches AS bracket_matches_table
          JOIN public.matches AS matches_table
            ON matches_table.id = bracket_matches_table.match_id
          JOIN public.championship_bracket_competitions AS competitions_table
            ON competitions_table.id = bracket_matches_table.competition_id
          JOIN public.championship_bracket_editions AS editions_table
            ON editions_table.id = competitions_table.bracket_edition_id
          WHERE editions_table.championship_id = _championship_id
            AND editions_table.season_year = resolved_season_year
            AND matches_table.sport_id = v_sport.sport_id
            AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
            AND matches_table.home_team_id IS NOT NULL

          UNION ALL

          SELECT
            matches_table.away_team_id AS team_id,
            matches_table.naipe,
            matches_table.division,
            bracket_matches_table.round_number
          FROM public.championship_bracket_matches AS bracket_matches_table
          JOIN public.matches AS matches_table
            ON matches_table.id = bracket_matches_table.match_id
          JOIN public.championship_bracket_competitions AS competitions_table
            ON competitions_table.id = bracket_matches_table.competition_id
          JOIN public.championship_bracket_editions AS editions_table
            ON editions_table.id = competitions_table.bracket_edition_id
          WHERE editions_table.championship_id = _championship_id
            AND editions_table.season_year = resolved_season_year
            AND matches_table.sport_id = v_sport.sport_id
            AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
            AND matches_table.away_team_id IS NOT NULL
        ) AS knockout_team_rows
        GROUP BY knockout_team_rows.team_id, knockout_team_rows.naipe, knockout_team_rows.division
      ),
      scorer_rows AS (
        SELECT
          cap.id AS player_id,
          cap.name AS player_name,
          cap.team_id AS team_id,
          t.name AS team_name,
          COUNT(*)::int AS goals,
          COALESCE(MAX(scorer_team_advancement_rows.team_advancement_rank), 0)::int AS team_advancement_rank
        FROM public.match_award_goal_scorers mags
        JOIN public.championship_award_players cap ON cap.id = mags.player_id
        JOIN public.matches m ON m.id = mags.match_id
        JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
        JOIN public.teams t ON t.id = cap.team_id
        LEFT JOIN scorer_team_advancement_rows
          ON scorer_team_advancement_rows.team_id = cap.team_id
          AND scorer_team_advancement_rows.naipe = cap.naipe
          AND scorer_team_advancement_rows.division IS NOT DISTINCT FROM cap.division
        WHERE cap.championship_id = _championship_id
          AND cap.sport_id = v_sport.sport_id
          AND cap.naipe = v_group.naipe
          AND cap.division IS NOT DISTINCT FROM v_group.division
          AND cap.season_year = resolved_season_year
          AND m.status = 'FINISHED'::public.match_status
          AND COALESCE(m.is_walkover, false) = false
          AND (
            bm.phase = 'GROUP_STAGE'::public.bracket_phase
            OR (v_sport.awards_include_knockout_phase = true AND bm.phase = 'KNOCKOUT'::public.bracket_phase)
          )
          AND (
            v_sport.awards_include_knockout_phase = false
            OR EXISTS (
              SELECT 1
              FROM knockout_eligible_teams ket
              WHERE ket.team_id = cap.team_id
                AND ket.naipe = cap.naipe
                AND ket.division IS NOT DISTINCT FROM cap.division
            )
          )
        GROUP BY cap.id, cap.name, cap.team_id, t.name
      )
      SELECT
        jsonb_agg(
          jsonb_build_object(
            'participant_id', sub.player_id,
            'participant_name', sub.player_name,
            'team_name', sub.team_name,
            'metric_value', sub.goals
          ) ORDER BY sub.player_name ASC
        ),
        string_agg(sub.player_id::text, ':' ORDER BY sub.player_id)
      INTO v_tied_participants, v_signature
      FROM (
        SELECT
          scorer_rows.*,
          RANK() OVER (
            ORDER BY
              scorer_rows.goals DESC,
              scorer_rows.team_advancement_rank DESC
          ) AS rnk
        FROM scorer_rows
      ) sub
      WHERE sub.rnk = 1;

      IF v_tied_participants IS NOT NULL AND jsonb_array_length(v_tied_participants) >= 2 THEN
        SELECT id INTO v_existing_draw_id
        FROM public.championship_award_draw_results
        WHERE championship_id = _championship_id
          AND season_year = resolved_season_year
          AND sport_id = v_sport.sport_id
          AND naipe = v_group.naipe
          AND division IS NOT DISTINCT FROM v_group.division
          AND award_type = 'TOP_SCORER'::public.championship_award_type
          AND tied_player_ids_signature = v_signature
        LIMIT 1;

        IF v_existing_draw_id IS NULL THEN
          v_result := v_result || jsonb_build_array(jsonb_build_object(
            'context_key',               'AWARD_SCORER:' || _championship_id::text || ':' || resolved_season_year::text || ':' || v_sport.sport_id::text || ':' || v_group.naipe::text || ':' || COALESCE(v_group.division::text, 'NULL'),
            'sport_id',                  v_sport.sport_id,
            'sport_name',                v_sport.sport_name,
            'naipe',                     v_group.naipe,
            'division',                  v_group.division,
            'award_type',                'TOP_SCORER',
            'tied_participants',         v_tied_participants,
            'tied_player_ids_signature', v_signature,
            'title',                     'Empate no artilheiro — ' || v_naipe_label || v_division_suffix,
            'description',               jsonb_array_length(v_tied_participants)::text || ' jogadores empatados no 1º lugar após aplicar o critério de avanço de fase. Realize o sorteio para definir o vencedor do prêmio de artilheiro.'
          ));
        END IF;
      END IF;

      v_tied_participants := NULL;
      v_signature := NULL;

      WITH knockout_eligible_teams AS (
        SELECT DISTINCT
          knockout_rows.team_id,
          knockout_rows.naipe,
          knockout_rows.division
        FROM (
          SELECT
            m.home_team_id AS team_id,
            m.naipe,
            m.division
          FROM public.matches m
          JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
          WHERE m.championship_id = _championship_id
            AND m.sport_id = v_sport.sport_id
            AND m.season_year = resolved_season_year
            AND m.naipe = v_group.naipe
            AND m.division IS NOT DISTINCT FROM v_group.division
            AND m.status = 'FINISHED'::public.match_status
            AND COALESCE(m.is_walkover, false) = false
            AND bm.phase = 'KNOCKOUT'::public.bracket_phase
            AND m.home_team_id IS NOT NULL

          UNION ALL

          SELECT
            m.away_team_id AS team_id,
            m.naipe,
            m.division
          FROM public.matches m
          JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
          WHERE m.championship_id = _championship_id
            AND m.sport_id = v_sport.sport_id
            AND m.season_year = resolved_season_year
            AND m.naipe = v_group.naipe
            AND m.division IS NOT DISTINCT FROM v_group.division
            AND m.status = 'FINISHED'::public.match_status
            AND COALESCE(m.is_walkover, false) = false
            AND bm.phase = 'KNOCKOUT'::public.bracket_phase
            AND m.away_team_id IS NOT NULL
        ) AS knockout_rows
      )
      SELECT
        jsonb_agg(
          jsonb_build_object(
            'participant_id', sub.team_id,
            'participant_name', sub.team_name,
            'team_name', sub.team_name,
            'metric_value', sub.goals_against_average
          ) ORDER BY sub.team_name ASC
        ),
        string_agg(sub.team_id::text, ':' ORDER BY sub.team_id)
      INTO v_tied_participants, v_signature
      FROM (
        SELECT
          defense_rows.team_id,
          teams_table.name AS team_name,
          defense_rows.matches_count,
          defense_rows.goals_against,
          defense_rows.goals_against_average,
          RANK() OVER (
            ORDER BY
              defense_rows.goals_against_average ASC,
              defense_rows.goals_against ASC,
              defense_rows.matches_count DESC
          ) AS rnk
        FROM (
          SELECT
            team_matches.team_id,
            COUNT(*)::int AS matches_count,
            SUM(team_matches.goals_against)::int AS goals_against,
            (SUM(team_matches.goals_against)::numeric / COUNT(*)::numeric) AS goals_against_average
          FROM (
            SELECT
              m.home_team_id AS team_id,
              m.away_score::int AS goals_against
            FROM public.matches m
            JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
            WHERE m.championship_id = _championship_id
              AND m.sport_id = v_sport.sport_id
              AND m.season_year = resolved_season_year
              AND m.naipe = v_group.naipe
              AND m.division IS NOT DISTINCT FROM v_group.division
              AND m.status = 'FINISHED'::public.match_status
              AND COALESCE(m.is_walkover, false) = false
              AND (
                bm.phase = 'GROUP_STAGE'::public.bracket_phase
                OR (v_sport.awards_include_knockout_phase = true AND bm.phase = 'KNOCKOUT'::public.bracket_phase)
              )

            UNION ALL

            SELECT
              m.away_team_id AS team_id,
              m.home_score::int AS goals_against
            FROM public.matches m
            JOIN public.championship_bracket_matches bm ON bm.match_id = m.id
            WHERE m.championship_id = _championship_id
              AND m.sport_id = v_sport.sport_id
              AND m.season_year = resolved_season_year
              AND m.naipe = v_group.naipe
              AND m.division IS NOT DISTINCT FROM v_group.division
              AND m.status = 'FINISHED'::public.match_status
              AND COALESCE(m.is_walkover, false) = false
              AND (
                bm.phase = 'GROUP_STAGE'::public.bracket_phase
                OR (v_sport.awards_include_knockout_phase = true AND bm.phase = 'KNOCKOUT'::public.bracket_phase)
              )
          ) AS team_matches
          WHERE
            v_sport.awards_include_knockout_phase = false
            OR EXISTS (
              SELECT 1
              FROM knockout_eligible_teams ket
              WHERE ket.team_id = team_matches.team_id
                AND ket.naipe = v_group.naipe
                AND ket.division IS NOT DISTINCT FROM v_group.division
            )
          GROUP BY team_matches.team_id
        ) AS defense_rows
        JOIN public.teams AS teams_table ON teams_table.id = defense_rows.team_id
      ) sub
      WHERE sub.rnk = 1;

      IF v_tied_participants IS NOT NULL AND jsonb_array_length(v_tied_participants) >= 2 THEN
        SELECT id INTO v_existing_draw_id
        FROM public.championship_award_draw_results
        WHERE championship_id = _championship_id
          AND season_year = resolved_season_year
          AND sport_id = v_sport.sport_id
          AND naipe = v_group.naipe
          AND division IS NOT DISTINCT FROM v_group.division
          AND award_type = 'BEST_GOALKEEPER'::public.championship_award_type
          AND tied_player_ids_signature = v_signature
        LIMIT 1;

        IF v_existing_draw_id IS NULL THEN
          v_result := v_result || jsonb_build_array(jsonb_build_object(
            'context_key',               'AWARD_DEFENSE:' || _championship_id::text || ':' || resolved_season_year::text || ':' || v_sport.sport_id::text || ':' || v_group.naipe::text || ':' || COALESCE(v_group.division::text, 'NULL'),
            'sport_id',                  v_sport.sport_id,
            'sport_name',                v_sport.sport_name,
            'naipe',                     v_group.naipe,
            'division',                  v_group.division,
            'award_type',                'BEST_GOALKEEPER',
            'tied_participants',         v_tied_participants,
            'tied_player_ids_signature', v_signature,
            'title',                     'Empate na melhor defesa — ' || v_naipe_label || v_division_suffix,
            'description',               jsonb_array_length(v_tied_participants)::text || ' atléticas empatadas no 1º lugar. Realize o sorteio para definir a atlética vencedora do prêmio.'
          ));
        END IF;
      END IF;
    END LOOP;
  END LOOP;

  RETURN v_result;
END;
$function$;

-- Supabase source RPC: get_championship_bracket_pending_tie_breaks
CREATE OR REPLACE FUNCTION public.get_championship_bracket_pending_tie_breaks(_championship_id uuid, _bracket_edition_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '4s'
AS $function$
  WITH pending_contexts AS (
    SELECT contexts_table.*
    FROM public.get_championship_bracket_tie_break_contexts(
      _championship_id,
      NULL,
      _bracket_edition_id
    ) AS contexts_table
    WHERE contexts_table.is_resolved = false
      AND COALESCE(cardinality(contexts_table.team_ids), 0) >= 2
      -- Suprime QUALIFICATION_POOL quando o bracket KO já foi gerado
      AND NOT (
        contexts_table.context_type = 'QUALIFICATION_POOL'::public.championship_bracket_tie_break_context_type
        AND EXISTS (
          SELECT 1 FROM public.championship_bracket_matches AS ko_check
          WHERE ko_check.competition_id = contexts_table.competition_id
            AND ko_check.phase = 'KNOCKOUT'::public.bracket_phase
        )
      )
  ),
  competition_rules AS (
    SELECT
      competitions_table.id AS competition_id,
      COALESCE(
        championship_sports_table.tie_breaker_rule,
        'STANDARD'::public.championship_sport_tie_breaker_rule
      ) AS tie_breaker_rule
    FROM public.championship_bracket_competitions AS competitions_table
    JOIN (
      SELECT DISTINCT pending_contexts.competition_id
      FROM pending_contexts
    ) AS pending_competitions
      ON pending_competitions.competition_id = competitions_table.id
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = editions_table.championship_id
      AND championship_sports_table.sport_id = competitions_table.sport_id
  ),
  group_rankings AS (
    SELECT
      competition_scope.competition_id,
      ranking_rows.group_id,
      ranking_rows.team_id,
      ranking_rows.points::numeric AS points,
      ranking_rows.wins::numeric AS wins,
      ranking_rows.goal_diff::numeric AS goal_diff,
      ranking_rows.goals_for::numeric AS goals_for,
      CASE
        WHEN (ranking_rows.goals_for - ranking_rows.goal_diff) = 0 THEN
          CASE
            WHEN ranking_rows.goals_for = 0 THEN 0::numeric
            ELSE 1000000000::numeric
          END
        ELSE ranking_rows.goals_for::numeric / (ranking_rows.goals_for - ranking_rows.goal_diff)::numeric
      END AS points_average
    FROM (
      SELECT DISTINCT pending_contexts.competition_id
      FROM pending_contexts
      WHERE pending_contexts.context_type = 'GROUP'::public.championship_bracket_tie_break_context_type
    ) AS competition_scope
    CROSS JOIN LATERAL public.get_championship_bracket_competition_group_rankings(
      _championship_id,
      competition_scope.competition_id
    ) AS ranking_rows
  ),
  qualification_pool_rankings AS (
    SELECT
      competition_scope.competition_id,
      ranking_rows.qualification_rank,
      ranking_rows.team_id,
      (ranking_rows.points::numeric / 1000000::numeric) AS points,
      ranking_rows.wins::numeric AS wins,
      ranking_rows.goal_diff::numeric AS goal_diff,
      ranking_rows.goals_for::numeric AS goals_for
    FROM (
      SELECT DISTINCT pending_contexts.competition_id
      FROM pending_contexts
      WHERE pending_contexts.context_type = 'QUALIFICATION_POOL'::public.championship_bracket_tie_break_context_type
    ) AS competition_scope
    CROSS JOIN LATERAL public.get_championship_bracket_competition_qualification_pool_rankings(
      _championship_id,
      competition_scope.competition_id
    ) AS ranking_rows
  ),
  validated_pending_contexts AS (
    SELECT current_context.*
    FROM pending_contexts AS current_context
    JOIN competition_rules
      ON competition_rules.competition_id = current_context.competition_id
    WHERE (
      current_context.context_type = 'GROUP'::public.championship_bracket_tie_break_context_type
      AND EXISTS (
        SELECT 1
        FROM (
          SELECT
            count(DISTINCT group_rankings.team_id) AS tied_teams_count,
            min(group_rankings.points) AS min_points,
            max(group_rankings.points) AS max_points,
            min(group_rankings.wins) AS min_wins,
            max(group_rankings.wins) AS max_wins,
            min(group_rankings.goal_diff) AS min_goal_diff,
            max(group_rankings.goal_diff) AS max_goal_diff,
            min(group_rankings.goals_for) AS min_goals_for,
            max(group_rankings.goals_for) AS max_goals_for,
            min(group_rankings.points_average) AS min_points_average,
            max(group_rankings.points_average) AS max_points_average
          FROM group_rankings
          WHERE group_rankings.competition_id = current_context.competition_id
            AND group_rankings.group_id = current_context.group_id
            AND group_rankings.team_id = ANY(current_context.team_ids)
        ) AS grouped_metrics
        WHERE grouped_metrics.tied_teams_count = cardinality(current_context.team_ids)
          AND grouped_metrics.min_points = grouped_metrics.max_points
          AND grouped_metrics.min_goal_diff = grouped_metrics.max_goal_diff
          AND grouped_metrics.min_goals_for = grouped_metrics.max_goals_for
          AND (
            competition_rules.tie_breaker_rule <> 'POINTS_AVERAGE'::public.championship_sport_tie_breaker_rule
            OR grouped_metrics.min_points_average = grouped_metrics.max_points_average
          )
          AND (
            competition_rules.tie_breaker_rule NOT IN (
              'STANDARD'::public.championship_sport_tie_breaker_rule,
              'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
              'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule
            )
            OR grouped_metrics.min_wins = grouped_metrics.max_wins
          )
      )
    ) OR (
      current_context.context_type = 'QUALIFICATION_POOL'::public.championship_bracket_tie_break_context_type
      AND EXISTS (
        SELECT 1
        FROM (
          SELECT
            count(DISTINCT qualification_pool_rankings.team_id) AS tied_teams_count,
            min(qualification_pool_rankings.points) AS min_points,
            max(qualification_pool_rankings.points) AS max_points,
            min(qualification_pool_rankings.wins) AS min_wins,
            max(qualification_pool_rankings.wins) AS max_wins,
            min(qualification_pool_rankings.goal_diff) AS min_goal_diff,
            max(qualification_pool_rankings.goal_diff) AS max_goal_diff,
            min(qualification_pool_rankings.goals_for) AS min_goals_for,
            max(qualification_pool_rankings.goals_for) AS max_goals_for
          FROM qualification_pool_rankings
          WHERE qualification_pool_rankings.competition_id = current_context.competition_id
            AND qualification_pool_rankings.qualification_rank = current_context.qualification_rank
            AND qualification_pool_rankings.team_id = ANY(current_context.team_ids)
        ) AS qualification_metrics
        WHERE qualification_metrics.tied_teams_count = cardinality(current_context.team_ids)
          AND qualification_metrics.min_points = qualification_metrics.max_points
          AND qualification_metrics.min_goal_diff = qualification_metrics.max_goal_diff
          AND qualification_metrics.min_goals_for = qualification_metrics.max_goals_for
          AND (
            competition_rules.tie_breaker_rule NOT IN (
              'STANDARD'::public.championship_sport_tie_breaker_rule,
              'BEACH_SOCCER'::public.championship_sport_tie_breaker_rule,
              'BEACH_TENNIS'::public.championship_sport_tie_breaker_rule
            )
            OR qualification_metrics.min_wins = qualification_metrics.max_wins
          )
      )
    )
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'context_key', contexts_table.context_key,
        'competition_id', contexts_table.competition_id,
        'sport_name', contexts_table.sport_name,
        'naipe', contexts_table.naipe,
        'division', contexts_table.division,
        'context_type', contexts_table.context_type,
        'group_id', contexts_table.group_id,
        'group_number', contexts_table.group_number,
        'qualification_rank', contexts_table.qualification_rank,
        'title', contexts_table.title,
        'description', contexts_table.description,
        'teams',
        (
          SELECT COALESCE(
            jsonb_agg(
              jsonb_build_object(
                'team_id', team_rows.team_id,
                'team_name', team_rows.team_name
              )
              ORDER BY team_rows.team_name ASC
            ),
            '[]'::jsonb
          )
          FROM unnest(contexts_table.team_ids, contexts_table.team_names) AS team_rows(team_id, team_name)
        )
      )
      ORDER BY
        CASE contexts_table.context_type
          WHEN 'GROUP'::public.championship_bracket_tie_break_context_type THEN 1
          ELSE 2
        END,
        contexts_table.sport_name ASC,
        contexts_table.naipe ASC,
        contexts_table.group_number ASC NULLS FIRST,
        contexts_table.qualification_rank ASC NULLS FIRST
    ),
    '[]'::jsonb
  )
  FROM validated_pending_contexts AS contexts_table;
$function$;

-- Supabase source RPC: get_championship_bracket_resolved_tie_break_orders
CREATE OR REPLACE FUNCTION public.get_championship_bracket_resolved_tie_break_orders(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  resolved_season_year INTEGER;
BEGIN
  SELECT COALESCE(
    _season_year,
    championships_table.current_season_year,
    date_part('year', timezone('America/Sao_Paulo', now()))::integer
  )
  INTO resolved_season_year
  FROM public.championships AS championships_table
  WHERE championships_table.id = _championship_id
  LIMIT 1;

  IF resolved_season_year IS NULL THEN
    resolved_season_year := date_part('year', timezone('America/Sao_Paulo', now()))::integer;
  END IF;

  RETURN COALESCE(
    (
      WITH latest_edition AS (
        SELECT editions_table.id
        FROM public.championship_bracket_editions AS editions_table
        WHERE editions_table.championship_id = _championship_id
          AND editions_table.season_year = resolved_season_year
        ORDER BY editions_table.created_at DESC
        LIMIT 1
      )
      SELECT jsonb_agg(
        jsonb_build_object(
          'context_key', resolved_contexts.context_key,
          'competition_id', resolved_contexts.competition_id,
          'sport_id', resolved_contexts.sport_id,
          'sport_name', resolved_contexts.sport_name,
          'naipe', resolved_contexts.naipe,
          'division', resolved_contexts.division,
          'context_type', resolved_contexts.context_type,
          'group_id', resolved_contexts.group_id,
          'group_number', resolved_contexts.group_number,
          'qualification_rank', resolved_contexts.qualification_rank,
          'team_ids', resolved_contexts.team_ids
        )
        ORDER BY
          CASE resolved_contexts.context_type
            WHEN 'GROUP'::public.championship_bracket_tie_break_context_type THEN 1
            ELSE 2
          END,
          resolved_contexts.sport_name ASC,
          resolved_contexts.naipe ASC,
          resolved_contexts.group_number ASC NULLS FIRST,
          resolved_contexts.qualification_rank ASC NULLS FIRST,
          resolved_contexts.context_key ASC
      )
      FROM (
        SELECT
          resolutions_table.context_key,
          resolutions_table.competition_id,
          competitions_table.sport_id,
          sports_table.name AS sport_name,
          competitions_table.naipe,
          competitions_table.division,
          resolutions_table.context_type,
          resolutions_table.group_id,
          groups_table.group_number,
          resolutions_table.qualification_rank,
          array_agg(resolution_teams_table.team_id ORDER BY resolution_teams_table.draw_order ASC) AS team_ids
        FROM public.championship_bracket_tie_break_resolutions AS resolutions_table
        JOIN public.championship_bracket_competitions AS competitions_table
          ON competitions_table.id = resolutions_table.competition_id
        JOIN latest_edition
          ON latest_edition.id = competitions_table.bracket_edition_id
        JOIN public.sports AS sports_table
          ON sports_table.id = competitions_table.sport_id
        LEFT JOIN public.championship_bracket_groups AS groups_table
          ON groups_table.id = resolutions_table.group_id
        JOIN public.championship_bracket_tie_break_resolution_teams AS resolution_teams_table
          ON resolution_teams_table.resolution_id = resolutions_table.id
        GROUP BY
          resolutions_table.context_key,
          resolutions_table.competition_id,
          competitions_table.sport_id,
          sports_table.name,
          competitions_table.naipe,
          competitions_table.division,
          resolutions_table.context_type,
          resolutions_table.group_id,
          groups_table.group_number,
          resolutions_table.qualification_rank
        HAVING count(resolution_teams_table.id) > 0
      ) AS resolved_contexts
    ),
    '[]'::jsonb
  );
END;
$function$;

-- Supabase source RPC: get_championship_corrected_group_standings
CREATE OR REPLACE FUNCTION public.get_championship_corrected_group_standings(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS TABLE(competition_id uuid, sport_id uuid, sport_name text, naipe match_naipe, division team_division, group_id uuid, group_number integer, group_size integer, team_id uuid, team_name text, wins bigint, points_base bigint, correction_factor numeric, corrected_points numeric, goals_for bigint, goals_against bigint, goal_diff bigint, yellow_cards bigint, red_cards bigint, blue_cards bigint, two_minute_penalties bigint, points_average numeric)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '8s'
AS $function$
  WITH edition_context AS (
    SELECT
      COALESCE(
        (
          SELECT editions_table.id
          FROM public.championship_bracket_editions AS editions_table
          WHERE editions_table.championship_id = _championship_id
            AND (_season_year IS NULL OR editions_table.season_year = _season_year)
          ORDER BY editions_table.created_at DESC
          LIMIT 1
        ),
        (
          SELECT editions_table.id
          FROM public.championship_bracket_editions AS editions_table
          WHERE editions_table.championship_id = _championship_id
          ORDER BY editions_table.created_at DESC
          LIMIT 1
        )
      ) AS bracket_edition_id,
      COALESCE(
        _season_year,
        (
          SELECT editions_table.season_year
          FROM public.championship_bracket_editions AS editions_table
          WHERE editions_table.championship_id = _championship_id
          ORDER BY editions_table.created_at DESC
          LIMIT 1
        )
      ) AS season_year
  ),
  competition_context AS (
    SELECT
      competitions_table.id AS competition_id,
      competitions_table.sport_id,
      sports_table.name AS sport_name,
      competitions_table.naipe,
      competitions_table.division
    FROM public.championship_bracket_competitions AS competitions_table
    JOIN edition_context
      ON edition_context.bracket_edition_id = competitions_table.bracket_edition_id
    JOIN public.sports AS sports_table
      ON sports_table.id = competitions_table.sport_id
  ),
  group_rankings AS (
    SELECT
      competition_context.competition_id,
      competition_context.sport_id,
      competition_context.sport_name,
      competition_context.naipe,
      competition_context.division,
      rankings_table.group_id,
      rankings_table.group_number,
      rankings_table.team_id,
      rankings_table.team_name,
      rankings_table.wins,
      rankings_table.points,
      rankings_table.goal_diff,
      rankings_table.goals_for
    FROM competition_context
    CROSS JOIN LATERAL public.get_championship_bracket_competition_group_rankings(
      _championship_id,
      competition_context.competition_id
    ) AS rankings_table
  ),
  group_sizes AS (
    SELECT
      group_rankings.competition_id,
      group_rankings.group_id,
      group_rankings.group_number,
      count(*)::int AS group_size
    FROM group_rankings
    GROUP BY group_rankings.competition_id, group_rankings.group_id, group_rankings.group_number
  ),
  competition_match_span AS (
    SELECT
      group_sizes.competition_id,
      GREATEST(
        COALESCE(max(GREATEST(group_sizes.group_size - 1, 1)), 1),
        1
      )::numeric AS max_matches_in_competition
    FROM group_sizes
    GROUP BY group_sizes.competition_id
  )
  SELECT
    group_rankings.competition_id,
    group_rankings.sport_id,
    group_rankings.sport_name,
    group_rankings.naipe,
    group_rankings.division,
    group_rankings.group_id,
    group_rankings.group_number,
    group_sizes.group_size,
    group_rankings.team_id,
    group_rankings.team_name,
    group_rankings.wins,
    group_rankings.points AS points_base,
    competition_match_span.max_matches_in_competition / GREATEST(group_sizes.group_size - 1, 1)::numeric AS correction_factor,
    group_rankings.points::numeric * (
      competition_match_span.max_matches_in_competition / GREATEST(group_sizes.group_size - 1, 1)::numeric
    ) AS corrected_points,
    standings_metrics.goals_for,
    standings_metrics.goals_against,
    standings_metrics.goal_diff,
    standings_metrics.yellow_cards,
    standings_metrics.red_cards,
    standings_metrics.blue_cards,
    standings_metrics.two_minute_penalties,
    CASE
      WHEN standings_metrics.goals_against = 0 THEN
        CASE
          WHEN standings_metrics.goals_for = 0 THEN 0::numeric
          ELSE 1000000000::numeric
        END
      ELSE standings_metrics.goals_for::numeric / standings_metrics.goals_against::numeric
    END AS points_average
  FROM group_rankings
  JOIN group_sizes
    ON group_sizes.competition_id = group_rankings.competition_id
    AND group_sizes.group_id = group_rankings.group_id
  JOIN competition_match_span
    ON competition_match_span.competition_id = group_rankings.competition_id
  CROSS JOIN edition_context
  LEFT JOIN public.standings AS standings_table
    ON standings_table.championship_id = _championship_id
    AND standings_table.season_year = edition_context.season_year
    AND standings_table.sport_id = group_rankings.sport_id
    AND standings_table.naipe = group_rankings.naipe
    AND standings_table.division IS NOT DISTINCT FROM group_rankings.division
    AND standings_table.team_id = group_rankings.team_id
  CROSS JOIN LATERAL (
    SELECT
      COALESCE(standings_table.goals_for, group_rankings.goals_for)::bigint AS goals_for,
      COALESCE(
        standings_table.goals_against,
        GREATEST(group_rankings.goals_for - group_rankings.goal_diff, 0)
      )::bigint AS goals_against,
      COALESCE(standings_table.goal_diff, group_rankings.goal_diff)::bigint AS goal_diff,
      COALESCE(standings_table.yellow_cards, 0)::bigint AS yellow_cards,
      COALESCE(standings_table.red_cards, 0)::bigint AS red_cards,
      COALESCE(standings_table.blue_cards, 0)::bigint AS blue_cards,
      COALESCE(standings_table.two_minute_penalties, 0)::bigint AS two_minute_penalties
  ) AS standings_metrics
  ORDER BY
    group_rankings.sport_name ASC,
    group_rankings.naipe ASC,
    group_rankings.division ASC NULLS FIRST,
    group_rankings.group_number ASC,
    corrected_points DESC,
    points_average DESC,
    standings_metrics.goal_diff DESC,
    standings_metrics.goals_for DESC,
    standings_metrics.blue_cards ASC,
    standings_metrics.two_minute_penalties ASC,
    standings_metrics.yellow_cards ASC,
    standings_metrics.red_cards ASC,
    group_rankings.team_name ASC;
$function$;

-- Supabase source RPC: get_championship_score_sheet_awards_rankings
CREATE OR REPLACE FUNCTION public.get_championship_score_sheet_awards_rankings(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH resolved_season AS (
    SELECT COALESCE(
      _season_year,
      championships_table.current_season_year
    ) AS season_year
    FROM public.championships AS championships_table
    WHERE championships_table.id = _championship_id
    LIMIT 1
  ),
  knockout_eligible_teams AS (
    SELECT DISTINCT
      knockout_rows.team_id,
      knockout_rows.sport_id,
      knockout_rows.naipe,
      knockout_rows.division
    FROM (
      SELECT
        matches_table.home_team_id AS team_id,
        matches_table.sport_id,
        matches_table.naipe,
        matches_table.division
      FROM public.matches AS matches_table
      JOIN public.championship_bracket_matches AS bracket_matches_table
        ON bracket_matches_table.match_id = matches_table.id
      JOIN public.championship_bracket_competitions AS competitions_table
        ON competitions_table.id = bracket_matches_table.competition_id
      JOIN public.championship_bracket_editions AS editions_table
        ON editions_table.id = competitions_table.bracket_edition_id
      JOIN resolved_season
        ON editions_table.season_year = resolved_season.season_year
      WHERE editions_table.championship_id = _championship_id
        AND matches_table.status = 'FINISHED'::public.match_status
        AND COALESCE(matches_table.is_walkover, false) = false
        AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
        AND matches_table.home_team_id IS NOT NULL

      UNION ALL

      SELECT
        matches_table.away_team_id AS team_id,
        matches_table.sport_id,
        matches_table.naipe,
        matches_table.division
      FROM public.matches AS matches_table
      JOIN public.championship_bracket_matches AS bracket_matches_table
        ON bracket_matches_table.match_id = matches_table.id
      JOIN public.championship_bracket_competitions AS competitions_table
        ON competitions_table.id = bracket_matches_table.competition_id
      JOIN public.championship_bracket_editions AS editions_table
        ON editions_table.id = competitions_table.bracket_edition_id
      JOIN resolved_season
        ON editions_table.season_year = resolved_season.season_year
      WHERE editions_table.championship_id = _championship_id
        AND matches_table.status = 'FINISHED'::public.match_status
        AND COALESCE(matches_table.is_walkover, false) = false
        AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
        AND matches_table.away_team_id IS NOT NULL
    ) AS knockout_rows
  ),
  scorer_team_advancement_rows AS (
    SELECT
      knockout_team_rows.team_id,
      knockout_team_rows.sport_id,
      knockout_team_rows.naipe,
      knockout_team_rows.division,
      MAX(knockout_team_rows.round_number)::int AS team_advancement_rank
    FROM (
      SELECT
        matches_table.home_team_id AS team_id,
        matches_table.sport_id,
        matches_table.naipe,
        matches_table.division,
        bracket_matches_table.round_number
      FROM public.championship_bracket_matches AS bracket_matches_table
      JOIN public.matches AS matches_table
        ON matches_table.id = bracket_matches_table.match_id
      JOIN public.championship_bracket_competitions AS competitions_table
        ON competitions_table.id = bracket_matches_table.competition_id
      JOIN public.championship_bracket_editions AS editions_table
        ON editions_table.id = competitions_table.bracket_edition_id
      JOIN resolved_season
        ON editions_table.season_year = resolved_season.season_year
      WHERE editions_table.championship_id = _championship_id
        AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
        AND matches_table.home_team_id IS NOT NULL

      UNION ALL

      SELECT
        matches_table.away_team_id AS team_id,
        matches_table.sport_id,
        matches_table.naipe,
        matches_table.division,
        bracket_matches_table.round_number
      FROM public.championship_bracket_matches AS bracket_matches_table
      JOIN public.matches AS matches_table
        ON matches_table.id = bracket_matches_table.match_id
      JOIN public.championship_bracket_competitions AS competitions_table
        ON competitions_table.id = bracket_matches_table.competition_id
      JOIN public.championship_bracket_editions AS editions_table
        ON editions_table.id = competitions_table.bracket_edition_id
      JOIN resolved_season
        ON editions_table.season_year = resolved_season.season_year
      WHERE editions_table.championship_id = _championship_id
        AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
        AND matches_table.away_team_id IS NOT NULL
    ) AS knockout_team_rows
    GROUP BY
      knockout_team_rows.team_id,
      knockout_team_rows.sport_id,
      knockout_team_rows.naipe,
      knockout_team_rows.division
  ),
  scorer_rows AS (
    SELECT
      award_players_table.id AS player_id,
      award_players_table.name AS player_name,
      award_players_table.team_id AS team_id,
      teams_table.name AS team_name,
      award_players_table.naipe,
      award_players_table.division,
      count(*)::int AS goals,
      COALESCE(MAX(scorer_team_advancement_rows.team_advancement_rank), 0)::int AS team_advancement_rank
    FROM public.match_award_goal_scorers AS goal_scorers_table
    JOIN public.championship_award_players AS award_players_table
      ON award_players_table.id = goal_scorers_table.player_id
    JOIN public.matches AS matches_table
      ON matches_table.id = goal_scorers_table.match_id
    JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.match_id = matches_table.id
    JOIN public.championship_sports AS cs_table
      ON cs_table.championship_id = _championship_id
      AND cs_table.sport_id = matches_table.sport_id
    JOIN resolved_season
      ON award_players_table.season_year = resolved_season.season_year
    JOIN public.teams AS teams_table
      ON teams_table.id = award_players_table.team_id
    LEFT JOIN scorer_team_advancement_rows
      ON scorer_team_advancement_rows.team_id = award_players_table.team_id
      AND scorer_team_advancement_rows.sport_id = matches_table.sport_id
      AND scorer_team_advancement_rows.naipe = award_players_table.naipe
      AND scorer_team_advancement_rows.division IS NOT DISTINCT FROM award_players_table.division
    WHERE award_players_table.championship_id = _championship_id
      AND cs_table.supports_individual_awards = true
      AND matches_table.status = 'FINISHED'::public.match_status
      AND COALESCE(matches_table.is_walkover, false) = false
      AND (
        bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
        OR (
          cs_table.awards_include_knockout_phase = true
          AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
        )
      )
      AND (
        cs_table.awards_include_knockout_phase = false
        OR EXISTS (
          SELECT 1
          FROM knockout_eligible_teams
          WHERE knockout_eligible_teams.team_id = award_players_table.team_id
            AND knockout_eligible_teams.sport_id = matches_table.sport_id
            AND knockout_eligible_teams.naipe = award_players_table.naipe
            AND knockout_eligible_teams.division IS NOT DISTINCT FROM award_players_table.division
        )
      )
    GROUP BY
      award_players_table.id,
      award_players_table.name,
      award_players_table.team_id,
      teams_table.name,
      award_players_table.naipe,
      award_players_table.division
  ),
  eligible_matches AS (
    SELECT
      matches_table.id AS match_id,
      matches_table.sport_id,
      matches_table.home_team_id,
      matches_table.away_team_id,
      matches_table.home_score,
      matches_table.away_score,
      matches_table.naipe,
      matches_table.division
    FROM public.matches AS matches_table
    JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.match_id = matches_table.id
    JOIN public.championship_bracket_competitions AS competitions_table
      ON competitions_table.id = bracket_matches_table.competition_id
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    JOIN public.championship_sports AS cs_table
      ON cs_table.championship_id = _championship_id
      AND cs_table.sport_id = matches_table.sport_id
    JOIN resolved_season
      ON editions_table.season_year = resolved_season.season_year
    WHERE editions_table.championship_id = _championship_id
      AND cs_table.supports_individual_awards = true
      AND matches_table.status = 'FINISHED'::public.match_status
      AND COALESCE(matches_table.is_walkover, false) = false
      AND (
        bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
        OR (
          cs_table.awards_include_knockout_phase = true
          AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
        )
      )
  ),
  defense_rows AS (
    SELECT
      team_matches.team_id,
      team_matches.sport_id,
      teams_table.name AS team_name,
      team_matches.naipe,
      team_matches.division,
      COUNT(*)::int AS matches_count,
      SUM(team_matches.goals_against)::int AS goals_against,
      (SUM(team_matches.goals_against)::numeric / COUNT(*)::numeric) AS goals_against_average
    FROM (
      SELECT
        eligible_matches.home_team_id AS team_id,
        eligible_matches.sport_id,
        eligible_matches.naipe,
        eligible_matches.division,
        eligible_matches.away_score::int AS goals_against
      FROM eligible_matches

      UNION ALL

      SELECT
        eligible_matches.away_team_id AS team_id,
        eligible_matches.sport_id,
        eligible_matches.naipe,
        eligible_matches.division,
        eligible_matches.home_score::int AS goals_against
      FROM eligible_matches
    ) AS team_matches
    JOIN public.teams AS teams_table
      ON teams_table.id = team_matches.team_id
    JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = _championship_id
      AND championship_sports_table.sport_id = team_matches.sport_id
    WHERE
      championship_sports_table.awards_include_knockout_phase = false
      OR EXISTS (
        SELECT 1
        FROM knockout_eligible_teams
        WHERE knockout_eligible_teams.team_id = team_matches.team_id
          AND knockout_eligible_teams.sport_id = team_matches.sport_id
          AND knockout_eligible_teams.naipe = team_matches.naipe
          AND knockout_eligible_teams.division IS NOT DISTINCT FROM team_matches.division
      )
    GROUP BY
      team_matches.team_id,
      team_matches.sport_id,
      teams_table.name,
      team_matches.naipe,
      team_matches.division
  ),
  pending_matches AS (
    SELECT count(*)::int AS total
    FROM public.matches AS matches_table
    JOIN public.championship_bracket_matches AS bm
      ON bm.match_id = matches_table.id
    JOIN public.championship_sports AS cs_table
      ON cs_table.championship_id = _championship_id
      AND cs_table.sport_id = matches_table.sport_id
    JOIN resolved_season
      ON matches_table.season_year = resolved_season.season_year
    WHERE matches_table.championship_id = _championship_id
      AND cs_table.supports_individual_awards = true
      AND COALESCE(matches_table.is_walkover, false) = false
      AND (
        matches_table.status <> 'FINISHED'::public.match_status
        OR COALESCE(matches_table.is_score_sheet_reviewed, false) = false
      )
      AND (
        bm.phase = 'GROUP_STAGE'::public.bracket_phase
        OR (
          cs_table.awards_include_knockout_phase = true
          AND bm.phase = 'KNOCKOUT'::public.bracket_phase
        )
      )
  ),
  pending_award_contexts AS (
    SELECT
      matches_table.naipe,
      matches_table.division,
      count(*)::int AS pending_matches_count
    FROM public.matches AS matches_table
    JOIN public.championship_bracket_matches AS bm
      ON bm.match_id = matches_table.id
    JOIN public.championship_sports AS cs_table
      ON cs_table.championship_id = _championship_id
      AND cs_table.sport_id = matches_table.sport_id
    JOIN resolved_season
      ON matches_table.season_year = resolved_season.season_year
    WHERE matches_table.championship_id = _championship_id
      AND cs_table.supports_individual_awards = true
      AND COALESCE(matches_table.is_walkover, false) = false
      AND (
        matches_table.status <> 'FINISHED'::public.match_status
        OR COALESCE(matches_table.is_score_sheet_reviewed, false) = false
      )
      AND (
        bm.phase = 'GROUP_STAGE'::public.bracket_phase
        OR (
          cs_table.awards_include_knockout_phase = true
          AND bm.phase = 'KNOCKOUT'::public.bracket_phase
        )
      )
    GROUP BY
      matches_table.naipe,
      matches_table.division
  ),
  draw_results AS (
    SELECT
      dr.award_type,
      dr.naipe,
      dr.division,
      dr.winner_player_id,
      dr.winner_team_id
    FROM public.championship_award_draw_results dr
    JOIN resolved_season ON dr.season_year = resolved_season.season_year
    WHERE dr.championship_id = _championship_id
  )
  SELECT jsonb_build_object(
    'season_year', (SELECT resolved_season.season_year FROM resolved_season),
    'pending_matches_count', COALESCE((SELECT pending_matches.total FROM pending_matches), 0),
    'pending_award_contexts',
      COALESCE(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'naipe', pending_award_contexts.naipe,
              'division', pending_award_contexts.division,
              'pending_matches_count', pending_award_contexts.pending_matches_count
            )
            ORDER BY
              pending_award_contexts.naipe ASC,
              pending_award_contexts.division ASC NULLS FIRST
          )
          FROM pending_award_contexts
        ),
        '[]'::jsonb
      ),
    'top_scorers',
      COALESCE(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'player_id', scorer_rows.player_id,
              'player_name', scorer_rows.player_name,
              'team_id', scorer_rows.team_id,
              'team_name', scorer_rows.team_name,
              'naipe', scorer_rows.naipe,
              'division', scorer_rows.division,
              'goals', scorer_rows.goals,
              'team_advancement_rank', scorer_rows.team_advancement_rank
            )
            ORDER BY
              scorer_rows.goals DESC,
              scorer_rows.team_advancement_rank DESC,
              scorer_rows.naipe ASC,
              scorer_rows.division ASC NULLS FIRST,
              scorer_rows.player_name ASC
          )
          FROM scorer_rows
        ),
        '[]'::jsonb
      ),
    'best_defenses',
      COALESCE(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'team_id', defense_rows.team_id,
              'team_name', defense_rows.team_name,
              'naipe', defense_rows.naipe,
              'division', defense_rows.division,
              'matches_count', defense_rows.matches_count,
              'goals_against', defense_rows.goals_against,
              'goals_against_average', defense_rows.goals_against_average
            )
            ORDER BY
              defense_rows.goals_against_average ASC,
              defense_rows.goals_against ASC,
              defense_rows.matches_count DESC,
              defense_rows.naipe ASC,
              defense_rows.division ASC NULLS FIRST,
              defense_rows.team_name ASC
          )
          FROM defense_rows
        ),
        '[]'::jsonb
      ),
    'award_draw_results',
      COALESCE(
        (
          SELECT jsonb_agg(
            jsonb_build_object(
              'award_type', draw_results.award_type,
              'naipe', draw_results.naipe,
              'division', draw_results.division,
              'winner_player_id', draw_results.winner_player_id,
              'winner_team_id', draw_results.winner_team_id
            )
          )
          FROM draw_results
        ),
        '[]'::jsonb
      )
  );
$function$;

-- Supabase source RPC: get_championship_yellow_card_discipline
CREATE OR REPLACE FUNCTION public.get_championship_yellow_card_discipline(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '4s'
AS $function$
  WITH resolved_season AS (
    SELECT COALESCE(_season_year, championships_table.current_season_year) AS season_year
    FROM public.championships AS championships_table
    WHERE championships_table.id = _championship_id
    LIMIT 1
  ),
  bracket_editions AS (
    SELECT DISTINCT ON (editions_table.championship_id, editions_table.season_year)
      editions_table.championship_id,
      editions_table.season_year,
      editions_table.payload_snapshot
    FROM public.championship_bracket_editions AS editions_table
    JOIN resolved_season
      ON resolved_season.season_year = editions_table.season_year
    WHERE editions_table.championship_id = _championship_id
    ORDER BY editions_table.championship_id, editions_table.season_year, editions_table.updated_at DESC, editions_table.id DESC
  ),
  numbered_matches AS (
    SELECT numbered_matches_source.id,
      row_number() OVER (
        PARTITION BY numbered_matches_source.numbering_scope
        ORDER BY numbered_matches_source.scheduled_date,
          numbered_matches_source.start_time NULLS LAST,
          COALESCE(numbered_matches_source.scheduled_slot, numbered_matches_source.queue_position) NULLS LAST,
          numbered_matches_source.created_at,
          numbered_matches_source.id
      )::INTEGER AS match_number
    FROM (
      SELECT matches_table.id,
        matches_table.scheduled_date,
        matches_table.start_time,
        matches_table.scheduled_slot,
        matches_table.queue_position,
        matches_table.created_at,
        CASE
          WHEN bracket_editions.payload_snapshot ->> 'match_numbering_mode' = 'SPORT_NAIPE'
            THEN concat_ws('::', matches_table.sport_id::TEXT, matches_table.naipe::TEXT)
          WHEN bracket_editions.payload_snapshot ->> 'match_numbering_mode' = 'SPORT'
            THEN matches_table.sport_id::TEXT
          ELSE concat_ws('::', matches_table.location, matches_table.court_name)
        END AS numbering_scope
      FROM public.matches AS matches_table
      JOIN resolved_season
        ON resolved_season.season_year = matches_table.season_year
      LEFT JOIN bracket_editions
        ON bracket_editions.championship_id = matches_table.championship_id
        AND bracket_editions.season_year = matches_table.season_year
      WHERE matches_table.championship_id = _championship_id
        AND matches_table.scheduled_date IS NOT NULL
        AND (
          COALESCE(bracket_editions.payload_snapshot ->> 'match_numbering_mode', 'COURT') IN ('SPORT', 'SPORT_NAIPE')
          OR (
            NULLIF(btrim(matches_table.location), '') IS NOT NULL
            AND NULLIF(btrim(matches_table.court_name), '') IS NOT NULL
          )
        )
    ) AS numbered_matches_source
  ),
  team_match_sequence AS (
    SELECT matches_table.id AS match_id,
      matches_table.sport_id,
      matches_table.naipe,
      matches_table.division,
      matches_table.home_team_id AS team_id,
      matches_table.home_team_id,
      matches_table.away_team_id,
      matches_table.scheduled_date,
      matches_table.start_time,
      CASE
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
          AND bracket_matches_table.is_third_place THEN 'THIRD_PLACE'
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
          AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) THEN 'FINAL'
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
          AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) - 1 THEN 'SEMIFINAL'
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
          AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) - 2 THEN 'QUARTERFINAL'
        ELSE 'GROUP_STAGE'
      END AS phase,
      matches_table.status,
      row_number() OVER (
        PARTITION BY matches_table.sport_id, matches_table.naipe, matches_table.division, matches_table.home_team_id
        ORDER BY matches_table.scheduled_date NULLS LAST, matches_table.start_time NULLS LAST, matches_table.queue_position NULLS LAST, matches_table.id
      ) AS match_sequence
    FROM public.matches AS matches_table
    JOIN resolved_season
      ON resolved_season.season_year = matches_table.season_year
    LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.match_id = matches_table.id
    WHERE matches_table.championship_id = _championship_id

    UNION ALL

    SELECT matches_table.id AS match_id,
      matches_table.sport_id,
      matches_table.naipe,
      matches_table.division,
      matches_table.away_team_id AS team_id,
      matches_table.home_team_id,
      matches_table.away_team_id,
      matches_table.scheduled_date,
      matches_table.start_time,
      CASE
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
          AND bracket_matches_table.is_third_place THEN 'THIRD_PLACE'
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
          AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) THEN 'FINAL'
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
          AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) - 1 THEN 'SEMIFINAL'
        WHEN bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
          AND bracket_matches_table.round_number = public.resolve_championship_competition_expected_knockout_rounds(bracket_matches_table.competition_id) - 2 THEN 'QUARTERFINAL'
        ELSE 'GROUP_STAGE'
      END AS phase,
      matches_table.status,
      row_number() OVER (
        PARTITION BY matches_table.sport_id, matches_table.naipe, matches_table.division, matches_table.away_team_id
        ORDER BY matches_table.scheduled_date NULLS LAST, matches_table.start_time NULLS LAST, matches_table.queue_position NULLS LAST, matches_table.id
      ) AS match_sequence
    FROM public.matches AS matches_table
    JOIN resolved_season
      ON resolved_season.season_year = matches_table.season_year
    LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.match_id = matches_table.id
    WHERE matches_table.championship_id = _championship_id
  ),
  discipline AS (
    SELECT public.get_championship_yellow_card_discipline_raw(
      _championship_id,
      _season_year
    ) AS payload
  ),
  discipline_athletes AS (
    SELECT athlete.value,
      public.normalize_sport_name(athlete.value ->> 'sport_name') = 'handebol' AS is_handball
    FROM discipline
    CROSS JOIN LATERAL jsonb_array_elements(
      COALESCE(discipline.payload -> 'athletes', '[]'::jsonb)
    ) AS athlete(value)
  )
  SELECT jsonb_build_object(
    'season_year', discipline.payload -> 'season_year',
    'athletes', COALESCE((
      SELECT jsonb_agg(
        (discipline_athletes.value - 'red_cards_derived_total') || jsonb_build_object(
          'yellow_cards_active', CASE
            WHEN discipline_athletes.is_handball THEN '0'::jsonb
            ELSE COALESCE(discipline_athletes.value -> 'yellow_cards_active', '0'::jsonb)
          END,
          'is_suspended', CASE
            WHEN discipline_athletes.is_handball THEN 'false'::jsonb
            ELSE COALESCE(discipline_athletes.value -> 'is_suspended', 'false'::jsonb)
          END,
          'suspension_causes', CASE
            WHEN discipline_athletes.is_handball THEN '[]'::jsonb
            ELSE COALESCE(discipline_athletes.value -> 'suspension_causes', '[]'::jsonb)
          END,
          'next_match', CASE
            WHEN discipline_athletes.is_handball THEN 'null'::jsonb
            ELSE COALESCE(discipline_athletes.value -> 'next_match', 'null'::jsonb)
          END,
          'matches', COALESCE((
            SELECT jsonb_agg(
              (history.value - 'red_cards_derived') || jsonb_build_object(
                'match_number', COALESCE(
                  numbered_matches.match_number,
                  matches_table.scheduled_slot,
                  matches_table.queue_position
                ),
                'opponent_name', CASE
                  WHEN matches_table.home_team_id = (discipline_athletes.value ->> 'team_id')::UUID THEN away_teams_table.name
                  WHEN matches_table.away_team_id = (discipline_athletes.value ->> 'team_id')::UUID THEN home_teams_table.name
                  ELSE NULL
                END
              )
              ORDER BY history.position
            )
            FROM jsonb_array_elements(
              COALESCE(discipline_athletes.value -> 'matches', '[]'::jsonb)
            ) WITH ORDINALITY AS history(value, position)
            LEFT JOIN public.matches AS matches_table
              ON matches_table.id = (history.value ->> 'match_id')::UUID
            LEFT JOIN numbered_matches
              ON numbered_matches.id = matches_table.id
            LEFT JOIN public.teams AS home_teams_table
              ON home_teams_table.id = matches_table.home_team_id
            LEFT JOIN public.teams AS away_teams_table
              ON away_teams_table.id = matches_table.away_team_id
          ), '[]'::jsonb),
          'served_suspensions', CASE
            WHEN discipline_athletes.is_handball THEN '[]'::jsonb
            ELSE COALESCE((
              SELECT jsonb_agg(
                jsonb_build_object(
                  'suspension_match_id', suspension_history.value ->> 'match_id',
                  'direct_red', COALESCE((suspension_history.value ->> 'red_cards_direct')::INTEGER, 0) > 0,
                  'yellow_accumulation', COALESCE((suspension_history.value ->> 'red_cards_derived')::INTEGER, 0) > 0,
                  'served_match', jsonb_build_object(
                    'match_id', next_match.match_id,
                    'match_number', COALESCE(next_match_number.match_number, next_match.match_sequence::INTEGER),
                    'scheduled_date', next_match.scheduled_date,
                    'start_time', next_match.start_time,
                    'phase', next_match.phase,
                    'opponent_name', CASE
                      WHEN next_match.home_team_id = (discipline_athletes.value ->> 'team_id')::UUID THEN next_away_team.name
                      ELSE next_home_team.name
                    END
                  )
                )
                ORDER BY suspension_match.match_sequence
              )
              FROM jsonb_array_elements(
                COALESCE(discipline_athletes.value -> 'matches', '[]'::jsonb)
              ) AS suspension_history(value)
              JOIN team_match_sequence AS suspension_match
                ON suspension_match.match_id = (suspension_history.value ->> 'match_id')::UUID
                AND suspension_match.team_id = (discipline_athletes.value ->> 'team_id')::UUID
              JOIN LATERAL (
                SELECT following_match.*
                FROM team_match_sequence AS following_match
                WHERE following_match.team_id = suspension_match.team_id
                  AND following_match.sport_id = suspension_match.sport_id
                  AND following_match.naipe = suspension_match.naipe
                  AND following_match.division IS NOT DISTINCT FROM suspension_match.division
                  AND following_match.match_sequence > suspension_match.match_sequence
                ORDER BY following_match.match_sequence
                LIMIT 1
              ) AS next_match ON true
              LEFT JOIN numbered_matches AS next_match_number
                ON next_match_number.id = next_match.match_id
              LEFT JOIN public.teams AS next_home_team
                ON next_home_team.id = next_match.home_team_id
              LEFT JOIN public.teams AS next_away_team
                ON next_away_team.id = next_match.away_team_id
              WHERE (
                COALESCE((suspension_history.value ->> 'red_cards_direct')::INTEGER, 0) > 0
                OR COALESCE((suspension_history.value ->> 'red_cards_derived')::INTEGER, 0) > 0
              )
                AND next_match.status = 'FINISHED'::public.match_status
            ), '[]'::jsonb)
          END
        )
      )
      FROM discipline_athletes
    ), '[]'::jsonb)
  )
  FROM discipline;
$function$;

-- Supabase source RPC: get_interlaje_regulation_competition_standings
CREATE OR REPLACE FUNCTION public.get_interlaje_regulation_competition_standings(_championship_id uuid, _season_year integer, _sport_id uuid, _naipe match_naipe, _division team_division DEFAULT NULL::team_division)
 RETURNS TABLE(team_id uuid, team_name text, division team_division, played integer, wins integer, draws integer, losses integer, goals_for integer, goals_against integer, goal_diff integer, points numeric, yellow_cards integer, red_cards integer, blue_cards integer, two_minute_penalties integer, final_position integer, placement_points integer, placement_status text, placement_basis text, sets_for integer, sets_against integer, rally_points_for integer, rally_points_against integer, has_pending_tie_break boolean, classification_policy jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH policy AS (
    SELECT public.get_interlaje_classification_policy(_championship_id, _sport_id) AS value
  ), collective_ranked AS (
    SELECT
      ranking.*,
      BOOL_OR(ranking.played > 0) OVER (
        PARTITION BY ranking.division
      ) AS has_completed_result,
      public.is_championship_competition_team_disqualified(
        _championship_id,
        _season_year,
        _sport_id,
        _naipe,
        ranking.division,
        ranking.team_id
      ) AS is_disqualified
    FROM policy
    CROSS JOIN LATERAL public.get_interlaje_collective_ranking(
      _championship_id,
      _season_year,
      _sport_id,
      _naipe,
      _division
    ) AS ranking
    WHERE policy.value ->> 'mode' = 'COLLECTIVE'
  ), ranking_payload AS (
    SELECT
      collective_ranked.division,
      jsonb_agg(
        jsonb_build_object(
          'team_id', collective_ranked.team_id,
          'final_position', collective_ranked.classification_rank
        )
        ORDER BY collective_ranked.classification_rank
      ) AS ranked_teams,
      BOOL_OR(collective_ranked.has_pending_tie_break) AS has_pending_tie_break
    FROM collective_ranked
    GROUP BY collective_ranked.division
  ), competition_context AS (
    SELECT
      competitions_table.id AS competition_id,
      competitions_table.division,
      COALESCE(
        BOOL_AND(
          group_matches_table.match_id IS NOT NULL
          AND matches_table.status = 'FINISHED'::public.match_status
        ),
        false
      ) AS is_group_stage_finished,
      COALESCE(knockout_context.participant_count, 0) AS knockout_participant_count
    FROM public.championship_bracket_competitions AS competitions_table
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    LEFT JOIN public.championship_bracket_matches AS group_matches_table
      ON group_matches_table.competition_id = competitions_table.id
      AND group_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
    LEFT JOIN public.matches AS matches_table
      ON matches_table.id = group_matches_table.match_id
    LEFT JOIN LATERAL (
      WITH first_round AS (
        SELECT MIN(knockout_matches.round_number) AS round_number
        FROM public.championship_bracket_matches AS knockout_matches
        WHERE knockout_matches.competition_id = competitions_table.id
          AND knockout_matches.phase = 'KNOCKOUT'::public.bracket_phase
          AND knockout_matches.is_third_place = false
      ), participants AS (
        SELECT knockout_matches.home_team_id AS team_id
        FROM public.championship_bracket_matches AS knockout_matches
        CROSS JOIN first_round
        WHERE knockout_matches.competition_id = competitions_table.id
          AND knockout_matches.phase = 'KNOCKOUT'::public.bracket_phase
          AND knockout_matches.is_third_place = false
          AND knockout_matches.round_number = first_round.round_number
          AND knockout_matches.home_team_id IS NOT NULL
        UNION ALL
        SELECT knockout_matches.away_team_id
        FROM public.championship_bracket_matches AS knockout_matches
        CROSS JOIN first_round
        WHERE knockout_matches.competition_id = competitions_table.id
          AND knockout_matches.phase = 'KNOCKOUT'::public.bracket_phase
          AND knockout_matches.is_third_place = false
          AND knockout_matches.round_number = first_round.round_number
          AND knockout_matches.away_team_id IS NOT NULL
      )
      SELECT COUNT(DISTINCT participants.team_id)::INTEGER AS participant_count
      FROM participants
    ) AS knockout_context ON true
    WHERE editions_table.championship_id = _championship_id
      AND editions_table.season_year = _season_year
      AND competitions_table.sport_id = _sport_id
      AND competitions_table.naipe = _naipe
      AND (
        _division IS NULL
        OR competitions_table.division IS NOT DISTINCT FROM _division
      )
    GROUP BY
      competitions_table.id,
      competitions_table.division,
      knockout_context.participant_count
  ), knockout_placements AS (
    SELECT
      competition_context.competition_id,
      competition_context.division,
      placements.*
    FROM competition_context
    JOIN ranking_payload
      ON ranking_payload.division IS NOT DISTINCT FROM competition_context.division
    CROSS JOIN LATERAL public.get_interlaje_knockout_final_placements(
      competition_context.competition_id,
      ranking_payload.ranked_teams
    ) AS placements
    WHERE ranking_payload.has_pending_tie_break = false
  ), collective_joined AS (
    SELECT
      ranking.*,
      competition_context.competition_id,
      competition_context.is_group_stage_finished,
      competition_context.knockout_participant_count,
      knockout_placements.final_position AS knockout_final_position,
      knockout_placements.placement_status AS knockout_placement_status,
      knockout_placements.placement_basis AS knockout_placement_basis,
      knockout_placements.placement_stage,
      knockout_placements.eliminated_by_team_id,
      knockout_placements.eliminated_by_final_position,
      knockout_placements.placement_reason,
      eliminated_by_team.name AS eliminated_by_team_name,
      COUNT(knockout_placements.team_id) OVER (
        PARTITION BY competition_context.competition_id
      )::INTEGER AS resolved_knockout_count
    FROM collective_ranked AS ranking
    LEFT JOIN competition_context
      ON competition_context.division IS NOT DISTINCT FROM ranking.division
    LEFT JOIN knockout_placements
      ON knockout_placements.competition_id = competition_context.competition_id
      AND knockout_placements.team_id = ranking.team_id
    LEFT JOIN public.teams AS eliminated_by_team
      ON eliminated_by_team.id = knockout_placements.eliminated_by_team_id
  ), collective_numbered AS (
    SELECT
      collective_joined.*,
      ROW_NUMBER() OVER (
        PARTITION BY collective_joined.division, (collective_joined.knockout_final_position IS NULL)
        ORDER BY collective_joined.classification_rank, collective_joined.team_id
      )::INTEGER AS non_knockout_rank,
      collective_joined.knockout_participant_count IN (4, 8)
        AND collective_joined.resolved_knockout_count = collective_joined.knockout_participant_count
        AND collective_joined.has_pending_tie_break = false
        AS has_resolved_knockout_structure
    FROM collective_joined
  ), collective_positioned AS (
    SELECT
      collective_numbered.*,
      CASE
        WHEN collective_numbered.knockout_final_position IS NOT NULL
          THEN collective_numbered.knockout_final_position
        WHEN collective_numbered.has_resolved_knockout_structure
          THEN collective_numbered.knockout_participant_count + collective_numbered.non_knockout_rank
        ELSE collective_numbered.classification_rank
      END::INTEGER AS resolved_final_position,
      CASE
        WHEN collective_numbered.has_pending_tie_break THEN 'PENDING_TIE_BREAK'
        WHEN collective_numbered.knockout_final_position IS NOT NULL
          THEN collective_numbered.knockout_placement_status
        WHEN collective_numbered.knockout_participant_count IN (4, 8)
          AND NOT collective_numbered.has_resolved_knockout_structure
          THEN 'PROJECTED'
        WHEN collective_numbered.is_group_stage_finished THEN 'CONFIRMED'
        ELSE 'PROJECTED'
      END::TEXT AS resolved_placement_status,
      CASE
        WHEN collective_numbered.knockout_final_position IS NOT NULL THEN 'KNOCKOUT'
        ELSE 'GROUP_STAGE'
      END::TEXT AS resolved_placement_basis
    FROM collective_numbered
  ), collective AS (
    SELECT
      ranking.team_id,
      ranking.team_name,
      ranking.division,
      ranking.played,
      ranking.wins,
      ranking.draws,
      ranking.losses,
      ranking.goals_for,
      ranking.goals_against,
      ranking.goal_diff,
      ranking.points,
      ranking.yellow_cards,
      ranking.red_cards,
      ranking.blue_cards,
      ranking.two_minute_penalties,
      ranking.resolved_final_position AS final_position,
      CASE
        WHEN ranking.is_disqualified
          OR NOT ranking.has_completed_result
          OR ranking.has_pending_tie_break
        THEN 0
        ELSE COALESCE(settings_table.points, 0)
      END::INTEGER AS placement_points,
      ranking.resolved_placement_status AS placement_status,
      ranking.resolved_placement_basis AS placement_basis,
      ranking.sets_for,
      ranking.sets_against,
      ranking.rally_points_for,
      ranking.rally_points_against,
      ranking.has_pending_tie_break,
      policy.value || jsonb_build_object(
        'placement_context',
        jsonb_strip_nulls(jsonb_build_object(
          'stage', COALESCE(
            ranking.placement_stage,
            CASE WHEN ranking.has_resolved_knockout_structure THEN 'GROUP_STAGE' ELSE 'GROUP_STAGE' END
          ),
          'status', ranking.resolved_placement_status,
          'reason', COALESCE(
            ranking.placement_reason,
            CASE
              WHEN ranking.has_resolved_knockout_structure THEN 'GROUP_STAGE_ELIMINATION'
              ELSE 'GROUP_STAGE_RANKING'
            END
          ),
          'final_position', ranking.resolved_final_position,
          'group_stage_rank', ranking.classification_rank,
          'knockout_reserved_positions', CASE
            WHEN ranking.has_resolved_knockout_structure THEN ranking.knockout_participant_count
            ELSE NULL
          END,
          'is_knockout_participant', ranking.knockout_final_position IS NOT NULL,
          'eliminated_by_team_id', ranking.eliminated_by_team_id,
          'eliminated_by_team_name', ranking.eliminated_by_team_name,
          'eliminated_by_final_position', ranking.eliminated_by_final_position
        ))
      ) AS classification_policy
    FROM policy
    JOIN collective_positioned AS ranking ON true
    LEFT JOIN public.championship_overall_position_point_settings AS settings_table
      ON settings_table.championship_id = _championship_id
      AND settings_table.season_year = _season_year
      AND settings_table.final_position = ranking.resolved_final_position
  ), individual_base AS (
    SELECT
      individual_standings.team_id,
      teams_table.name AS team_name,
      individual_standings.division,
      individual_standings.scored_events_count,
      individual_standings.total_points,
      individual_standings.first_places,
      individual_standings.second_places,
      individual_standings.third_places,
      individual_standings.fourth_places,
      individual_standings.fifth_places,
      individual_standings.sixth_places,
      individual_standings.seventh_places,
      individual_standings.eighth_places,
      individual_standings.ninth_places,
      individual_standings.tenth_places,
      individual_standings.eleventh_places,
      individual_standings.twelfth_places,
      individual_standings.thirteenth_places,
      individual_standings.fourteenth_places,
      individual_standings.fifteenth_places,
      individual_standings.sixteenth_places,
      individual_standings.seventeenth_places,
      individual_standings.eighteenth_places,
      individual_standings.nineteenth_places,
      individual_standings.twentieth_places,
      public.is_championship_competition_team_disqualified(
        _championship_id,
        _season_year,
        _sport_id,
        _naipe,
        individual_standings.division,
        individual_standings.team_id
      ) AS is_disqualified,
      resolutions_table.draw_order,
      COALESCE(session_context.is_finished, false) AS is_finished
    FROM policy
    JOIN public.championship_individual_team_standings AS individual_standings
      ON policy.value ->> 'mode' = 'INDIVIDUAL'
    JOIN public.teams AS teams_table
      ON teams_table.id = individual_standings.team_id
    LEFT JOIN public.championship_interlaje_tie_break_resolutions AS resolutions_table
      ON resolutions_table.championship_id = _championship_id
      AND resolutions_table.season_year = _season_year
      AND resolutions_table.sport_id = _sport_id
      AND resolutions_table.naipe = _naipe
      AND resolutions_table.division IS NOT DISTINCT FROM individual_standings.division
      AND resolutions_table.group_id IS NULL
      AND resolutions_table.team_id = individual_standings.team_id
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*) > 0
          AND BOOL_AND(
            sessions_table.status IN (
              'FINISHED'::public.championship_individual_session_status,
              'CANCELLED'::public.championship_individual_session_status
            )
          ) AS is_finished
      FROM public.championship_individual_sessions AS sessions_table
      WHERE sessions_table.championship_id = _championship_id
        AND sessions_table.season_year = _season_year
        AND sessions_table.sport_id = _sport_id
        AND sessions_table.naipe = _naipe
        AND sessions_table.division IS NOT DISTINCT FROM individual_standings.division
    ) AS session_context ON true
    WHERE individual_standings.championship_id = _championship_id
      AND individual_standings.season_year = _season_year
      AND individual_standings.sport_id = _sport_id
      AND individual_standings.naipe = _naipe
      AND (_division IS NULL OR individual_standings.division IS NOT DISTINCT FROM _division)
  ), individual_ranked AS (
    SELECT
      individual_base.*,
      COUNT(*) OVER (
        PARTITION BY
          individual_base.division,
          individual_base.total_points,
          individual_base.first_places,
          individual_base.second_places,
          individual_base.third_places,
          individual_base.fourth_places,
          individual_base.fifth_places,
          individual_base.sixth_places,
          individual_base.seventh_places,
          individual_base.eighth_places,
          individual_base.ninth_places,
          individual_base.tenth_places,
          individual_base.eleventh_places,
          individual_base.twelfth_places,
          individual_base.thirteenth_places,
          individual_base.fourteenth_places,
          individual_base.fifteenth_places,
          individual_base.sixteenth_places,
          individual_base.seventeenth_places,
          individual_base.eighteenth_places,
          individual_base.nineteenth_places,
          individual_base.twentieth_places
      )::INTEGER AS unresolved_count,
      ROW_NUMBER() OVER (
        PARTITION BY individual_base.division
        ORDER BY
          individual_base.is_disqualified ASC,
          individual_base.total_points DESC,
          individual_base.first_places DESC,
          individual_base.second_places DESC,
          individual_base.third_places DESC,
          individual_base.fourth_places DESC,
          individual_base.fifth_places DESC,
          individual_base.sixth_places DESC,
          individual_base.seventh_places DESC,
          individual_base.eighth_places DESC,
          individual_base.ninth_places DESC,
          individual_base.tenth_places DESC,
          individual_base.eleventh_places DESC,
          individual_base.twelfth_places DESC,
          individual_base.thirteenth_places DESC,
          individual_base.fourteenth_places DESC,
          individual_base.fifteenth_places DESC,
          individual_base.sixteenth_places DESC,
          individual_base.seventeenth_places DESC,
          individual_base.eighteenth_places DESC,
          individual_base.nineteenth_places DESC,
          individual_base.twentieth_places DESC,
          COALESCE(individual_base.draw_order, 2147483647) ASC,
          individual_base.team_id ASC
      )::INTEGER AS resolved_final_position
    FROM individual_base
  ), individual AS (
    SELECT
      ranking.team_id,
      ranking.team_name,
      ranking.division,
      ranking.scored_events_count::INTEGER AS played,
      ranking.first_places::INTEGER AS wins,
      ranking.second_places::INTEGER AS draws,
      0::INTEGER AS losses,
      0::INTEGER AS goals_for,
      0::INTEGER AS goals_against,
      0::INTEGER AS goal_diff,
      ranking.total_points::NUMERIC AS points,
      0::INTEGER AS yellow_cards,
      0::INTEGER AS red_cards,
      0::INTEGER AS blue_cards,
      0::INTEGER AS two_minute_penalties,
      ranking.resolved_final_position AS final_position,
      CASE
        WHEN ranking.is_disqualified
          OR NOT ranking.is_finished
          OR (ranking.unresolved_count > 1 AND ranking.draw_order IS NULL)
        THEN 0
        ELSE COALESCE(settings_table.points, 0)
      END::INTEGER AS placement_points,
      CASE
        WHEN ranking.unresolved_count > 1 AND ranking.draw_order IS NULL
          THEN 'PENDING_TIE_BREAK'
        WHEN ranking.is_finished THEN 'CONFIRMED'
        ELSE 'PROJECTED'
      END::TEXT AS placement_status,
      'INDIVIDUAL'::TEXT AS placement_basis,
      0::INTEGER AS sets_for,
      0::INTEGER AS sets_against,
      0::INTEGER AS rally_points_for,
      0::INTEGER AS rally_points_against,
      (ranking.unresolved_count > 1 AND ranking.draw_order IS NULL) AS has_pending_tie_break,
      policy.value || jsonb_build_object(
        'placement_context',
        jsonb_build_object(
          'stage', 'INDIVIDUAL',
          'status', CASE
            WHEN ranking.unresolved_count > 1 AND ranking.draw_order IS NULL
              THEN 'PENDING_TIE_BREAK'
            WHEN ranking.is_finished THEN 'CONFIRMED'
            ELSE 'PROJECTED'
          END,
          'reason', 'INDIVIDUAL_RANKING',
          'final_position', ranking.resolved_final_position
        )
      ) AS classification_policy
    FROM policy
    JOIN individual_ranked AS ranking ON true
    LEFT JOIN public.championship_overall_position_point_settings AS settings_table
      ON settings_table.championship_id = _championship_id
      AND settings_table.season_year = _season_year
      AND settings_table.final_position = ranking.resolved_final_position
  )
  SELECT * FROM collective
  UNION ALL
  SELECT * FROM individual
  ORDER BY final_position, team_id;
$function$;

-- Supabase source RPC: get_interlaje_overall_standings
CREATE OR REPLACE FUNCTION public.get_interlaje_overall_standings(_championship_id uuid, _season_year integer)
 RETURNS TABLE(team_id uuid, team_name text, placement_points numeric, confirmed_placement_points numeric, projected_placement_points numeric, opening_bonus_points numeric, walkover_count integer, walkover_penalty_points numeric, overall_points numeric, confirmed_competitions_count integer, has_projected_placement_points boolean, has_pending_tie_break boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '4s'
AS $function$
  WITH participating_teams AS (
    SELECT DISTINCT registrations_table.team_id
    FROM public.championship_bracket_team_registrations AS registrations_table
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = registrations_table.bracket_edition_id
    WHERE editions_table.championship_id = _championship_id
      AND editions_table.season_year = _season_year
  ), competition_contexts AS (
    SELECT DISTINCT standings_table.sport_id, standings_table.naipe, standings_table.division
    FROM public.get_championship_effective_standings(
      _championship_id,
      _season_year,
      NULL,
      NULL,
      NULL
    ) AS standings_table
  ), competition_points AS (
    SELECT
      standings_table.team_id,
      standings_table.placement_points,
      standings_table.placement_status,
      standings_table.has_pending_tie_break
    FROM competition_contexts
    CROSS JOIN LATERAL public.get_interlaje_regulation_competition_standings(
      _championship_id,
      _season_year,
      competition_contexts.sport_id,
      competition_contexts.naipe,
      competition_contexts.division
    ) AS standings_table
  ), placement_totals AS (
    SELECT
      competition_points.team_id,
      COALESCE(SUM(competition_points.placement_points), 0) AS placement_points,
      COALESCE(
        SUM(competition_points.placement_points)
          FILTER (WHERE competition_points.placement_status = 'CONFIRMED'),
        0
      ) AS confirmed_placement_points,
      COALESCE(
        SUM(competition_points.placement_points)
          FILTER (WHERE competition_points.placement_status = 'PROJECTED'),
        0
      ) AS projected_placement_points,
      COUNT(*) FILTER (
        WHERE competition_points.placement_status = 'CONFIRMED'
      )::INTEGER AS confirmed_competitions_count,
      COALESCE(
        BOOL_OR(competition_points.placement_status = 'PROJECTED'),
        false
      ) AS has_projected_placement_points,
      COALESCE(
        BOOL_OR(
          competition_points.placement_status = 'PENDING_TIE_BREAK'
          OR competition_points.has_pending_tie_break
        ),
        false
      ) AS has_competition_pending_tie_break
    FROM competition_points
    GROUP BY competition_points.team_id
  ), opening_totals AS (
    SELECT
      adjustments_table.team_id,
      COALESCE(SUM(adjustments_table.points), 0) AS opening_bonus_points
    FROM public.championship_overall_score_adjustments AS adjustments_table
    WHERE adjustments_table.championship_id = _championship_id
      AND adjustments_table.season_year = _season_year
      AND adjustments_table.adjustment_type = 'OPENING_CEREMONY'
    GROUP BY adjustments_table.team_id
  ), walkover_totals AS (
    SELECT
      counts_table.team_id,
      SUM(counts_table.walkover_count)::INTEGER AS walkover_count,
      COALESCE(SUM(counts_table.walkover_count * settings_table.points), 0) AS walkover_penalty_points
    FROM public.championship_walkover_penalty_counts AS counts_table
    JOIN public.championship_walkover_penalty_settings AS settings_table
      ON settings_table.championship_id = counts_table.championship_id
      AND settings_table.season_year = counts_table.season_year
    WHERE counts_table.championship_id = _championship_id
      AND counts_table.season_year = _season_year
    GROUP BY counts_table.team_id
  ), totals AS (
    SELECT
      teams_table.id AS team_id,
      teams_table.name AS team_name,
      COALESCE(placement_totals.placement_points, 0) AS placement_points,
      COALESCE(placement_totals.confirmed_placement_points, 0) AS confirmed_placement_points,
      COALESCE(placement_totals.projected_placement_points, 0) AS projected_placement_points,
      COALESCE(opening_totals.opening_bonus_points, 0) AS opening_bonus_points,
      COALESCE(walkover_totals.walkover_count, 0)::INTEGER AS walkover_count,
      COALESCE(walkover_totals.walkover_penalty_points, 0) AS walkover_penalty_points,
      COALESCE(placement_totals.placement_points, 0)
        + COALESCE(opening_totals.opening_bonus_points, 0)
        - COALESCE(walkover_totals.walkover_penalty_points, 0) AS overall_points,
      COALESCE(placement_totals.confirmed_competitions_count, 0) AS confirmed_competitions_count,
      COALESCE(placement_totals.has_projected_placement_points, false) AS has_projected_placement_points,
      COALESCE(placement_totals.has_competition_pending_tie_break, false) AS has_competition_pending_tie_break
    FROM participating_teams
    JOIN public.teams AS teams_table ON teams_table.id = participating_teams.team_id
    LEFT JOIN placement_totals ON placement_totals.team_id = teams_table.id
    LEFT JOIN opening_totals ON opening_totals.team_id = teams_table.id
    LEFT JOIN walkover_totals ON walkover_totals.team_id = teams_table.id
    WHERE teams_table.is_active IS DISTINCT FROM false
  ), tie_groups AS (
    SELECT totals_table.overall_points
    FROM totals AS totals_table
    WHERE totals_table.overall_points > 0
    GROUP BY totals_table.overall_points
    HAVING COUNT(*) > 1
  ), resolved_ties AS (
    SELECT
      resolutions_table.points_total,
      resolution_teams_table.team_id,
      resolution_teams_table.draw_order
    FROM public.championship_overall_tie_break_resolutions AS resolutions_table
    JOIN public.championship_overall_tie_break_resolution_teams AS resolution_teams_table
      ON resolution_teams_table.resolution_id = resolutions_table.id
    WHERE resolutions_table.championship_id = _championship_id
      AND resolutions_table.season_year = _season_year
  )
  SELECT
    totals.team_id,
    totals.team_name,
    totals.placement_points,
    totals.confirmed_placement_points,
    totals.projected_placement_points,
    totals.opening_bonus_points,
    totals.walkover_count,
    totals.walkover_penalty_points,
    totals.overall_points,
    totals.confirmed_competitions_count,
    totals.has_projected_placement_points,
    totals.has_competition_pending_tie_break
      OR EXISTS (
        SELECT 1
        FROM tie_groups
        WHERE tie_groups.overall_points = totals.overall_points
          AND NOT EXISTS (
            SELECT 1
            FROM resolved_ties
            WHERE resolved_ties.points_total = totals.overall_points
              AND resolved_ties.team_id = totals.team_id
          )
      ) AS has_pending_tie_break
  FROM totals
  LEFT JOIN resolved_ties
    ON resolved_ties.team_id = totals.team_id
    AND resolved_ties.points_total = totals.overall_points
  ORDER BY totals.overall_points DESC, resolved_ties.draw_order ASC NULLS LAST, totals.team_name ASC;
$function$;

-- Supabase source RPC: list_championship_competition_team_disqualifications
CREATE OR REPLACE FUNCTION public.list_championship_competition_team_disqualifications(_championship_id uuid, _season_year integer DEFAULT NULL::integer)
 RETURNS SETOF championship_competition_team_disqualifications
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '2s'
AS $function$
  WITH resolved_season AS (
    SELECT COALESCE(_season_year, championships_table.current_season_year) AS season_year
    FROM public.championships AS championships_table
    WHERE championships_table.id = _championship_id
    LIMIT 1
  )
  SELECT disqualifications_table.*
  FROM public.championship_competition_team_disqualifications AS disqualifications_table
  JOIN resolved_season
    ON resolved_season.season_year = disqualifications_table.season_year
  WHERE disqualifications_table.championship_id = _championship_id
  ORDER BY disqualifications_table.sport_id, disqualifications_table.naipe, disqualifications_table.division, disqualifications_table.created_at;
$function$;

SET check_function_bodies = on;
