CREATE OR REPLACE FUNCTION public.get_championship_bracket_competition_qualification_pool_ranking(_championship_id uuid, _competition_id uuid)
RETURNS TABLE(competition_id uuid, team_id uuid, team_name text, qualification_rank integer, points bigint, wins bigint, goal_diff bigint, goals_for bigint, pool_rank integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  is_interlaje_volleyball BOOLEAN;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.championship_bracket_competitions AS competitions_table
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    JOIN public.championships AS championships_table
      ON championships_table.id = editions_table.championship_id
    JOIN public.sports AS sports_table
      ON sports_table.id = competitions_table.sport_id
    WHERE competitions_table.id = _competition_id
      AND championships_table.id = _championship_id
      AND championships_table.code = 'INTERLAJE'::public.championship_code
      AND public.normalize_sport_name(sports_table.name) = 'voleibol'
  )
  INTO is_interlaje_volleyball;

  IF is_interlaje_volleyball THEN
    RETURN QUERY
    SELECT *
    FROM public.get_interlaje_volleyball_cross_group_ranking(
      _championship_id,
      _competition_id
    );
    RETURN;
  END IF;

  RETURN QUERY
  SELECT *
  FROM public.get_interlaje_qualification_pool_ranking_legacy(
    _championship_id,
    _competition_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_championship_bracket_qualification_pool_rankings(
  _championship_id uuid,
  _competition_id uuid
)
RETURNS TABLE(
  competition_id uuid,
  team_id uuid,
  team_name text,
  qualification_rank integer,
  points bigint,
  wins bigint,
  goal_diff bigint,
  goals_for bigint,
  pool_rank integer
)
LANGUAGE sql STABLE
SET search_path TO 'public'
AS $function$
  SELECT *
  FROM public.get_championship_bracket_competition_qualification_pool_ranking(
    _championship_id,
    _competition_id
  );
$function$;

DO $migration$
DECLARE
  function_record RECORD;
  old_helper_name CONSTANT text := 'get_championship_bracket_competition_qualification_pool_rankings(';
  new_helper_name CONSTANT text := 'get_championship_bracket_qualification_pool_rankings(';
BEGIN
  FOR function_record IN
    SELECT routines_table.oid
    FROM pg_catalog.pg_proc AS routines_table
    JOIN pg_catalog.pg_namespace AS namespaces_table
      ON namespaces_table.oid = routines_table.pronamespace
    WHERE namespaces_table.nspname = 'public'
      AND routines_table.prokind = 'f'
      AND strpos(pg_catalog.pg_get_functiondef(routines_table.oid), old_helper_name) > 0
  LOOP
    EXECUTE replace(
      pg_catalog.pg_get_functiondef(function_record.oid),
      old_helper_name,
      new_helper_name
    );
  END LOOP;
END;
$migration$;
