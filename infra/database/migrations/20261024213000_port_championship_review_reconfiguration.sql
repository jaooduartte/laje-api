-- LAJE-150: AWS/RDS championship schedule review/reconfiguration.
-- Port only functions used by the active AdminChampionshipSchedule workflow.
-- Preserve original validation, preview subtransaction rollback and optimistic revision locking.
-- Deliberately omit Supabase privilege GRANTs (anon/authenticated) and PostgREST notifications.
-- JWT/RBAC is enforced in bracket-operations.routes.ts; SQL also checks auth.uid()
-- and has_admin_tab_access, using the existing AWS transaction-local identity adapter.
-- Source migrations remain untouched. This migration does not directly update championship records.

ALTER TABLE public.championship_bracket_court_sports
  DROP CONSTRAINT IF EXISTS
    championship_bracket_court_sports_sequence_mode_preferences_check;

ALTER TABLE public.championship_bracket_court_sports
  ADD CONSTRAINT
    championship_bracket_court_sports_sequence_mode_preferences_check
  CHECK (
    sequence_mode =
      'FLEXIBLE'::public.bracket_court_sequence_mode

    OR (
      sequence_mode IN (
        'GROUP_NAIPE'::public.bracket_court_sequence_mode,
        'ALTERNATE_NAIPE'::public.bracket_court_sequence_mode
      )
      AND preferred_naipe IS NOT NULL
      AND preferred_division IS NULL
    )

    OR (
      sequence_mode =
        'GROUP_DIVISION'::public.bracket_court_sequence_mode
      AND preferred_division IS NOT NULL
      AND preferred_naipe IS NULL
    )
  );

-- ============================================================
-- 2. Permite que uma reprogramação explícita ignore
--    temporariamente o snapshot da etapa 11
-- ============================================================

CREATE OR REPLACE FUNCTION
  public.sync_bracket_court_sequence_mode_from_payload()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  resolved_payload JSONB;
  resolved_event_date DATE;
  resolved_location_name TEXT;
  resolved_court_name TEXT;

  configured_preference JSONB;
  configured_preferred_sport_id UUID;
  configured_sequence_mode TEXT;
  configured_preferred_naipe TEXT;
  configured_preferred_division TEXT;
BEGIN
  /*
   * Alterações normais continuam protegidas pelo payload_snapshot.
   *
   * Somente a RPC de reprogramação pode ativar este flag dentro
   * da própria transação.
   */
  IF current_setting(
    'app.allow_court_sequence_reprogramming',
    true
  ) = 'true'
  THEN
    RETURN NEW;
  END IF;

  SELECT
    editions_table.payload_snapshot,
    days_table.event_date,
    locations_table.name,
    courts_table.name
  INTO
    resolved_payload,
    resolved_event_date,
    resolved_location_name,
    resolved_court_name
  FROM public.championship_bracket_courts
    AS courts_table
  JOIN public.championship_bracket_locations
    AS locations_table
    ON locations_table.id =
      courts_table.bracket_location_id
  JOIN public.championship_bracket_days
    AS days_table
    ON days_table.id =
      locations_table.bracket_day_id
  JOIN public.championship_bracket_editions
    AS editions_table
    ON editions_table.id =
      days_table.bracket_edition_id
  WHERE courts_table.id =
    NEW.bracket_court_id
  LIMIT 1;

  NEW.alternate_naipe_after_exclusive_knockout_phase :=
    false;

  IF resolved_payload IS NULL
    OR resolved_event_date IS NULL
  THEN
    NEW.sequence_mode :=
      'FLEXIBLE'::public.bracket_court_sequence_mode;

    RETURN NEW;
  END IF;

  configured_preference := NULL;

  SELECT
    court_configuration.value
      -> 'sport_preference'
  INTO configured_preference
  FROM jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(
        resolved_payload -> 'schedule_days'
      ) = 'array'
      THEN resolved_payload -> 'schedule_days'
      ELSE '[]'::jsonb
    END
  ) AS day_configuration(value)

  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(
        day_configuration.value -> 'locations'
      ) = 'array'
      THEN day_configuration.value -> 'locations'
      ELSE '[]'::jsonb
    END
  ) AS location_configuration(value)

  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(
        location_configuration.value -> 'courts'
      ) = 'array'
      THEN location_configuration.value -> 'courts'
      ELSE '[]'::jsonb
    END
  ) AS court_configuration(value)

  WHERE
    day_configuration.value ->> 'date' =
      resolved_event_date::text

    AND public.normalize_bracket_entity_name(
      location_configuration.value ->> 'name'
    ) =
      public.normalize_bracket_entity_name(
        resolved_location_name
      )

    AND public.normalize_bracket_entity_name(
      court_configuration.value ->> 'name'
    ) =
      public.normalize_bracket_entity_name(
        resolved_court_name
      )

  LIMIT 1;

  IF jsonb_typeof(configured_preference)
    IS DISTINCT FROM 'object'
  THEN
    NEW.sequence_mode :=
      'FLEXIBLE'::public.bracket_court_sequence_mode;

    RETURN NEW;
  END IF;

  configured_preferred_sport_id := CASE
    WHEN NULLIF(
      trim(
        COALESCE(
          configured_preference
            ->> 'preferred_sport_id',
          ''
        )
      ),
      ''
    ) IS NULL
    THEN NULL

    ELSE (
      configured_preference
        ->> 'preferred_sport_id'
    )::uuid
  END;

  IF configured_preferred_sport_id
    IS DISTINCT FROM NEW.sport_id
  THEN
    NEW.sequence_mode :=
      'FLEXIBLE'::public.bracket_court_sequence_mode;

    RETURN NEW;
  END IF;

  configured_sequence_mode := upper(
    trim(
      COALESCE(
        configured_preference
          ->> 'sequence_mode',
        'FLEXIBLE'
      )
    )
  );

  configured_preferred_naipe := NULLIF(
    trim(
      COALESCE(
        configured_preference
          ->> 'preferred_naipe',
        ''
      )
    ),
    ''
  );

  configured_preferred_division := NULLIF(
    trim(
      COALESCE(
        configured_preference
          ->> 'preferred_division',
        ''
      )
    ),
    ''
  );

  IF configured_sequence_mode = 'GROUP_NAIPE'
    AND configured_preferred_naipe IN (
      'FEMININO',
      'MASCULINO',
      'MISTO'
    )
  THEN
    NEW.sequence_mode :=
      'GROUP_NAIPE'
        ::public.bracket_court_sequence_mode;

    NEW.preferred_naipe :=
      configured_preferred_naipe
        ::public.match_naipe;

    NEW.preferred_division := NULL;

    NEW.alternate_naipe_after_exclusive_knockout_phase :=
      COALESCE(
        (
          configured_preference
            ->> 'alternate_naipe_after_exclusive_knockout_phase'
        )::boolean,
        false
      );

  ELSIF configured_sequence_mode =
      'GROUP_DIVISION'
    AND configured_preferred_division IN (
      'DIVISAO_PRINCIPAL',
      'DIVISAO_ACESSO'
    )
  THEN
    NEW.sequence_mode :=
      'GROUP_DIVISION'
        ::public.bracket_court_sequence_mode;

    NEW.preferred_naipe := NULL;

    NEW.preferred_division :=
      configured_preferred_division
        ::public.team_division;

  ELSE
    NEW.sequence_mode :=
      'FLEXIBLE'
        ::public.bracket_court_sequence_mode;
  END IF;

  RETURN NEW;
END;
$$;

-- ============================================================
-- 3. Reprogramming revision também observa court_sports
-- ============================================================


