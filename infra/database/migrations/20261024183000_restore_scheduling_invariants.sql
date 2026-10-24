-- LAJE-150 restore schedule validation with support for AWS draft group generation.
-- Unscheduled draft group matches are permitted until their slots are assigned.
-- Business rules otherwise match the legacy Supabase function behavior.

CREATE OR REPLACE FUNCTION public.normalize_bracket_entity_name(_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT lower(trim(regexp_replace(COALESCE(_value, ''), '\s+', ' ', 'g')));
$function$;

CREATE OR REPLACE FUNCTION public.is_championship_team_rest_gap_conflict(_candidate_naipe match_naipe, _other_naipe match_naipe, _same_court boolean, _candidate_court_position bigint, _other_court_position bigint, _candidate_start_at timestamp with time zone, _other_start_at timestamp with time zone, _candidate_duration_minutes integer, _other_duration_minutes integer, _candidate_is_knockout boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  SELECT CASE
    WHEN COALESCE(_candidate_is_knockout, false) THEN false
    WHEN _candidate_naipe IS NULL
      OR _other_naipe IS NULL
      OR _candidate_naipe IS DISTINCT FROM _other_naipe
    THEN false
    WHEN COALESCE(_same_court, false) THEN
      _candidate_court_position IS NOT NULL
      AND _other_court_position IS NOT NULL
      AND abs(_candidate_court_position - _other_court_position) < 4
    ELSE
      _candidate_start_at IS NOT NULL
      AND _other_start_at IS NOT NULL
      AND abs(extract(epoch FROM (_other_start_at - _candidate_start_at)) / 60.0)
        < greatest(
          greatest(COALESCE(_candidate_duration_minutes, 35), 1),
          greatest(COALESCE(_other_duration_minutes, 35), 1)
        ) * 4
  END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_scheduled_match_rest_gap_conflict(_championship_id uuid, _season_year integer, _scheduled_date date, _location text, _court_name text, _start_time timestamp with time zone, _scheduled_slot integer, _queue_position integer, _created_at timestamp with time zone, _match_id uuid, _sport_id uuid, _naipe match_naipe, _home_team_id uuid, _away_team_id uuid, _duration_minutes integer DEFAULT NULL::integer)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  candidate_match_id UUID := COALESCE(
    _match_id,
    '00000000-0000-0000-0000-000000000000'::uuid
  );
  candidate_duration_minutes INTEGER;
  conflict_same_court BOOLEAN := false;
  conflict_cross_court BOOLEAN := false;
BEGIN
  IF _championship_id IS NULL
    OR _season_year IS NULL
    OR _scheduled_date IS NULL
    OR _sport_id IS NULL
    OR _naipe IS NULL
    OR NULLIF(trim(COALESCE(_location, '')), '') IS NULL
    OR NULLIF(trim(COALESCE(_court_name, '')), '') IS NULL
    OR _home_team_id IS NULL
    OR _away_team_id IS NULL
  THEN
    RETURN NULL;
  END IF;

  SELECT greatest(
    COALESCE(
      _duration_minutes,
      (
        SELECT championship_sports_table.default_match_duration_minutes
        FROM public.championship_sports AS championship_sports_table
        WHERE championship_sports_table.championship_id = _championship_id
          AND championship_sports_table.sport_id = _sport_id
        LIMIT 1
      ),
      35
    ),
    1
  )
  INTO candidate_duration_minutes;

  WITH simulated_matches AS (
    SELECT
      matches_table.id,
      matches_table.location,
      matches_table.court_name,
      matches_table.start_time,
      matches_table.scheduled_slot,
      matches_table.queue_position,
      matches_table.created_at,
      matches_table.naipe,
      matches_table.home_team_id,
      matches_table.away_team_id,
      greatest(
        COALESCE(championship_sports_table.default_match_duration_minutes, 35),
        1
      ) AS duration_minutes,
      COALESCE(bracket_matches_table.group_id IS NULL, false) AS is_knockout
    FROM public.matches AS matches_table
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = matches_table.championship_id
      AND championship_sports_table.sport_id = matches_table.sport_id
    LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.match_id = matches_table.id
    WHERE matches_table.championship_id = _championship_id
      AND matches_table.season_year = _season_year
      AND matches_table.status = 'SCHEDULED'::public.match_status
      AND matches_table.scheduled_date = _scheduled_date
      AND matches_table.id <> candidate_match_id

    UNION ALL

    SELECT
      candidate_match_id,
      _location,
      _court_name,
      _start_time,
      _scheduled_slot,
      _queue_position,
      COALESCE(_created_at, now()),
      _naipe,
      _home_team_id,
      _away_team_id,
      candidate_duration_minutes,
      COALESCE((
        SELECT bracket_matches_table.group_id IS NULL
        FROM public.championship_bracket_matches AS bracket_matches_table
        WHERE bracket_matches_table.match_id = candidate_match_id
        LIMIT 1
      ), false)
  ), ordered_court_matches AS (
    SELECT
      simulated_matches.*,
      row_number() OVER (
        ORDER BY
          CASE WHEN simulated_matches.start_time IS NULL THEN 1 ELSE 0 END,
          simulated_matches.start_time ASC NULLS LAST,
          COALESCE(simulated_matches.scheduled_slot, simulated_matches.queue_position) ASC NULLS LAST,
          COALESCE(simulated_matches.queue_position, simulated_matches.scheduled_slot) ASC NULLS LAST,
          simulated_matches.created_at ASC,
          simulated_matches.id ASC
      ) AS court_sequence_index
    FROM simulated_matches
    WHERE public.normalize_bracket_entity_name(simulated_matches.location) =
      public.normalize_bracket_entity_name(_location)
      AND public.normalize_bracket_entity_name(simulated_matches.court_name) =
        public.normalize_bracket_entity_name(_court_name)
  ), candidate_match AS (
    SELECT simulated_matches.*
    FROM simulated_matches
    WHERE simulated_matches.id = candidate_match_id
    LIMIT 1
  ), candidate_court_match AS (
    SELECT ordered_court_matches.*
    FROM ordered_court_matches
    WHERE ordered_court_matches.id = candidate_match_id
    LIMIT 1
  )
  SELECT
    EXISTS (
      SELECT 1
      FROM candidate_court_match
      JOIN ordered_court_matches AS other_match
        ON other_match.id <> candidate_court_match.id
      WHERE (
        other_match.home_team_id IN (
          candidate_court_match.home_team_id,
          candidate_court_match.away_team_id
        )
        OR other_match.away_team_id IN (
          candidate_court_match.home_team_id,
          candidate_court_match.away_team_id
        )
      )
      AND public.is_championship_team_rest_gap_conflict(
        candidate_court_match.naipe,
        other_match.naipe,
        true,
        candidate_court_match.court_sequence_index,
        other_match.court_sequence_index,
        candidate_court_match.start_time,
        other_match.start_time,
        candidate_court_match.duration_minutes,
        other_match.duration_minutes,
        candidate_court_match.is_knockout
      )
    ),
    EXISTS (
      SELECT 1
      FROM candidate_match
      JOIN simulated_matches AS other_match
        ON other_match.id <> candidate_match.id
      WHERE (
        public.normalize_bracket_entity_name(candidate_match.location) <>
          public.normalize_bracket_entity_name(other_match.location)
        OR public.normalize_bracket_entity_name(candidate_match.court_name) <>
          public.normalize_bracket_entity_name(other_match.court_name)
      )
      AND (
        other_match.home_team_id IN (
          candidate_match.home_team_id,
          candidate_match.away_team_id
        )
        OR other_match.away_team_id IN (
          candidate_match.home_team_id,
          candidate_match.away_team_id
        )
      )
      AND public.is_championship_team_rest_gap_conflict(
        candidate_match.naipe,
        other_match.naipe,
        false,
        NULL,
        NULL,
        candidate_match.start_time,
        other_match.start_time,
        candidate_match.duration_minutes,
        other_match.duration_minutes,
        candidate_match.is_knockout
      )
    )
  INTO conflict_same_court, conflict_cross_court;

  IF conflict_same_court THEN
    RETURN 'A mesma atlética só pode voltar a jogar no mesmo naipe a partir da quarta posição seguinte da quadra (ex.: jogo 1 → jogo 5).';
  END IF;

  IF conflict_cross_court THEN
    RETURN 'A mesma atlética precisa do intervalo equivalente a quatro jogos antes de voltar a jogar no mesmo naipe em outra quadra.';
  END IF;

  RETURN NULL;
END;
$function$;

CREATE OR REPLACE FUNCTION public.validate_match_conflict()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  available_courts_count INTEGER;
  live_matches_count INTEGER;
  latest_bracket_edition_id UUID;
  should_validate_live_capacity BOOLEAN := false;
  rest_gap_conflict_message TEXT;
  is_penalty_shootout_knockout_match BOOLEAN := false;
  penalty_shootout_tie_breaker_rule public.championship_sport_tie_breaker_rule;
  should_apply_penalty_shootout BOOLEAN := false;
BEGIN
  IF current_setting('app.skip_match_conflict_trigger', TRUE) = 'true' THEN
    RETURN NEW;
  END IF;

  IF NEW.home_team_id = NEW.away_team_id THEN
    RAISE EXCEPTION 'Os times da partida devem ser diferentes.';
  END IF;

  -- A newly generated group match can lack its date until the AWS preview assigns a slot.
  IF NEW.status = 'SCHEDULED'::public.match_status
    AND (NEW.queue_position IS NOT NULL OR NEW.scheduled_slot IS NOT NULL OR NEW.court_name IS NOT NULL)
  THEN
    IF NEW.scheduled_date IS NULL THEN
      RAISE EXCEPTION 'Informe o dia da fila para partidas agendadas.';
    END IF;
  END IF;

  IF NEW.status = 'LIVE'::public.match_status AND NEW.scheduled_date IS NOT NULL THEN
    IF TG_OP = 'INSERT' THEN
      should_validate_live_capacity := true;
    ELSIF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
      should_validate_live_capacity := true;
    END IF;
  END IF;

  IF should_validate_live_capacity THEN
    SELECT editions_table.id
    INTO latest_bracket_edition_id
    FROM public.championship_bracket_editions AS editions_table
    WHERE editions_table.championship_id = NEW.championship_id
      AND editions_table.season_year = NEW.season_year
    ORDER BY editions_table.created_at DESC
    LIMIT 1;

    IF latest_bracket_edition_id IS NOT NULL THEN
      SELECT count(*)
      INTO available_courts_count
      FROM public.championship_bracket_days AS days_table
      JOIN public.championship_bracket_locations AS locations_table
        ON locations_table.bracket_day_id = days_table.id
      JOIN public.championship_bracket_courts AS courts_table
        ON courts_table.bracket_location_id = locations_table.id
      JOIN public.championship_bracket_court_sports AS court_sports_table
        ON court_sports_table.bracket_court_id = courts_table.id
      WHERE days_table.bracket_edition_id = latest_bracket_edition_id
        AND days_table.event_date = NEW.scheduled_date
        AND court_sports_table.sport_id = NEW.sport_id;

      IF COALESCE(available_courts_count, 0) > 0 THEN
        SELECT count(*)
        INTO live_matches_count
        FROM public.matches AS matches_table
        WHERE matches_table.championship_id = NEW.championship_id
          AND matches_table.season_year = NEW.season_year
          AND matches_table.sport_id = NEW.sport_id
          AND matches_table.status = 'LIVE'::public.match_status
          AND matches_table.scheduled_date IS NOT DISTINCT FROM NEW.scheduled_date
          AND matches_table.id != COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid);

        IF live_matches_count >= available_courts_count THEN
          RAISE EXCEPTION 'Todas as quadras compatíveis desta modalidade já estão ocupadas neste dia.';
        END IF;
      END IF;
    END IF;
  END IF;

  IF NEW.status = 'SCHEDULED'::public.match_status
    AND NEW.court_name IS NOT NULL
    AND NULLIF(trim(COALESCE(NEW.location, '')), '') IS NOT NULL
    AND NULLIF(trim(COALESCE(NEW.court_name, '')), '') IS NOT NULL THEN
    rest_gap_conflict_message := public.resolve_scheduled_match_rest_gap_conflict(
      NEW.championship_id,
      NEW.season_year,
      NEW.scheduled_date,
      NEW.location,
      NEW.court_name,
      NEW.start_time,
      NEW.scheduled_slot,
      NEW.queue_position,
      NEW.created_at,
      NEW.id,
      NEW.sport_id,
      NEW.naipe,
      NEW.home_team_id,
      NEW.away_team_id
    );

    IF rest_gap_conflict_message IS NOT NULL THEN
      RAISE EXCEPTION '%', rest_gap_conflict_message;
    END IF;
  END IF;

  IF (NEW.home_penalty_score IS NOT NULL AND NEW.home_penalty_score < 0)
    OR (NEW.away_penalty_score IS NOT NULL AND NEW.away_penalty_score < 0) THEN
    RAISE EXCEPTION 'O placar de pênaltis não pode ser negativo.';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.sports AS sports_table
      ON sports_table.id = NEW.sport_id
    WHERE bracket_matches_table.match_id = NEW.id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND sports_table.code IN ('FUTEBOL_SOCIETY', 'BEACH_SOCCER', 'FUTSAL')
  )
  INTO is_penalty_shootout_knockout_match;

  SELECT championship_sports_table.tie_breaker_rule
  INTO penalty_shootout_tie_breaker_rule
  FROM public.championship_sports AS championship_sports_table
  WHERE championship_sports_table.championship_id = NEW.championship_id
    AND championship_sports_table.sport_id = NEW.sport_id
  LIMIT 1;

  should_apply_penalty_shootout := (
    NEW.status = 'FINISHED'::public.match_status
    AND COALESCE(NEW.is_walkover, false) = false
    AND COALESCE(NEW.is_double_walkover, false) = false
    AND is_penalty_shootout_knockout_match
    AND NEW.home_score = NEW.away_score
  );

  IF should_apply_penalty_shootout THEN
    IF NEW.home_penalty_score IS NULL OR NEW.away_penalty_score IS NULL THEN
      RAISE EXCEPTION 'Jogos empatados do mata-mata desta modalidade exigem o placar dos pênaltis.';
    END IF;

    IF NEW.home_penalty_score = NEW.away_penalty_score THEN
      RAISE EXCEPTION 'O placar dos pênaltis precisa definir um vencedor.';
    END IF;

    NEW.resolved_tie_breaker_rule := COALESCE(penalty_shootout_tie_breaker_rule, 'FUTEBOL_SOCIETY'::public.championship_sport_tie_breaker_rule);
    NEW.resolved_tie_break_winner_team_id := CASE
      WHEN NEW.home_penalty_score > NEW.away_penalty_score THEN NEW.home_team_id
      ELSE NEW.away_team_id
    END;
  ELSIF NEW.status = 'LIVE'::public.match_status
    AND COALESCE(NEW.is_walkover, false) = false
    AND COALESCE(NEW.is_double_walkover, false) = false
    AND is_penalty_shootout_knockout_match
    AND NEW.home_score = NEW.away_score THEN
    NEW.resolved_tie_breaker_rule := NULL;
    NEW.resolved_tie_break_winner_team_id := NULL;
  ELSE
    NEW.home_penalty_score := NULL;
    NEW.away_penalty_score := NULL;

    IF NEW.resolved_tie_breaker_rule = penalty_shootout_tie_breaker_rule THEN
      NEW.resolved_tie_breaker_rule := NULL;
    END IF;

    IF NEW.resolved_tie_breaker_rule IS NULL THEN
      NEW.resolved_tie_break_winner_team_id := NULL;
    END IF;
  END IF;

  IF NEW.resolved_tie_break_winner_team_id IS NOT NULL
    AND NEW.resolved_tie_break_winner_team_id != NEW.home_team_id
    AND NEW.resolved_tie_break_winner_team_id != NEW.away_team_id THEN
    RAISE EXCEPTION 'O vencedor do desempate deve ser um dos times da partida.';
  END IF;

  IF NEW.end_time IS NOT NULL AND NEW.start_time IS NULL THEN
    RAISE EXCEPTION 'A partida não pode ter horário final sem horário inicial.';
  END IF;

  IF NEW.start_time IS NOT NULL
    AND NEW.end_time IS NOT NULL
    AND NEW.end_time <= NEW.start_time THEN
    RAISE EXCEPTION 'Horário final da partida deve ser maior que o horário inicial.';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS check_match_conflict ON public.matches;
CREATE TRIGGER check_match_conflict BEFORE INSERT OR UPDATE ON public.matches FOR EACH ROW EXECUTE FUNCTION public.validate_match_conflict();
