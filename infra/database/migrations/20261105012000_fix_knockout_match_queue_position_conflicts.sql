CREATE OR REPLACE FUNCTION public.create_championship_knockout_match_schedule(_championship_id uuid, _bracket_match_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  bracket_match_record RECORD;
  new_match_id UUID;
  resolved_queue_position INTEGER;
BEGIN
  SELECT
    bracket_matches_table.id,
    bracket_matches_table.bracket_edition_id,
    bracket_matches_table.competition_id,
    bracket_matches_table.match_id,
    bracket_matches_table.home_team_id,
    bracket_matches_table.away_team_id,
    bracket_matches_table.round_number,
    bracket_matches_table.slot_number,
    bracket_matches_table.is_third_place,
    bracket_matches_table.planned_scheduled_date,
    bracket_matches_table.planned_scheduled_slot,
    bracket_matches_table.planned_queue_position,
    bracket_matches_table.planned_start_time,
    bracket_matches_table.planned_end_time,
    bracket_matches_table.planned_location_name,
    bracket_matches_table.planned_court_name,
    competitions_table.division,
    competitions_table.naipe,
    competitions_table.sport_id,
    editions_table.season_year,
    editions_table.championship_id,
    editions_table.payload_snapshot ->> 'exact_preview_algorithm_version'
      AS exact_preview_algorithm_version
  INTO bracket_match_record
  FROM public.championship_bracket_matches AS bracket_matches_table
  JOIN public.championship_bracket_competitions AS competitions_table
    ON competitions_table.id = bracket_matches_table.competition_id
  JOIN public.championship_bracket_editions AS editions_table
    ON editions_table.id = bracket_matches_table.bracket_edition_id
  WHERE bracket_matches_table.id = _bracket_match_id
  LIMIT 1;

  IF bracket_match_record.id IS NULL THEN
    RETURN NULL;
  END IF;

  IF bracket_match_record.exact_preview_algorithm_version
    IS DISTINCT FROM 'async-exact-v8'
  THEN
    RAISE EXCEPTION 'A API AWS LAJE-150 suporta apenas o mata-mata criado pela prévia exata v8.';
  END IF;

  IF bracket_match_record.championship_id <> _championship_id THEN
    RAISE EXCEPTION
      'A partida eliminatória % não pertence ao campeonato informado.',
      _bracket_match_id;
  END IF;

  IF bracket_match_record.match_id IS NOT NULL THEN
    RETURN bracket_match_record.match_id;
  END IF;

  IF bracket_match_record.home_team_id IS NULL
    OR bracket_match_record.away_team_id IS NULL
  THEN
    RETURN NULL;
  END IF;

  IF bracket_match_record.planned_scheduled_date IS NULL
    OR bracket_match_record.planned_scheduled_slot IS NULL
    OR bracket_match_record.planned_queue_position IS NULL
    OR bracket_match_record.planned_start_time IS NULL
    OR bracket_match_record.planned_end_time IS NULL
    OR bracket_match_record.planned_location_name IS NULL
    OR bracket_match_record.planned_court_name IS NULL
  THEN
    RAISE EXCEPTION
      'A partida eliminatória v8 % não possui programação estrutural completa.',
      _bracket_match_id;
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      format(
        '%s:%s:%s:%s:%s:%s',
        _championship_id,
        bracket_match_record.season_year,
        bracket_match_record.planned_scheduled_date,
        bracket_match_record.sport_id,
        bracket_match_record.naipe,
        COALESCE(
          public.coerce_division_for_index(bracket_match_record.division),
          ''
        )
      ),
      0
    )
  );

  IF public.coerce_division_for_index(bracket_match_record.division) IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM public.matches AS matches_table
      WHERE matches_table.championship_id = _championship_id
        AND matches_table.season_year = bracket_match_record.season_year
        AND matches_table.scheduled_date = bracket_match_record.planned_scheduled_date
        AND matches_table.sport_id = bracket_match_record.sport_id
        AND matches_table.naipe = bracket_match_record.naipe
        AND public.coerce_division_for_index(matches_table.division)
          IS NOT DISTINCT FROM
            public.coerce_division_for_index(bracket_match_record.division)
        AND matches_table.queue_position = bracket_match_record.planned_queue_position
    )
  THEN
    resolved_queue_position := bracket_match_record.planned_queue_position;
  ELSE
    SELECT COALESCE(MAX(matches_table.queue_position), 0) + 1
    INTO resolved_queue_position
    FROM public.matches AS matches_table
    WHERE matches_table.championship_id = _championship_id
      AND matches_table.season_year = bracket_match_record.season_year
      AND matches_table.scheduled_date = bracket_match_record.planned_scheduled_date
      AND matches_table.sport_id = bracket_match_record.sport_id
      AND matches_table.naipe = bracket_match_record.naipe
      AND public.coerce_division_for_index(matches_table.division)
        IS NOT DISTINCT FROM
          public.coerce_division_for_index(bracket_match_record.division);
  END IF;

  PERFORM set_config('app.skip_queue_trigger', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  INSERT INTO public.matches (
    championship_id,
    division,
    naipe,
    sport_id,
    home_team_id,
    away_team_id,
    location,
    court_name,
    scheduled_date,
    queue_position,
    scheduled_slot,
    scheduled_start_time,
    start_time,
    end_time,
    season_year,
    status
  )
  VALUES (
    _championship_id,
    bracket_match_record.division,
    bracket_match_record.naipe,
    bracket_match_record.sport_id,
    bracket_match_record.home_team_id,
    bracket_match_record.away_team_id,
    bracket_match_record.planned_location_name,
    bracket_match_record.planned_court_name,
    bracket_match_record.planned_scheduled_date,
    resolved_queue_position,
    bracket_match_record.planned_scheduled_slot,
    public.combine_bracket_schedule_timestamp(
      bracket_match_record.planned_scheduled_date,
      bracket_match_record.planned_start_time
    ),
    public.combine_bracket_schedule_timestamp(
      bracket_match_record.planned_scheduled_date,
      bracket_match_record.planned_start_time
    ),
    public.combine_bracket_schedule_timestamp(
      bracket_match_record.planned_scheduled_date,
      bracket_match_record.planned_end_time
    ),
    bracket_match_record.season_year,
    'SCHEDULED'::public.match_status
  )
  RETURNING id
  INTO new_match_id;

  UPDATE public.championship_bracket_matches
  SET
    match_id = new_match_id,
    planned_queue_position = resolved_queue_position
  WHERE id = _bracket_match_id;

  UPDATE public.championship_bracket_knockout_schedule_reservations
  SET queue_position = resolved_queue_position
  WHERE bracket_edition_id = bracket_match_record.bracket_edition_id
    AND competition_id = bracket_match_record.competition_id
    AND round_number = bracket_match_record.round_number
    AND slot_number = bracket_match_record.slot_number
    AND is_third_place = bracket_match_record.is_third_place;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  PERFORM set_config('app.skip_queue_trigger', 'false', true);

  RETURN new_match_id;
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.skip_queue_trigger', 'false', true);
    RAISE;
END;
$function$;