CREATE OR REPLACE FUNCTION public.reverse_championship_bracket_day_court_match_order(
  _bracket_edition_id UUID,
  _payload JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  championship_id_value UUID;
  season_year_value INTEGER;
  scheduled_date_value DATE;
  setup_payload JSONB;
  requested_court_count INTEGER;
  selected_court_count INTEGER;
  affected_match_count INTEGER;
  before_matches JSONB;
  after_matches JSONB;
BEGIN
  scheduled_date_value := NULLIF(_payload->>'scheduled_date', '')::date;

  IF scheduled_date_value IS NULL THEN
    RAISE EXCEPTION 'Informe a data para inverter a ordem dos jogos.';
  END IF;

  SELECT editions_table.championship_id, editions_table.season_year
  INTO championship_id_value, season_year_value
  FROM public.championship_bracket_editions AS editions_table
  WHERE editions_table.id = _bracket_edition_id
  FOR UPDATE;

  IF championship_id_value IS NULL THEN
    RAISE EXCEPTION 'Edição do chaveamento não encontrada.';
  END IF;

  CREATE TEMPORARY TABLE reverse_day_court_match_order_courts ON COMMIT DROP AS
  WITH requested_courts AS (
    SELECT DISTINCT value::uuid AS bracket_court_id
    FROM jsonb_array_elements_text(COALESCE(_payload->'bracket_court_ids', '[]'::jsonb))
  )
  SELECT
    courts_table.id AS bracket_court_id,
    locations_table.name AS location_name,
    courts_table.name AS court_name
  FROM requested_courts
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.id = requested_courts.bracket_court_id
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.id = courts_table.bracket_location_id
  JOIN public.championship_bracket_days AS days_table
    ON days_table.id = locations_table.bracket_day_id
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND days_table.event_date = scheduled_date_value;

  SELECT count(*) INTO requested_court_count
  FROM (
    SELECT DISTINCT value
    FROM jsonb_array_elements_text(COALESCE(_payload->'bracket_court_ids', '[]'::jsonb))
  ) AS requested_courts;

  SELECT count(*) INTO selected_court_count
  FROM reverse_day_court_match_order_courts;

  IF requested_court_count = 0 THEN
    RAISE EXCEPTION 'Selecione ao menos uma quadra para inverter a ordem dos jogos.';
  END IF;

  IF selected_court_count <> requested_court_count THEN
    RAISE EXCEPTION 'Uma ou mais quadras não pertencem à data selecionada da agenda.';
  END IF;

  PERFORM 1
  FROM public.matches AS matches_table
  WHERE matches_table.championship_id = championship_id_value
    AND matches_table.season_year = season_year_value
    AND matches_table.scheduled_date = scheduled_date_value
  FOR UPDATE;

  CREATE TEMPORARY TABLE reverse_day_court_match_order_slots ON COMMIT DROP AS
  WITH ordered_matches AS (
    SELECT
      matches_table.id,
      courts_table.bracket_court_id,
      matches_table.scheduled_date,
      matches_table.start_time,
      matches_table.end_time,
      matches_table.queue_position,
      matches_table.scheduled_slot,
      matches_table.global_queue_order,
      row_number() OVER (
        PARTITION BY courts_table.bracket_court_id
        ORDER BY
          matches_table.start_time ASC NULLS LAST,
          COALESCE(matches_table.scheduled_slot, matches_table.queue_position) ASC NULLS LAST,
          matches_table.global_queue_order ASC NULLS LAST,
          matches_table.created_at ASC,
          matches_table.id ASC
      ) AS sequence_position,
      count(*) OVER (PARTITION BY courts_table.bracket_court_id) AS sequence_length
    FROM public.matches AS matches_table
    JOIN reverse_day_court_match_order_courts AS courts_table
      ON public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(courts_table.location_name)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(courts_table.court_name)
    WHERE matches_table.championship_id = championship_id_value
      AND matches_table.season_year = season_year_value
      AND matches_table.scheduled_date = scheduled_date_value
      AND matches_table.status = 'SCHEDULED'::public.match_status
  )
  SELECT
    source_match.id AS source_match_id,
    target_match.id AS target_match_id,
    target_match.start_time AS target_start_time,
    target_match.end_time AS target_end_time,
    target_match.queue_position AS target_queue_position,
    target_match.scheduled_slot AS target_scheduled_slot,
    target_match.global_queue_order AS target_global_queue_order
  FROM ordered_matches AS source_match
  JOIN ordered_matches AS target_match
    ON target_match.bracket_court_id = source_match.bracket_court_id
    AND target_match.sequence_position = source_match.sequence_length - source_match.sequence_position + 1
  WHERE source_match.id <> target_match.id;

  SELECT count(*) INTO affected_match_count
  FROM reverse_day_court_match_order_slots;

  IF affected_match_count = 0 THEN
    RAISE EXCEPTION 'Não há ao menos dois jogos agendados nas quadras selecionadas para inverter.';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'match_id', matches_table.id,
    'scheduled_date', matches_table.scheduled_date,
    'start_time', matches_table.start_time,
    'end_time', matches_table.end_time,
    'queue_position', matches_table.queue_position,
    'scheduled_slot', matches_table.scheduled_slot,
    'global_queue_order', matches_table.global_queue_order
  ) ORDER BY matches_table.id), '[]'::jsonb)
  INTO before_matches
  FROM public.matches AS matches_table
  JOIN reverse_day_court_match_order_slots AS slots_table
    ON slots_table.source_match_id = matches_table.id;

  PERFORM set_config('app.skip_queue_trigger', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  BEGIN
    UPDATE public.matches AS matches_table
    SET
      start_time = matches_table.start_time + make_interval(days => 3650),
      end_time = CASE
        WHEN matches_table.end_time IS NULL THEN NULL
        ELSE matches_table.end_time + make_interval(days => 3650)
      END,
      queue_position = CASE
        WHEN matches_table.queue_position IS NULL THEN NULL
        ELSE matches_table.queue_position + 1000000
      END,
      scheduled_slot = CASE
        WHEN matches_table.scheduled_slot IS NULL THEN NULL
        ELSE matches_table.scheduled_slot + 1000000
      END,
      global_queue_order = CASE
        WHEN matches_table.global_queue_order IS NULL THEN NULL
        ELSE matches_table.global_queue_order + 1000000
      END
    FROM reverse_day_court_match_order_slots AS slots_table
    WHERE matches_table.id = slots_table.source_match_id;

    UPDATE public.matches AS matches_table
    SET
      start_time = slots_table.target_start_time,
      end_time = slots_table.target_end_time,
      queue_position = slots_table.target_queue_position,
      scheduled_slot = slots_table.target_scheduled_slot,
      global_queue_order = slots_table.target_global_queue_order
    FROM reverse_day_court_match_order_slots AS slots_table
    WHERE matches_table.id = slots_table.source_match_id;

    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.skip_queue_trigger', 'false', true);

    IF EXISTS (
      SELECT 1
      FROM public.matches AS matches_table
      JOIN reverse_day_court_match_order_slots AS slots_table
        ON slots_table.source_match_id = matches_table.id
      WHERE NOT EXISTS (
        SELECT 1
        FROM public.championship_bracket_days AS days_table
        JOIN public.championship_bracket_locations AS locations_table
          ON locations_table.bracket_day_id = days_table.id
        JOIN public.championship_bracket_courts AS courts_table
          ON courts_table.bracket_location_id = locations_table.id
        JOIN public.championship_bracket_court_sports AS court_sports_table
          ON court_sports_table.bracket_court_id = courts_table.id
        WHERE days_table.bracket_edition_id = _bracket_edition_id
          AND days_table.event_date = matches_table.scheduled_date
          AND court_sports_table.sport_id = matches_table.sport_id
          AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(matches_table.location)
          AND public.normalize_bracket_entity_name(courts_table.name) = public.normalize_bracket_entity_name(matches_table.court_name)
          AND matches_table.start_time >= make_timestamptz(
            EXTRACT(YEAR FROM days_table.event_date)::integer,
            EXTRACT(MONTH FROM days_table.event_date)::integer,
            EXTRACT(DAY FROM days_table.event_date)::integer,
            EXTRACT(HOUR FROM days_table.start_time)::integer,
            EXTRACT(MINUTE FROM days_table.start_time)::integer,
            0,
            'America/Sao_Paulo'
          )
          AND COALESCE(
            matches_table.end_time,
            matches_table.start_time + make_interval(mins => GREATEST(COALESCE(public.resolve_championship_sport_duration_minutes(matches_table.championship_id, matches_table.sport_id), 35), 1))
          ) <= make_timestamptz(
            EXTRACT(YEAR FROM days_table.event_date)::integer,
            EXTRACT(MONTH FROM days_table.event_date)::integer,
            EXTRACT(DAY FROM days_table.event_date)::integer,
            EXTRACT(HOUR FROM days_table.end_time)::integer,
            EXTRACT(MINUTE FROM days_table.end_time)::integer,
            0,
            'America/Sao_Paulo'
          )
          AND NOT EXISTS (
            SELECT 1
            FROM public.championship_bracket_day_breaks AS breaks_table
            WHERE breaks_table.bracket_day_id = days_table.id
              AND (
                breaks_table.scope_type = 'ALL_COURTS'
                OR (breaks_table.scope_type = 'COURT' AND breaks_table.bracket_court_id = courts_table.id)
              )
              AND matches_table.start_time < make_timestamptz(
                EXTRACT(YEAR FROM days_table.event_date)::integer,
                EXTRACT(MONTH FROM days_table.event_date)::integer,
                EXTRACT(DAY FROM days_table.event_date)::integer,
                EXTRACT(HOUR FROM breaks_table.break_end_time)::integer,
                EXTRACT(MINUTE FROM breaks_table.break_end_time)::integer,
                0,
                'America/Sao_Paulo'
              )
              AND COALESCE(
                matches_table.end_time,
                matches_table.start_time + make_interval(mins => GREATEST(COALESCE(public.resolve_championship_sport_duration_minutes(matches_table.championship_id, matches_table.sport_id), 35), 1))
              ) > make_timestamptz(
                EXTRACT(YEAR FROM days_table.event_date)::integer,
                EXTRACT(MONTH FROM days_table.event_date)::integer,
                EXTRACT(DAY FROM days_table.event_date)::integer,
                EXTRACT(HOUR FROM breaks_table.break_start_time)::integer,
                EXTRACT(MINUTE FROM breaks_table.break_start_time)::integer,
                0,
                'America/Sao_Paulo'
              )
          )
      )
    ) THEN
      RAISE EXCEPTION 'A inversão não respeita a agenda configurada para modalidade, quadra ou intervalo.';
    END IF;

    setup_payload := public.get_championship_setup_payload_snapshot(championship_id_value, season_year_value);

    IF setup_payload IS NOT NULL AND EXISTS (
      SELECT 1
      FROM public.matches AS matches_table
      JOIN reverse_day_court_match_order_slots AS slots_table
        ON slots_table.source_match_id = matches_table.id
      CROSS JOIN LATERAL (
        SELECT format(
          '%s::%s::%s',
          matches_table.sport_id,
          matches_table.naipe,
          COALESCE(matches_table.division::text, 'WITHOUT_DIVISION')
        ) AS competition_key
      ) AS competition_table
      WHERE NOT EXISTS (
        SELECT 1
        FROM public.resolve_championship_bracket_competition_schedule_windows(
          setup_payload,
          competition_table.competition_key,
          matches_table.scheduled_date
        ) AS windows_table
        WHERE matches_table.start_time >= windows_table.window_start_at
          AND COALESCE(
            matches_table.end_time,
            matches_table.start_time + make_interval(mins => GREATEST(COALESCE(public.resolve_championship_sport_duration_minutes(matches_table.championship_id, matches_table.sport_id), 35), 1))
          ) <= windows_table.window_end_at
      )
      OR NOT EXISTS (
        SELECT 1
        FROM public.resolve_championship_bracket_team_schedule_windows(
          setup_payload,
          matches_table.home_team_id,
          competition_table.competition_key,
          matches_table.scheduled_date
        ) AS windows_table
        WHERE matches_table.start_time >= windows_table.window_start_at
          AND COALESCE(
            matches_table.end_time,
            matches_table.start_time + make_interval(mins => GREATEST(COALESCE(public.resolve_championship_sport_duration_minutes(matches_table.championship_id, matches_table.sport_id), 35), 1))
          ) <= windows_table.window_end_at
      )
      OR NOT EXISTS (
        SELECT 1
        FROM public.resolve_championship_bracket_team_schedule_windows(
          setup_payload,
          matches_table.away_team_id,
          competition_table.competition_key,
          matches_table.scheduled_date
        ) AS windows_table
        WHERE matches_table.start_time >= windows_table.window_start_at
          AND COALESCE(
            matches_table.end_time,
            matches_table.start_time + make_interval(mins => GREATEST(COALESCE(public.resolve_championship_sport_duration_minutes(matches_table.championship_id, matches_table.sport_id), 35), 1))
          ) <= windows_table.window_end_at
      )
    ) THEN
      RAISE EXCEPTION 'A inversão não respeita a disponibilidade configurada da modalidade ou das atléticas.';
    END IF;

    IF EXISTS (
      WITH ordered_matches AS (
        SELECT
          matches_table.id,
          matches_table.scheduled_date,
          matches_table.location,
          matches_table.court_name,
          matches_table.sport_id,
          matches_table.naipe,
          matches_table.home_team_id,
          matches_table.away_team_id,
          matches_table.start_time,
          COALESCE(
            matches_table.end_time,
            matches_table.start_time + make_interval(mins => GREATEST(COALESCE(public.resolve_championship_sport_duration_minutes(matches_table.championship_id, matches_table.sport_id), 35), 1))
          ) AS end_time,
          row_number() OVER (
            PARTITION BY matches_table.scheduled_date, public.normalize_bracket_entity_name(matches_table.location), public.normalize_bracket_entity_name(matches_table.court_name)
            ORDER BY matches_table.start_time ASC NULLS LAST, COALESCE(matches_table.scheduled_slot, matches_table.queue_position) ASC NULLS LAST, matches_table.created_at ASC, matches_table.id ASC
          ) AS court_position,
          EXISTS (
            SELECT 1
            FROM public.championship_bracket_matches AS bracket_matches_table
            WHERE bracket_matches_table.match_id = matches_table.id
              AND bracket_matches_table.group_id IS NULL
          ) AS is_knockout
        FROM public.matches AS matches_table
        WHERE matches_table.championship_id = championship_id_value
          AND matches_table.season_year = season_year_value
          AND matches_table.status = 'SCHEDULED'::public.match_status
          AND matches_table.scheduled_date = scheduled_date_value
      )
      SELECT 1
      FROM ordered_matches AS first_match
      JOIN reverse_day_court_match_order_courts AS courts_table
        ON public.normalize_bracket_entity_name(first_match.location) = public.normalize_bracket_entity_name(courts_table.location_name)
        AND public.normalize_bracket_entity_name(first_match.court_name) = public.normalize_bracket_entity_name(courts_table.court_name)
      JOIN ordered_matches AS second_match
        ON second_match.id <> first_match.id
        AND second_match.scheduled_date = first_match.scheduled_date
        AND second_match.naipe = first_match.naipe
        AND (
          second_match.home_team_id IN (first_match.home_team_id, first_match.away_team_id)
          OR second_match.away_team_id IN (first_match.home_team_id, first_match.away_team_id)
        )
      WHERE NOT first_match.is_knockout
        AND (
          CASE
            WHEN public.normalize_bracket_entity_name(first_match.location) = public.normalize_bracket_entity_name(second_match.location)
              AND public.normalize_bracket_entity_name(first_match.court_name) = public.normalize_bracket_entity_name(second_match.court_name)
            THEN abs(first_match.court_position - second_match.court_position) < CASE WHEN first_match.sport_id = second_match.sport_id THEN 3 ELSE 2 END
            ELSE abs(EXTRACT(EPOCH FROM (second_match.start_time - first_match.start_time)) / 60.0)
              < GREATEST(
                EXTRACT(EPOCH FROM (first_match.end_time - first_match.start_time)) / 60.0,
                EXTRACT(EPOCH FROM (second_match.end_time - second_match.start_time)) / 60.0,
                1
              ) * CASE WHEN first_match.sport_id = second_match.sport_id THEN 3 ELSE 2 END
          END
        )
    ) THEN
      RAISE EXCEPTION 'A inversão não preserva o descanso exigido entre as atléticas envolvidas.';
    END IF;

    WITH ordered_matches AS (
      SELECT
        matches_table.id,
        row_number() OVER (
          PARTITION BY matches_table.scheduled_date, public.normalize_bracket_entity_name(matches_table.location), public.normalize_bracket_entity_name(matches_table.court_name)
          ORDER BY matches_table.start_time ASC NULLS LAST, COALESCE(matches_table.scheduled_slot, matches_table.queue_position) ASC NULLS LAST, matches_table.created_at ASC, matches_table.id ASC
        ) AS court_position
      FROM public.matches AS matches_table
      JOIN reverse_day_court_match_order_courts AS courts_table
        ON public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(courts_table.location_name)
        AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(courts_table.court_name)
      WHERE matches_table.championship_id = championship_id_value
        AND matches_table.season_year = season_year_value
        AND matches_table.status = 'SCHEDULED'::public.match_status
        AND matches_table.scheduled_date = scheduled_date_value
    )
    UPDATE public.matches AS matches_table
    SET manual_representation_mode = CASE
      WHEN ordered_matches.court_position = 1 THEN 'CO'
      ELSE 'AUTO'
    END
    FROM ordered_matches
    WHERE matches_table.id = ordered_matches.id
      AND matches_table.manual_representation_mode IS DISTINCT FROM CASE
        WHEN ordered_matches.court_position = 1 THEN 'CO'
        ELSE 'AUTO'
      END;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.skip_queue_trigger', 'false', true);
    RAISE;
  END;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'match_id', matches_table.id,
    'scheduled_date', matches_table.scheduled_date,
    'start_time', matches_table.start_time,
    'end_time', matches_table.end_time,
    'queue_position', matches_table.queue_position,
    'scheduled_slot', matches_table.scheduled_slot,
    'global_queue_order', matches_table.global_queue_order
  ) ORDER BY matches_table.id), '[]'::jsonb)
  INTO after_matches
  FROM public.matches AS matches_table
  JOIN reverse_day_court_match_order_slots AS slots_table
    ON slots_table.source_match_id = matches_table.id;

  PERFORM public.write_admin_action_log(
    'UPDATE'::public.admin_action_type,
    'matches',
    _bracket_edition_id::text,
    'Inverteu a ordem dos jogos agendados por quadra.',
    before_matches,
    after_matches,
    jsonb_build_object(
      'scheduled_date', scheduled_date_value,
      'bracket_court_ids', COALESCE(_payload->'bracket_court_ids', '[]'::jsonb),
      'affected_match_count', affected_match_count
    )
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.reprogram_championship_individual_session(
  _bracket_edition_id UUID,
  _payload JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  championship_id_value UUID;
  season_year_value INTEGER;
  edition_payload JSONB;

  session_id_value UUID;
  session_record public.championship_individual_sessions%ROWTYPE;

  scheduled_date_value DATE;
  start_time_value TIME;
  end_time_value TIME;

  location_group_id_value UUID;
  court_group_id_value UUID;

  bracket_day_id_value UUID;
  bracket_court_id_value UUID;

  day_start_time_value TIME;
  day_end_time_value TIME;

  location_name_value TEXT;
  court_name_value TEXT;

  exclusive_lock_enabled_value BOOLEAN;

  target_start_at TIMESTAMPTZ;
  target_end_at TIMESTAMPTZ;

  before_session JSONB;
  after_session JSONB;
BEGIN
  session_id_value :=
    NULLIF(_payload->>'session_id', '')::uuid;

  scheduled_date_value :=
    NULLIF(_payload->>'scheduled_date', '')::date;

  start_time_value :=
    NULLIF(_payload->>'start_time', '')::time;

  end_time_value :=
    NULLIF(_payload->>'end_time', '')::time;

  location_group_id_value :=
    NULLIF(_payload->>'location_group_id', '')::uuid;

  court_group_id_value :=
    NULLIF(_payload->>'court_group_id', '')::uuid;

  exclusive_lock_enabled_value :=
    COALESCE(
      (_payload->>'exclusive_lock_enabled')::boolean,
      false
    );

  IF session_id_value IS NULL THEN
    RAISE EXCEPTION 'Sessão individual inválida.';
  END IF;

  IF scheduled_date_value IS NULL THEN
    RAISE EXCEPTION 'Informe a data da sessão individual.';
  END IF;

  IF start_time_value IS NULL OR end_time_value IS NULL THEN
    RAISE EXCEPTION 'Informe o horário inicial e final da sessão.';
  END IF;

  IF end_time_value <= start_time_value THEN
    RAISE EXCEPTION 'O horário final deve ser maior que o horário inicial.';
  END IF;

  IF location_group_id_value IS NULL OR court_group_id_value IS NULL THEN
    RAISE EXCEPTION 'Selecione o local e a quadra da sessão.';
  END IF;

  SELECT
    editions_table.championship_id,
    editions_table.season_year,
    editions_table.payload_snapshot
  INTO
    championship_id_value,
    season_year_value,
    edition_payload
  FROM public.championship_bracket_editions AS editions_table
  JOIN public.championships AS championships_table
    ON championships_table.id = editions_table.championship_id
  WHERE editions_table.id = _bracket_edition_id
    AND championships_table.status =
      'REVIEW'::public.championship_status
  FOR UPDATE OF editions_table;

  IF championship_id_value IS NULL THEN
    RAISE EXCEPTION
      'A reprogramação só está disponível com o campeonato em revisão.';
  END IF;

  SELECT sessions_table.*
  INTO session_record
  FROM public.championship_individual_sessions AS sessions_table
  WHERE sessions_table.id = session_id_value
    AND sessions_table.championship_id = championship_id_value
    AND sessions_table.season_year = season_year_value
  FOR UPDATE;

  IF session_record.id IS NULL THEN
    RAISE EXCEPTION
      'Sessão individual não encontrada neste campeonato.';
  END IF;

  IF session_record.status IN (
    'LIVE'::public.championship_individual_session_status,
    'FINISHED'::public.championship_individual_session_status,
    'CANCELLED'::public.championship_individual_session_status
  ) THEN
    RAISE EXCEPTION
      'Esta sessão não pode mais ser reprogramada.';
  END IF;

  before_session := to_jsonb(session_record);

  SELECT
    days_table.id,
    days_table.start_time,
    days_table.end_time,
    locations_table.name,
    courts_table.id,
    courts_table.name
  INTO
    bracket_day_id_value,
    day_start_time_value,
    day_end_time_value,
    location_name_value,
    bracket_court_id_value,
    court_name_value
  FROM public.championship_bracket_days AS days_table
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.bracket_day_id = days_table.id
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND days_table.event_date = scheduled_date_value
    AND locations_table.location_group_id = location_group_id_value
    AND courts_table.court_group_id = court_group_id_value
  LIMIT 1;

  IF bracket_day_id_value IS NULL
    OR bracket_court_id_value IS NULL
  THEN
    RAISE EXCEPTION
      'O local ou a quadra selecionada não pertence à data informada.';
  END IF;

  IF start_time_value < day_start_time_value
    OR end_time_value > day_end_time_value
  THEN
    RAISE EXCEPTION
      'O horário da sessão precisa permanecer dentro da agenda do dia.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.championship_bracket_court_sports AS court_sports_table
    WHERE court_sports_table.bracket_court_id = bracket_court_id_value
      AND court_sports_table.sport_id = session_record.sport_id
  ) THEN
    RAISE EXCEPTION
      'A quadra selecionada não está habilitada para esta modalidade.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.championship_bracket_day_breaks AS breaks_table
    WHERE breaks_table.bracket_day_id = bracket_day_id_value
      AND (
        breaks_table.scope_type = 'ALL_COURTS'
        OR (
          breaks_table.scope_type = 'COURT'
          AND breaks_table.bracket_court_id = bracket_court_id_value
        )
      )
      AND start_time_value < breaks_table.break_end_time
      AND end_time_value > breaks_table.break_start_time
  ) THEN
    RAISE EXCEPTION
      'O horário da sessão conflita com um intervalo configurado.';
  END IF;

  target_start_at := make_timestamptz(
    EXTRACT(YEAR FROM scheduled_date_value)::integer,
    EXTRACT(MONTH FROM scheduled_date_value)::integer,
    EXTRACT(DAY FROM scheduled_date_value)::integer,
    EXTRACT(HOUR FROM start_time_value)::integer,
    EXTRACT(MINUTE FROM start_time_value)::integer,
    0,
    'America/Sao_Paulo'
  );

  target_end_at := make_timestamptz(
    EXTRACT(YEAR FROM scheduled_date_value)::integer,
    EXTRACT(MONTH FROM scheduled_date_value)::integer,
    EXTRACT(DAY FROM scheduled_date_value)::integer,
    EXTRACT(HOUR FROM end_time_value)::integer,
    EXTRACT(MINUTE FROM end_time_value)::integer,
    0,
    'America/Sao_Paulo'
  );

  IF exclusive_lock_enabled_value
    AND EXISTS (
      SELECT 1
      FROM public.matches AS matches_table
      WHERE matches_table.championship_id = championship_id_value
        AND matches_table.season_year = season_year_value
        AND matches_table.status =
          'SCHEDULED'::public.match_status
        AND matches_table.scheduled_date = scheduled_date_value
        AND public.normalize_bracket_entity_name(
          matches_table.location
        ) =
        public.normalize_bracket_entity_name(
          location_name_value
        )
        AND public.normalize_bracket_entity_name(
          COALESCE(matches_table.court_name, '')
        ) =
        public.normalize_bracket_entity_name(
          court_name_value
        )
        AND matches_table.start_time < target_end_at
        AND COALESCE(
          matches_table.end_time,
          matches_table.start_time
            + make_interval(
                mins => GREATEST(
                  COALESCE(
                    public.resolve_championship_sport_duration_minutes(
                      matches_table.championship_id,
                      matches_table.sport_id
                    ),
                    35
                  ),
                  1
                )
              )
        ) > target_start_at
    )
  THEN
    RAISE EXCEPTION
      'A reserva exclusiva da sessão conflita com um jogo já programado.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.championship_individual_sessions AS other_session
    WHERE other_session.id <> session_id_value
      AND other_session.championship_id = championship_id_value
      AND other_session.season_year = season_year_value
      AND other_session.status <>
        'CANCELLED'::public.championship_individual_session_status
      AND other_session.scheduled_date = scheduled_date_value
      AND other_session.location_key =
        location_group_id_value::text
      AND other_session.court_key =
        court_group_id_value::text
      AND other_session.start_time IS NOT NULL
      AND other_session.end_time IS NOT NULL
      AND (
        exclusive_lock_enabled_value
        OR other_session.exclusive_lock_enabled
      )
      AND start_time_value < other_session.end_time
      AND end_time_value > other_session.start_time
  ) THEN
    RAISE EXCEPTION
      'A sessão conflita com outra sessão que possui reserva exclusiva do recurso.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      COALESCE(
        edition_payload->'resource_locks',
        '[]'::jsonb
      )
    ) AS lock_record(value)
    WHERE lock_record.value->>'date' =
        scheduled_date_value::text
      AND lock_record.value->>'location_key' =
        location_group_id_value::text
      AND lock_record.value->>'court_key' =
        court_group_id_value::text
      AND COALESCE(
        lock_record.value->>'lock_mode',
        'FLEXIBLE'
      ) = 'HARD'
      AND start_time_value <
        NULLIF(
          lock_record.value->>'end_time',
          ''
        )::time
      AND end_time_value >
        NULLIF(
          lock_record.value->>'start_time',
          ''
        )::time
  ) THEN
    RAISE EXCEPTION
      'A sessão conflita com uma reserva fixa deste recurso.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      COALESCE(
        edition_payload->'individual_session_configs',
        '[]'::jsonb
      )
    ) AS config_record(value)
    WHERE config_record.value->>'sport_id' =
        session_record.sport_id::text
      AND config_record.value->>'naipe' =
        session_record.naipe::text
      AND COALESCE(
        NULLIF(config_record.value->>'division', ''),
        'WITHOUT_DIVISION'
      ) =
      COALESCE(
        session_record.division::text,
        'WITHOUT_DIVISION'
      )
  ) THEN
    RAISE EXCEPTION
      'A configuração original desta sessão não foi encontrada.';
  END IF;

  UPDATE public.championship_individual_sessions
  SET
    scheduled_date = scheduled_date_value,
    period = NULL,
    start_time = start_time_value,
    end_time = end_time_value,
    location_key = location_group_id_value::text,
    court_key = court_group_id_value::text,
    location_name = location_name_value,
    court_name = court_name_value,
    status =
      'SCHEDULED'::public.championship_individual_session_status,
    exclusive_lock_enabled = exclusive_lock_enabled_value,
    updated_at = now()
  WHERE id = session_id_value;

  UPDATE public.championship_individual_events
  SET
    scheduled_date = scheduled_date_value,
    period = NULL,
    location = location_name_value,
    status = CASE
      WHEN status =
        'FINISHED'::public.championship_individual_event_status
      THEN status
      ELSE
        'SCHEDULED'::public.championship_individual_event_status
    END,
    updated_at = now()
  WHERE session_id = session_id_value;

  UPDATE public.championship_bracket_editions AS editions_table
  SET
    payload_snapshot = jsonb_set(
      editions_table.payload_snapshot,
      '{individual_session_configs}',
      (
        SELECT COALESCE(
          jsonb_agg(
            CASE
              WHEN config_record.value->>'sport_id' =
                  session_record.sport_id::text
                AND config_record.value->>'naipe' =
                  session_record.naipe::text
                AND COALESCE(
                  NULLIF(
                    config_record.value->>'division',
                    ''
                  ),
                  'WITHOUT_DIVISION'
                ) =
                COALESCE(
                  session_record.division::text,
                  'WITHOUT_DIVISION'
                )
              THEN
                config_record.value
                || jsonb_build_object(
                  'scheduled_date',
                  scheduled_date_value::text,
                  'period',
                  NULL,
                  'start_time',
                  to_char(start_time_value, 'HH24:MI'),
                  'end_time',
                  to_char(end_time_value, 'HH24:MI'),
                  'location_key',
                  location_group_id_value::text,
                  'court_key',
                  court_group_id_value::text,
                  'location_name',
                  location_name_value,
                  'court_name',
                  court_name_value,
                  'exclusive_lock_enabled',
                  exclusive_lock_enabled_value
                )
              ELSE config_record.value
            END
            ORDER BY config_record.ordinality
          ),
          '[]'::jsonb
        )
        FROM jsonb_array_elements(
          COALESCE(
            editions_table.payload_snapshot
              ->'individual_session_configs',
            '[]'::jsonb
          )
        ) WITH ORDINALITY
          AS config_record(value, ordinality)
      )
    ),
    reprogramming_revision =
      reprogramming_revision + 1,
    updated_at = now(),
    updated_by = auth.uid()
  WHERE editions_table.id = _bracket_edition_id;

  SELECT to_jsonb(sessions_table)
  INTO after_session
  FROM public.championship_individual_sessions AS sessions_table
  WHERE sessions_table.id = session_id_value;

  PERFORM public.write_admin_action_log(
    'UPDATE'::public.admin_action_type,
    'championship_individual_sessions',
    session_id_value::text,
    'Reprogramou uma sessão individual.',
    before_session,
    after_session,
    jsonb_build_object(
      'bracket_edition_id',
      _bracket_edition_id,
      'scheduled_date',
      scheduled_date_value,
      'start_time',
      start_time_value,
      'end_time',
      end_time_value,
      'location_name',
      location_name_value,
      'court_name',
      court_name_value,
      'exclusive_lock_enabled',
      exclusive_lock_enabled_value
    )
  );
END;
$$;

REVOKE ALL
ON FUNCTION public.reprogram_championship_individual_session(UUID, JSONB)
FROM PUBLIC;



CREATE OR REPLACE FUNCTION
  public.update_bracket_court_sequences(
    _bracket_edition_id UUID,
    _sequence_updates JSONB
  )
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_championship_id UUID;

  v_item JSONB;

  v_court_id UUID;
  v_sport_id UUID;

  v_sequence_mode TEXT;

  v_preferred_naipe TEXT;
  v_preferred_division TEXT;

  v_location_group_id UUID;
BEGIN
  IF NOT public.has_admin_tab_access(
    'championship_schedule'
      ::public.admin_panel_tab,
    true
  )
  THEN
    RAISE EXCEPTION
      'Usuário sem permissão para reprogramar prioridades de quadra.';
  END IF;

  SELECT editions_table.championship_id
  INTO v_championship_id
  FROM public.championship_bracket_editions
    AS editions_table
  JOIN public.championships
    AS championships_table
    ON championships_table.id =
      editions_table.championship_id
  WHERE editions_table.id =
      _bracket_edition_id
    AND championships_table.status =
      'REVIEW'::public.championship_status
  LIMIT 1;

  IF v_championship_id IS NULL THEN
    RAISE EXCEPTION
      'A reprogramação só está disponível com o campeonato em revisão.';
  END IF;

  PERFORM set_config(
    'app.allow_court_sequence_reprogramming',
    'true',
    true
  );

  FOR v_item IN
    SELECT *
    FROM jsonb_array_elements(
      COALESCE(
        _sequence_updates,
        '[]'::jsonb
      )
    )
  LOOP
    v_court_id :=
      NULLIF(
        trim(
          COALESCE(
            v_item ->> 'bracket_court_id',
            ''
          )
        ),
        ''
      )::uuid;

    v_sport_id :=
      NULLIF(
        trim(
          COALESCE(
            v_item ->> 'sport_id',
            ''
          )
        ),
        ''
      )::uuid;

    v_sequence_mode :=
      upper(
        trim(
          COALESCE(
            v_item ->> 'sequence_mode',
            ''
          )
        )
      );

    v_preferred_naipe :=
      NULLIF(
        trim(
          COALESCE(
            v_item ->> 'preferred_naipe',
            ''
          )
        ),
        ''
      );

    v_preferred_division :=
      NULLIF(
        trim(
          COALESCE(
            v_item ->> 'preferred_division',
            ''
          )
        ),
        ''
      );

    IF v_court_id IS NULL
      OR v_sport_id IS NULL
    THEN
      RAISE EXCEPTION
        'Quadra ou modalidade inválida na reprogramação.';
    END IF;

    IF v_sequence_mode NOT IN (
      'FLEXIBLE',
      'GROUP_NAIPE',
      'ALTERNATE_NAIPE',
      'GROUP_DIVISION'
    )
    THEN
      RAISE EXCEPTION
        'Modo de sequenciamento inválido: %.',
        v_sequence_mode;
    END IF;

    IF v_sequence_mode IN (
      'GROUP_NAIPE',
      'ALTERNATE_NAIPE'
    )
    THEN
      IF v_preferred_naipe IS NULL
        OR v_preferred_naipe NOT IN (
          'FEMININO',
          'MASCULINO',
          'MISTO'
        )
      THEN
        RAISE EXCEPTION
          'Informe o naipe inicial para o sequenciamento por naipe.';
      END IF;

      v_preferred_division := NULL;

    ELSIF v_sequence_mode =
      'GROUP_DIVISION'
    THEN
      IF v_preferred_division IS NULL
        OR v_preferred_division NOT IN (
          'DIVISAO_PRINCIPAL',
          'DIVISAO_ACESSO'
        )
      THEN
        RAISE EXCEPTION
          'Informe a divisão inicial para o sequenciamento por divisão.';
      END IF;

      v_preferred_naipe := NULL;

    ELSE
      v_preferred_naipe := NULL;
      v_preferred_division := NULL;
    END IF;

    /*
     * Resolve e valida simultaneamente:
     *
     * - quadra pertence à edição;
     * - modalidade existe nessa quadra;
     * - modalidade é a modalidade principal
     *   definida para a quadra.
     */
    SELECT locations_table.location_group_id
    INTO v_location_group_id
    FROM public.championship_bracket_courts
      AS courts_table
    JOIN public.championship_bracket_locations
      AS locations_table
      ON locations_table.id =
        courts_table.bracket_location_id
    JOIN public.championship_bracket_days
      AS days_table
      ON days_table.id =
        locations_table.bracket_day_id
    JOIN public.championship_bracket_court_sports
      AS court_sports_table
      ON court_sports_table.bracket_court_id =
        courts_table.id
      AND court_sports_table.sport_id =
        v_sport_id
    WHERE courts_table.id =
        v_court_id
      AND days_table.bracket_edition_id =
        _bracket_edition_id
      AND courts_table.preferred_sport_id =
        v_sport_id
    LIMIT 1;

    IF v_location_group_id IS NULL THEN
      RAISE EXCEPTION
        'A modalidade não está definida como principal nesta quadra.';
    END IF;

    UPDATE public.championship_bracket_court_sports
      AS court_sports_table
    SET
      sequence_mode =
        v_sequence_mode
          ::public.bracket_court_sequence_mode,

      preferred_naipe = CASE
        WHEN v_preferred_naipe IS NULL
          THEN NULL
        ELSE
          v_preferred_naipe
            ::public.match_naipe
      END,

      preferred_division = CASE
        WHEN v_preferred_division IS NULL
          THEN NULL
        ELSE
          v_preferred_division
            ::public.team_division
      END,

      alternate_naipe_after_exclusive_knockout_phase =
        false

    WHERE court_sports_table.bracket_court_id =
        v_court_id
      AND court_sports_table.sport_id =
        v_sport_id;

    /*
     * A prioridade global antiga não deve interferir
     * quando a nova aba passa a controlar a quadra
     * diretamente.
     */
    DELETE FROM
      public.championship_bracket_location_sport_priorities
    WHERE bracket_edition_id =
        _bracket_edition_id
      AND location_group_id =
        v_location_group_id
      AND sport_id =
        v_sport_id;
  END LOOP;

  PERFORM set_config(
    'app.allow_court_sequence_reprogramming',
    'false',
    true
  );

  /*
   * Redistribui apenas uma vez após todas as alterações.
   */
  PERFORM public.redistribute_bracket_scheduled_matches(
    _bracket_edition_id
  );
END;
$$;

COMMENT ON FUNCTION
  public.update_bracket_court_sequences(
    UUID,
    JSONB
  )
IS
  'Reprograma o sequenciamento por modalidade na quadra principal durante REVIEW e redistribui a agenda uma única vez.';

-- ============================================================
-- 5. Adiciona COURT_SPORT_SEQUENCE ao executor seguro
--    sem sobrescrever ações adicionadas por migrations futuras
-- ============================================================


CREATE OR REPLACE FUNCTION public.execute_championship_bracket_reconfiguration(
  _bracket_edition_id UUID,
  _action TEXT,
  _payload JSONB
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  CASE _action
    WHEN 'DAY_SCHEDULE' THEN
      PERFORM public.update_bracket_day_schedule(
        _bracket_edition_id,
        COALESCE(
          _payload->'schedule_updates',
          '[]'::jsonb
        )
      );

    WHEN 'REVERSE_DAY_COURT_MATCH_ORDER' THEN
      PERFORM public.reverse_championship_bracket_day_court_match_order(
        _bracket_edition_id,
        COALESCE(_payload, '{}'::jsonb)
      );

    WHEN 'INDIVIDUAL_SESSION' THEN
      PERFORM public.reprogram_championship_individual_session(
        _bracket_edition_id,
        COALESCE(_payload, '{}'::jsonb)
      );

    WHEN 'COMPETITION_SETTINGS' THEN
      PERFORM public.update_bracket_competition_settings(
        (_payload->>'competition_id')::uuid,
        (_payload->>'qualifiers_per_group')::integer,
        COALESCE(
          (
            _payload
              ->>'should_complete_knockout_with_best_second_placed_teams'
          )::boolean,
          false
        ),
        COALESCE(
          _payload->>'knockout_pairing_mode',
          'LINEAR'
        )
      );

    WHEN 'LOCATION_SPORT_PRIORITIES' THEN
      PERFORM public.update_bracket_location_sport_priorities(
        _bracket_edition_id,
        COALESCE(
          _payload->'priority_updates',
          '[]'::jsonb
        )
      );

    WHEN 'COURT_SPORT_SEQUENCE' THEN
      PERFORM public.update_bracket_court_sequences(
        _bracket_edition_id,
        COALESCE(_payload->'sequence_updates', '[]'::jsonb)
      );
    WHEN 'KNOCKOUT_COURT_PRIORITIES' THEN
      PERFORM public.update_bracket_knockout_court_priorities(
        _bracket_edition_id,
        COALESCE(
          _payload->'priority_updates',
          '[]'::jsonb
        )
      );

    WHEN 'LOCATION_GROUP' THEN
      PERFORM public.update_bracket_generated_location_group(
        _bracket_edition_id,
        _payload
      );

    ELSE
      RAISE EXCEPTION
        'Tipo de reprogramação inválido.';
  END CASE;
END;
$$;


CREATE OR REPLACE FUNCTION public.bump_championship_bracket_reprogramming_revision()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  edition_id_value UUID;
  trigger_record JSONB;
  previous_record JSONB;
BEGIN
  trigger_record := CASE TG_OP
    WHEN 'DELETE' THEN to_jsonb(OLD)
    ELSE to_jsonb(NEW)
  END;
  previous_record := CASE TG_OP
    WHEN 'INSERT' THEN NULL
    ELSE to_jsonb(OLD)
  END;

  IF TG_OP = 'UPDATE'
    AND TG_TABLE_NAME IN ('championship_bracket_locations', 'championship_bracket_courts')
    AND (trigger_record - 'name') = (previous_record - 'name') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE'
    AND TG_TABLE_NAME = 'matches'
    AND trigger_record = previous_record THEN
    RETURN NEW;
  END IF;

  CASE TG_TABLE_NAME
    WHEN 'championship_bracket_competitions',
         'championship_bracket_location_sport_priorities',
         'championship_bracket_knockout_court_priorities',
         'championship_bracket_days' THEN
      edition_id_value := (trigger_record->>'bracket_edition_id')::uuid;
    WHEN 'championship_bracket_day_breaks' THEN
      SELECT days_table.bracket_edition_id
      INTO edition_id_value
      FROM public.championship_bracket_days AS days_table
      WHERE days_table.id = (trigger_record->>'bracket_day_id')::uuid;
    WHEN 'championship_bracket_locations' THEN
      SELECT days_table.bracket_edition_id
      INTO edition_id_value
      FROM public.championship_bracket_days AS days_table
      WHERE days_table.id = (trigger_record->>'bracket_day_id')::uuid;
    WHEN 'championship_bracket_courts' THEN
      SELECT days_table.bracket_edition_id
      INTO edition_id_value
      FROM public.championship_bracket_locations AS locations_table
      JOIN public.championship_bracket_days AS days_table
        ON days_table.id = locations_table.bracket_day_id
      WHERE locations_table.id = (trigger_record->>'bracket_location_id')::uuid;
    WHEN 'championship_bracket_court_sports' THEN
      SELECT days_table.bracket_edition_id INTO edition_id_value
      FROM public.championship_bracket_courts c
      JOIN public.championship_bracket_locations l ON l.id = c.bracket_location_id
      JOIN public.championship_bracket_days days_table ON days_table.id = l.bracket_day_id
      WHERE c.id = (trigger_record->>'bracket_court_id')::uuid;
    WHEN 'matches' THEN
      SELECT editions_table.id
      INTO edition_id_value
      FROM public.championship_bracket_editions AS editions_table
      WHERE editions_table.championship_id = (trigger_record->>'championship_id')::uuid
        AND editions_table.season_year = (trigger_record->>'season_year')::integer
      ORDER BY editions_table.updated_at DESC NULLS LAST, editions_table.created_at DESC
      LIMIT 1;
  END CASE;

  IF edition_id_value IS NOT NULL THEN
    UPDATE public.championship_bracket_editions
    SET reprogramming_revision = reprogramming_revision + 1
    WHERE id = edition_id_value;
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS matches_bump_championship_bracket_reprogramming_revision ON public.matches;
CREATE TRIGGER matches_bump_championship_bracket_reprogramming_revision
AFTER UPDATE OF scheduled_date, start_time, end_time, location, court_name, queue_position, global_queue_order, scheduled_slot ON public.matches
FOR EACH ROW EXECUTE FUNCTION public.bump_championship_bracket_reprogramming_revision();


DROP TRIGGER IF EXISTS championship_bracket_days_reprogramming_revision ON public.championship_bracket_days;
CREATE TRIGGER championship_bracket_days_reprogramming_revision
AFTER INSERT OR UPDATE OR DELETE ON public.championship_bracket_days
FOR EACH ROW EXECUTE FUNCTION public.bump_championship_bracket_reprogramming_revision();

DROP TRIGGER IF EXISTS championship_bracket_day_breaks_reprogramming_revision ON public.championship_bracket_day_breaks;
CREATE TRIGGER championship_bracket_day_breaks_reprogramming_revision
AFTER INSERT OR UPDATE OR DELETE ON public.championship_bracket_day_breaks
FOR EACH ROW EXECUTE FUNCTION public.bump_championship_bracket_reprogramming_revision();

DROP TRIGGER IF EXISTS championship_bracket_locations_reprogramming_revision ON public.championship_bracket_locations;
CREATE TRIGGER championship_bracket_locations_reprogramming_revision
AFTER INSERT OR UPDATE OR DELETE ON public.championship_bracket_locations
FOR EACH ROW EXECUTE FUNCTION public.bump_championship_bracket_reprogramming_revision();

DROP TRIGGER IF EXISTS championship_bracket_courts_reprogramming_revision ON public.championship_bracket_courts;
CREATE TRIGGER championship_bracket_courts_reprogramming_revision
AFTER INSERT OR UPDATE OR DELETE ON public.championship_bracket_courts
FOR EACH ROW EXECUTE FUNCTION public.bump_championship_bracket_reprogramming_revision();

DROP TRIGGER IF EXISTS championship_bracket_competitions_reprogramming_revision ON public.championship_bracket_competitions;
CREATE TRIGGER championship_bracket_competitions_reprogramming_revision
AFTER INSERT OR UPDATE OR DELETE ON public.championship_bracket_competitions
FOR EACH ROW EXECUTE FUNCTION public.bump_championship_bracket_reprogramming_revision();

DROP TRIGGER IF EXISTS championship_bracket_location_sport_priorities_reprogramming_revision ON public.championship_bracket_location_sport_priorities;
CREATE TRIGGER championship_bracket_location_sport_priorities_reprogramming_revision
AFTER INSERT OR UPDATE OR DELETE ON public.championship_bracket_location_sport_priorities
FOR EACH ROW EXECUTE FUNCTION public.bump_championship_bracket_reprogramming_revision();

DROP TRIGGER IF EXISTS championship_bracket_knockout_court_priorities_reprogramming_revision ON public.championship_bracket_knockout_court_priorities;
CREATE TRIGGER championship_bracket_knockout_court_priorities_reprogramming_revision
AFTER INSERT OR UPDATE OR DELETE ON public.championship_bracket_knockout_court_priorities
FOR EACH ROW EXECUTE FUNCTION public.bump_championship_bracket_reprogramming_revision();


DROP TRIGGER IF EXISTS
  championship_bracket_court_sports_reprogramming_revision
ON public.championship_bracket_court_sports;

CREATE TRIGGER
  championship_bracket_court_sports_reprogramming_revision
AFTER INSERT OR UPDATE OR DELETE
ON public.championship_bracket_court_sports
FOR EACH ROW
EXECUTE FUNCTION
  public.bump_championship_bracket_reprogramming_revision();


CREATE OR REPLACE FUNCTION public.preview_championship_bracket_reconfiguration(
  _bracket_edition_id UUID,
  _action TEXT,
  _payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  revision_value BIGINT;
  before_schedule JSONB;
  preview_result JSONB;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_admin_tab_access('championship_schedule'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para reprogramar a agenda.';
  END IF;

  SELECT reprogramming_revision
  INTO revision_value
  FROM public.championship_bracket_editions AS editions_table
  JOIN public.championships AS championships_table ON championships_table.id = editions_table.championship_id
  WHERE editions_table.id = _bracket_edition_id
    AND championships_table.status = 'REVIEW'::public.championship_status;

  IF revision_value IS NULL THEN
    RAISE EXCEPTION 'A reprogramação só está disponível com o campeonato em revisão.';
  END IF;

  WITH numbered_matches AS (
    SELECT
      scoped_matches.id,
      row_number() OVER (
        PARTITION BY scoped_matches.numbering_scope
        ORDER BY
          scoped_matches.scheduled_date ASC,
          scoped_matches.start_time ASC NULLS LAST,
          COALESCE(scoped_matches.scheduled_slot, scoped_matches.queue_position) ASC NULLS LAST,
          scoped_matches.created_at ASC,
          scoped_matches.id ASC
      )::INTEGER AS match_number
    FROM (
      SELECT
        matches_table.id,
        matches_table.scheduled_date,
        matches_table.start_time,
        matches_table.scheduled_slot,
        matches_table.queue_position,
        matches_table.created_at,
        CASE
          WHEN editions_table.payload_snapshot ->> 'match_numbering_mode' = 'SPORT_NAIPE'
            THEN concat_ws('::', matches_table.sport_id::TEXT, matches_table.naipe::TEXT)
          WHEN editions_table.payload_snapshot ->> 'match_numbering_mode' = 'SPORT'
            THEN matches_table.sport_id::TEXT
          ELSE concat_ws(
            '::',
            public.normalize_bracket_entity_name(matches_table.location),
            public.normalize_bracket_entity_name(COALESCE(matches_table.court_name, ''))
          )
        END AS numbering_scope
      FROM public.matches AS matches_table
      JOIN public.championship_bracket_editions AS editions_table
        ON editions_table.championship_id = matches_table.championship_id
      WHERE editions_table.id = _bracket_edition_id
        AND matches_table.season_year = editions_table.season_year
        AND matches_table.scheduled_date IS NOT NULL
    ) AS scoped_matches
  ),
  court_positions AS (
    SELECT
      matches_table.id,
      row_number() OVER (
        PARTITION BY
          matches_table.scheduled_date,
          public.normalize_bracket_entity_name(matches_table.location),
          public.normalize_bracket_entity_name(COALESCE(matches_table.court_name, ''))
        ORDER BY
          matches_table.start_time ASC NULLS LAST,
          COALESCE(matches_table.scheduled_slot, matches_table.queue_position) ASC NULLS LAST,
          matches_table.global_queue_order ASC NULLS LAST,
          matches_table.created_at ASC,
          matches_table.id ASC
      )::INTEGER AS court_sequence_position
    FROM public.matches AS matches_table
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.championship_id = matches_table.championship_id
    WHERE editions_table.id = _bracket_edition_id
      AND matches_table.season_year = editions_table.season_year
      AND matches_table.status = 'SCHEDULED'::public.match_status
      AND matches_table.scheduled_date IS NOT NULL
  ),
  match_snapshots AS (
    SELECT
      matches_table.id,
      jsonb_build_object(
        'scheduled_date', matches_table.scheduled_date,
        'start_time', matches_table.start_time,
        'end_time', matches_table.end_time,
        'location', matches_table.location,
        'court_name', matches_table.court_name,
        'queue_position', matches_table.queue_position,
        'global_queue_order', matches_table.global_queue_order,
        'scheduled_slot', matches_table.scheduled_slot,
        'court_sequence_position', CASE
          WHEN _action = 'REVERSE_DAY_COURT_MATCH_ORDER' THEN court_positions.court_sequence_position
          ELSE NULL
        END,
        'manual_representation_mode', matches_table.manual_representation_mode,
        'match_number', numbered_matches.match_number,
        'sport_name', sports_table.name,
        'naipe', matches_table.naipe,
        'home_team_name', home_teams_table.name,
        'away_team_name', away_teams_table.name
      ) AS snapshot
    FROM public.matches AS matches_table
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.championship_id = matches_table.championship_id
    LEFT JOIN numbered_matches ON numbered_matches.id = matches_table.id
    LEFT JOIN court_positions ON court_positions.id = matches_table.id
    LEFT JOIN public.sports AS sports_table ON sports_table.id = matches_table.sport_id
    LEFT JOIN public.teams AS home_teams_table ON home_teams_table.id = matches_table.home_team_id
    LEFT JOIN public.teams AS away_teams_table ON away_teams_table.id = matches_table.away_team_id
    WHERE editions_table.id = _bracket_edition_id
      AND matches_table.season_year = editions_table.season_year
  )
  SELECT COALESCE(jsonb_object_agg(match_snapshots.id, match_snapshots.snapshot), '{}'::jsonb)
  INTO before_schedule
  FROM match_snapshots;

  BEGIN
    PERFORM public.execute_championship_bracket_reconfiguration(
      _bracket_edition_id,
      _action,
      COALESCE(_payload, '{}'::jsonb)
    );

    SELECT jsonb_build_object(
      'revision', revision_value,
      'action', _action,
      'affected_matches', count(*)::integer,
      'changes', COALESCE(jsonb_agg(jsonb_build_object(
        'match_id', after_item.key,
        'match_number', NULLIF(before_item.value ->> 'match_number', '')::INTEGER,
        'before', before_item.value,
        'after', after_item.value,
        'changed_fields', array_remove(ARRAY[
          CASE WHEN before_item.value->'scheduled_date' IS DISTINCT FROM after_item.value->'scheduled_date' THEN 'data' END,
          CASE WHEN before_item.value->'start_time' IS DISTINCT FROM after_item.value->'start_time' THEN 'horário de início' END,
          CASE WHEN before_item.value->'end_time' IS DISTINCT FROM after_item.value->'end_time' THEN 'horário de término' END,
          CASE WHEN before_item.value->'location' IS DISTINCT FROM after_item.value->'location' THEN 'local' END,
          CASE WHEN before_item.value->'court_name' IS DISTINCT FROM after_item.value->'court_name' THEN 'quadra' END,
          CASE WHEN before_item.value->'queue_position' IS DISTINCT FROM after_item.value->'queue_position' OR before_item.value->'global_queue_order' IS DISTINCT FROM after_item.value->'global_queue_order' OR before_item.value->'scheduled_slot' IS DISTINCT FROM after_item.value->'scheduled_slot' THEN 'posição' END,
          CASE WHEN before_item.value->'manual_representation_mode' IS DISTINCT FROM after_item.value->'manual_representation_mode' THEN 'representação' END
        ], NULL)
      ) ORDER BY
        NULLIF(after_item.value ->> 'scheduled_date', '')::DATE,
        NULLIF(after_item.value ->> 'start_time', '')::TIMESTAMPTZ,
        COALESCE(
          NULLIF(after_item.value ->> 'scheduled_slot', '')::INTEGER,
          NULLIF(after_item.value ->> 'queue_position', '')::INTEGER
        ),
        after_item.key), '[]'::jsonb),
      'blockers', '[]'::jsonb
    )
    INTO preview_result
    FROM jsonb_each(before_schedule) AS before_item
    JOIN jsonb_each((
      WITH numbered_matches AS (
        SELECT
          scoped_matches.id,
          row_number() OVER (
            PARTITION BY scoped_matches.numbering_scope
            ORDER BY
              scoped_matches.scheduled_date ASC,
              scoped_matches.start_time ASC NULLS LAST,
              COALESCE(scoped_matches.scheduled_slot, scoped_matches.queue_position) ASC NULLS LAST,
              scoped_matches.created_at ASC,
              scoped_matches.id ASC
          )::INTEGER AS match_number
        FROM (
          SELECT
            matches_table.id,
            matches_table.scheduled_date,
            matches_table.start_time,
            matches_table.scheduled_slot,
            matches_table.queue_position,
            matches_table.created_at,
            CASE
              WHEN editions_table.payload_snapshot ->> 'match_numbering_mode' = 'SPORT_NAIPE'
                THEN concat_ws('::', matches_table.sport_id::TEXT, matches_table.naipe::TEXT)
              WHEN editions_table.payload_snapshot ->> 'match_numbering_mode' = 'SPORT'
                THEN matches_table.sport_id::TEXT
              ELSE concat_ws(
                '::',
                public.normalize_bracket_entity_name(matches_table.location),
                public.normalize_bracket_entity_name(COALESCE(matches_table.court_name, ''))
              )
            END AS numbering_scope
          FROM public.matches AS matches_table
          JOIN public.championship_bracket_editions AS editions_table
            ON editions_table.championship_id = matches_table.championship_id
          WHERE editions_table.id = _bracket_edition_id
            AND matches_table.season_year = editions_table.season_year
            AND matches_table.scheduled_date IS NOT NULL
        ) AS scoped_matches
      ),
      court_positions AS (
        SELECT
          matches_table.id,
          row_number() OVER (
            PARTITION BY
              matches_table.scheduled_date,
              public.normalize_bracket_entity_name(matches_table.location),
              public.normalize_bracket_entity_name(COALESCE(matches_table.court_name, ''))
            ORDER BY
              matches_table.start_time ASC NULLS LAST,
              COALESCE(matches_table.scheduled_slot, matches_table.queue_position) ASC NULLS LAST,
              matches_table.global_queue_order ASC NULLS LAST,
              matches_table.created_at ASC,
              matches_table.id ASC
          )::INTEGER AS court_sequence_position
        FROM public.matches AS matches_table
        JOIN public.championship_bracket_editions AS editions_table
          ON editions_table.championship_id = matches_table.championship_id
        WHERE editions_table.id = _bracket_edition_id
          AND matches_table.season_year = editions_table.season_year
          AND matches_table.status = 'SCHEDULED'::public.match_status
          AND matches_table.scheduled_date IS NOT NULL
      ),
      match_snapshots AS (
        SELECT
          matches_table.id,
          jsonb_build_object(
            'scheduled_date', matches_table.scheduled_date,
            'start_time', matches_table.start_time,
            'end_time', matches_table.end_time,
            'location', matches_table.location,
            'court_name', matches_table.court_name,
            'queue_position', matches_table.queue_position,
            'global_queue_order', matches_table.global_queue_order,
            'scheduled_slot', matches_table.scheduled_slot,
            'court_sequence_position', CASE
              WHEN _action = 'REVERSE_DAY_COURT_MATCH_ORDER' THEN court_positions.court_sequence_position
              ELSE NULL
            END,
            'manual_representation_mode', matches_table.manual_representation_mode,
            'match_number', numbered_matches.match_number,
            'sport_name', sports_table.name,
            'naipe', matches_table.naipe,
            'home_team_name', home_teams_table.name,
            'away_team_name', away_teams_table.name
          ) AS snapshot
        FROM public.matches AS matches_table
        JOIN public.championship_bracket_editions AS editions_table
          ON editions_table.championship_id = matches_table.championship_id
        LEFT JOIN numbered_matches ON numbered_matches.id = matches_table.id
        LEFT JOIN court_positions ON court_positions.id = matches_table.id
        LEFT JOIN public.sports AS sports_table ON sports_table.id = matches_table.sport_id
        LEFT JOIN public.teams AS home_teams_table ON home_teams_table.id = matches_table.home_team_id
        LEFT JOIN public.teams AS away_teams_table ON away_teams_table.id = matches_table.away_team_id
        WHERE editions_table.id = _bracket_edition_id
          AND matches_table.season_year = editions_table.season_year
      )
      SELECT COALESCE(jsonb_object_agg(match_snapshots.id, match_snapshots.snapshot), '{}'::jsonb)
      FROM match_snapshots
    )) AS after_item ON after_item.key = before_item.key
    WHERE before_item.value IS DISTINCT FROM after_item.value;

    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ROLLBACK_CHAMPIONSHIP_BRACKET_RECONFIGURATION_PREVIEW';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> 'ROLLBACK_CHAMPIONSHIP_BRACKET_RECONFIGURATION_PREVIEW' THEN
      preview_result := jsonb_build_object(
        'revision', revision_value,
        'action', _action,
        'affected_matches', 0,
        'changes', '[]'::jsonb,
        'blockers', jsonb_build_array(SQLERRM)
      );
    END IF;
  WHEN OTHERS THEN
    preview_result := jsonb_build_object(
      'revision', revision_value,
      'action', _action,
      'affected_matches', 0,
      'changes', '[]'::jsonb,
      'blockers', jsonb_build_array(SQLERRM)
    );
  END;

  RETURN COALESCE(preview_result, jsonb_build_object(
    'revision', revision_value,
    'action', _action,
    'affected_matches', 0,
    'changes', '[]'::jsonb,
    'blockers', '[]'::jsonb
  ));
END;
$$;


CREATE OR REPLACE FUNCTION public.apply_championship_bracket_reconfiguration(
  _bracket_edition_id UUID,
  _action TEXT,
  _payload JSONB,
  _expected_revision BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  revision_value BIGINT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_admin_tab_access('championship_schedule'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para reprogramar a agenda.';
  END IF;

  SELECT reprogramming_revision
  INTO revision_value
  FROM public.championship_bracket_editions AS editions_table
  JOIN public.championships AS championships_table ON championships_table.id = editions_table.championship_id
  WHERE editions_table.id = _bracket_edition_id
    AND championships_table.status = 'REVIEW'::public.championship_status
  FOR UPDATE OF editions_table;

  IF revision_value IS NULL THEN
    RAISE EXCEPTION 'A reprogramação só está disponível com o campeonato em revisão.';
  END IF;

  IF revision_value <> _expected_revision THEN
    RAISE EXCEPTION USING ERRCODE = '40001', MESSAGE = 'A agenda foi alterada desde a prévia. Revise o impacto novamente.';
  END IF;

  PERFORM public.execute_championship_bracket_reconfiguration(
    _bracket_edition_id,
    _action,
    COALESCE(_payload, '{}'::jsonb)
  );
END;
$$;


CREATE OR REPLACE FUNCTION public.prevent_review_match_operations()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  championship_status_value public.championship_status;
BEGIN
  SELECT status INTO championship_status_value
  FROM public.championships
  WHERE id = NEW.championship_id;

  IF championship_status_value <> 'REVIEW'::public.championship_status THEN
    RETURN NEW;
  END IF;

  IF NEW.status IS DISTINCT FROM OLD.status
    OR NEW.home_score IS DISTINCT FROM OLD.home_score
    OR NEW.away_score IS DISTINCT FROM OLD.away_score
    OR NEW.home_penalty_score IS DISTINCT FROM OLD.home_penalty_score
    OR NEW.away_penalty_score IS DISTINCT FROM OLD.away_penalty_score
    OR NEW.current_set_home_score IS DISTINCT FROM OLD.current_set_home_score
    OR NEW.current_set_away_score IS DISTINCT FROM OLD.current_set_away_score
    OR NEW.is_walkover IS DISTINCT FROM OLD.is_walkover
    OR NEW.is_double_walkover IS DISTINCT FROM OLD.is_double_walkover
    OR NEW.walkover_loser_team_id IS DISTINCT FROM OLD.walkover_loser_team_id
    OR NEW.is_score_sheet_reviewed IS DISTINCT FROM OLD.is_score_sheet_reviewed
    OR NEW.resolved_tie_break_winner_team_id IS DISTINCT FROM OLD.resolved_tie_break_winner_team_id
    OR NEW.resolved_tie_breaker_rule IS DISTINCT FROM OLD.resolved_tie_breaker_rule
  THEN
    RAISE EXCEPTION 'As operações de jogo só podem ser feitas com o campeonato em andamento.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS matches_prevent_review_operations ON public.matches;
CREATE TRIGGER matches_prevent_review_operations
BEFORE UPDATE ON public.matches
FOR EACH ROW EXECUTE FUNCTION public.prevent_review_match_operations();

CREATE OR REPLACE FUNCTION public.prevent_review_individual_session_operations()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  championship_status_value public.championship_status;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  SELECT status INTO championship_status_value
  FROM public.championships
  WHERE id = NEW.championship_id;

  IF championship_status_value <> 'IN_PROGRESS'::public.championship_status THEN
    RAISE EXCEPTION 'As sessões individuais só podem ser operadas com o campeonato em andamento.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS championship_individual_sessions_prevent_review_operations ON public.championship_individual_sessions;
CREATE TRIGGER championship_individual_sessions_prevent_review_operations
BEFORE UPDATE OF status ON public.championship_individual_sessions
FOR EACH ROW EXECUTE FUNCTION public.prevent_review_individual_session_operations();

DO $migration_protect_individual_event_results$
DECLARE
  function_definition TEXT;
  updated_function_definition TEXT;
BEGIN
  SELECT pg_get_functiondef('public.save_championship_individual_event_results(uuid,jsonb)'::regprocedure)
  INTO function_definition;
  updated_function_definition := replace(
    function_definition,
    '  IF current_event.id IS NULL THEN',
    '  IF NOT EXISTS (' || chr(10) ||
    '    SELECT 1' || chr(10) ||
    '    FROM public.championship_individual_events AS events_table' || chr(10) ||
    '    JOIN public.championships AS championships_table ON championships_table.id = events_table.championship_id' || chr(10) ||
    '    WHERE events_table.id = _event_id' || chr(10) ||
    '      AND championships_table.status = ''IN_PROGRESS''::public.championship_status' || chr(10) ||
    '  ) THEN' || chr(10) ||
    '    RAISE EXCEPTION ''Os resultados das provas individuais só podem ser registrados com o campeonato em andamento.'';' || chr(10) ||
    '  END IF;' || chr(10) || chr(10) ||
    '  IF current_event.id IS NULL THEN'
  );

  IF updated_function_definition = function_definition THEN
    RAISE EXCEPTION 'Não foi possível proteger o registro de resultados das provas individuais.';
  END IF;

  EXECUTE updated_function_definition;
END;
$migration_protect_individual_event_results$;


DO $migration_implement_alternate_naipe$
DECLARE
  function_definition TEXT;
  source_block TEXT;
  target_block TEXT;
BEGIN
  SELECT pg_get_functiondef(
    'public.redistribute_bracket_scheduled_matches(uuid)'
      ::regprocedure
  )
  INTO function_definition;

  IF function_definition IS NULL THEN
    RAISE EXCEPTION
      'redistribute_bracket_scheduled_matches(uuid) não existe.';
  END IF;

  IF strpos(
    function_definition,
    'alternate_naipe_sequence_priority'
  ) > 0
  THEN
    RETURN;
  END IF;

  source_block :=
$source$
        END ASC,
        CASE
          WHEN strict_current_knockout_round IS NOT NULL
$source$;

  target_block :=
$target$
        END ASC,

        /*
         * alternate_naipe_sequence_priority
         */

        CASE
          WHEN slot_record.sequence_mode =
              'ALTERNATE_NAIPE'
                ::public.bracket_court_sequence_mode
            AND slot_last_naipe IS NULL
            AND slot_record.primary_naipe IS NOT NULL
            AND pending_matches_table.naipe
              IS DISTINCT FROM
                slot_record.primary_naipe
          THEN 1

          WHEN slot_record.sequence_mode =
              'ALTERNATE_NAIPE'
                ::public.bracket_court_sequence_mode
            AND slot_last_naipe IS NOT NULL
            AND pending_matches_table.naipe
              IS NOT DISTINCT FROM
                slot_last_naipe
          THEN 1

          ELSE 0
        END ASC,

        CASE
          WHEN strict_current_knockout_round IS NOT NULL
$target$;

  IF strpos(
    function_definition,
    source_block
  ) = 0
  THEN
    RAISE EXCEPTION
      'Não foi possível localizar o ponto de ordenação da fila para ALTERNATE_NAIPE.';
  END IF;

  function_definition :=
    replace(
      function_definition,
      source_block,
      target_block
    );

  EXECUTE function_definition;
END;
$migration_implement_alternate_naipe$;


REVOKE ALL ON FUNCTION public.execute_championship_bracket_reconfiguration(uuid,text,jsonb) FROM PUBLIC;

COMMENT ON FUNCTION public.preview_championship_bracket_reconfiguration(uuid,text,jsonb)
IS 'LAJE-150: preview of championship reconfiguration with rollback and blockers, AWS/RDS';
COMMENT ON FUNCTION public.apply_championship_bracket_reconfiguration(uuid,text,jsonb,bigint)
IS 'LAJE-150: revision-guarded championship reconfiguration, AWS/RDS';
