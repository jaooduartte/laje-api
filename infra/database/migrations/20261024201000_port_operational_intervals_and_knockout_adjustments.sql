-- LAJE-150: operational intervals and knockout court adjustments.
-- All mutations require authenticated API permissions and original SQL validation.

-- Original: apply_operational_knockout_schedule_adjustment(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
CREATE OR REPLACE FUNCTION public.apply_operational_knockout_schedule_adjustment(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  source_item RECORD;
  preview_result JSONB;
  representation_adjustments JSONB;
  representation_adjustments_count INTEGER;
  updated_representation_count INTEGER;
BEGIN
  preview_result := public.preview_operational_knockout_schedule_adjustment(
    _bracket_edition_id,
    _payload
  );

  IF jsonb_array_length(COALESCE(preview_result->'blockers', '[]'::JSONB)) > 0 THEN
    RAISE EXCEPTION 'A prévia contém conflitos e não pode ser confirmada.';
  END IF;

  PERFORM public.apply_operational_knockout_schedule_adjustment_base(
    _bracket_edition_id,
    _payload,
    _expected_revision
  );

  PERFORM set_config('app.skip_queue_trigger', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  UPDATE public.matches AS matches_table
  SET scheduled_start_time = (timeline_item.value->>'start_time')::TIMESTAMPTZ
  FROM jsonb_array_elements(COALESCE(preview_result->'timeline', '[]'::JSONB)) AS timeline_item(value)
  WHERE matches_table.id = NULLIF(timeline_item.value->>'match_id', '')::UUID
    AND matches_table.status = 'SCHEDULED'::public.match_status
    AND matches_table.scheduled_start_time IS DISTINCT FROM (timeline_item.value->>'start_time')::TIMESTAMPTZ;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  PERFORM set_config('app.skip_queue_trigger', 'false', true);

  preview_result := public.preview_operational_knockout_schedule_adjustment(
    _bracket_edition_id,
    _payload
  );
  representation_adjustments := COALESCE(
    preview_result->'representation_adjustments',
    '[]'::JSONB
  );

  SELECT count(*)::INTEGER
  INTO representation_adjustments_count
  FROM jsonb_array_elements(representation_adjustments);

  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  UPDATE public.matches AS matches_table
  SET manual_representation_mode = 'CO'
  FROM (
    SELECT DISTINCT (adjustment.value->>'match_id')::UUID AS match_id
    FROM jsonb_array_elements(representation_adjustments) AS adjustment(value)
  ) AS adjustments
  WHERE matches_table.id = adjustments.match_id
    AND matches_table.status = 'SCHEDULED'::public.match_status
    AND COALESCE(matches_table.manual_representation_mode, 'AUTO') <> 'CO';

  GET DIAGNOSTICS updated_representation_count = ROW_COUNT;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);

  IF updated_representation_count <> representation_adjustments_count THEN
    RAISE EXCEPTION 'Não foi possível forçar a representação da CO para todos os jogos planejados.';
  END IF;

  SELECT
    editions_table.championship_id,
    editions_table.season_year,
    reservations_table.scheduled_date,
    reservations_table.location_name,
    reservations_table.court_name
  INTO source_item
  FROM public.championship_bracket_editions AS editions_table
  JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.bracket_edition_id = editions_table.id
  JOIN public.championship_bracket_knockout_schedule_reservations AS reservations_table
    ON reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
    AND reservations_table.competition_id = bracket_matches_table.competition_id
    AND reservations_table.round_number = bracket_matches_table.round_number
    AND reservations_table.slot_number = bracket_matches_table.slot_number
    AND reservations_table.is_third_place = bracket_matches_table.is_third_place
  WHERE editions_table.id = _bracket_edition_id
    AND bracket_matches_table.id = ((_payload->'bracket_match_ids'->>0)::UUID);

  IF source_item.championship_id IS NULL THEN
    RAISE EXCEPTION 'O item inicial não foi localizado após o ajuste operacional.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.championship_bracket_knockout_schedule_reservations AS reservations_table
      ON reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
      AND reservations_table.competition_id = bracket_matches_table.competition_id
      AND reservations_table.round_number = bracket_matches_table.round_number
      AND reservations_table.slot_number = bracket_matches_table.slot_number
      AND reservations_table.is_third_place = bracket_matches_table.is_third_place
    JOIN public.matches AS matches_table
      ON matches_table.championship_id = source_item.championship_id
      AND matches_table.season_year = source_item.season_year
      AND matches_table.status = 'SCHEDULED'::public.match_status
      AND matches_table.scheduled_date = reservations_table.scheduled_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(reservations_table.location_name)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(reservations_table.court_name)
      AND matches_table.id IS DISTINCT FROM bracket_matches_table.match_id
      AND matches_table.start_time < reservations_table.end_at
      AND matches_table.end_time > reservations_table.start_at
    WHERE bracket_matches_table.bracket_edition_id = _bracket_edition_id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND bracket_matches_table.is_bye IS NOT TRUE
      AND reservations_table.scheduled_date = source_item.scheduled_date
      AND public.normalize_bracket_entity_name(reservations_table.location_name) = public.normalize_bracket_entity_name(source_item.location_name)
      AND public.normalize_bracket_entity_name(reservations_table.court_name) = public.normalize_bracket_entity_name(source_item.court_name)
      AND reservations_table.start_at > now()
  ) THEN
    RAISE EXCEPTION 'A programação ajustada sobrepõe outra partida agendada na mesma quadra.';
  END IF;

  IF representation_adjustments_count > 0 THEN
    PERFORM public.write_admin_action_log(
      'UPDATE'::public.admin_action_type,
      'public.matches',
      _bracket_edition_id::TEXT,
      'Forçou a representação da CO para conflitos consecutivos na mesma quadra.',
      jsonb_build_object('representation_adjustments', representation_adjustments),
      jsonb_build_object('representation_adjustments', representation_adjustments),
      jsonb_build_object(
        'championship_id', source_item.championship_id,
        'season_year', source_item.season_year,
        'reprogramming_revision', _expected_revision
      )
    );
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.skip_queue_trigger', 'false', true);
    RAISE;
END;
$function$;

-- Original: apply_operational_knockout_schedule_adjustment_base(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
CREATE OR REPLACE FUNCTION public.apply_operational_knockout_schedule_adjustment_base(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  edition_record RECORD;
  preview JSONB;
  timeline_item JSONB;
  break_action TEXT;
  break_id_value TEXT;
  break_scope_type public.bracket_day_break_scope_type;
  break_start_time_value TIME;
  break_end_time_value TIME;
  day_record RECORD;
  target_court_id UUID;
  original_timeline JSONB;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para ajustar a programação.';
  END IF;

  SELECT * INTO edition_record
  FROM public.championship_bracket_editions
  WHERE id = _bracket_edition_id
  FOR UPDATE;

  IF edition_record.id IS NULL THEN
    RAISE EXCEPTION 'Edição de chaveamento inválida.';
  END IF;

  IF edition_record.reprogramming_revision <> _expected_revision THEN
    RAISE EXCEPTION 'A programação foi alterada por outro usuário. Gere uma nova prévia.';
  END IF;

  PERFORM 1
  FROM public.championship_bracket_matches AS bracket_matches_table
  JOIN public.championship_bracket_knockout_schedule_reservations AS reservations_table
    ON reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
    AND reservations_table.competition_id = bracket_matches_table.competition_id
    AND reservations_table.round_number = bracket_matches_table.round_number
    AND reservations_table.slot_number = bracket_matches_table.slot_number
    AND reservations_table.is_third_place = bracket_matches_table.is_third_place
  WHERE bracket_matches_table.id IN (
    SELECT value::UUID
    FROM jsonb_array_elements_text(COALESCE(_payload->'bracket_match_ids', '[]'::jsonb)) AS value
  )
  FOR UPDATE OF bracket_matches_table, reservations_table;

  preview := public.preview_operational_knockout_schedule_adjustment(
    _bracket_edition_id,
    _payload
  );

  IF jsonb_array_length(COALESCE(preview->'blockers', '[]'::jsonb)) > 0 THEN
    RAISE EXCEPTION 'A prévia contém conflitos e não pode ser confirmada.';
  END IF;

  IF COALESCE((preview->>'extends_day_end')::BOOLEAN, false)
    AND COALESCE((_payload->>'accept_day_end_extension')::BOOLEAN, false) IS NOT TRUE
  THEN
    RAISE EXCEPTION 'Confirme a ampliação do horário final do dia para salvar a programação.';
  END IF;

  SELECT * INTO day_record
  FROM public.championship_bracket_days
  WHERE bracket_edition_id = _bracket_edition_id
    AND event_date = ((preview->'timeline'->0->>'scheduled_date')::DATE)
  FOR UPDATE;

  SELECT reservations_table.bracket_court_id
  INTO target_court_id
  FROM public.championship_bracket_matches AS bracket_matches_table
  JOIN public.championship_bracket_knockout_schedule_reservations AS reservations_table
    ON reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
    AND reservations_table.competition_id = bracket_matches_table.competition_id
    AND reservations_table.round_number = bracket_matches_table.round_number
    AND reservations_table.slot_number = bracket_matches_table.slot_number
    AND reservations_table.is_third_place = bracket_matches_table.is_third_place
  WHERE bracket_matches_table.id = ((_payload->'bracket_match_ids'->>0)::UUID);

  FOR timeline_item IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(preview->'timeline', '[]'::jsonb))
  LOOP
    PERFORM 1
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.championship_bracket_knockout_schedule_reservations AS reservations_table
      ON reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
      AND reservations_table.competition_id = bracket_matches_table.competition_id
      AND reservations_table.round_number = bracket_matches_table.round_number
      AND reservations_table.slot_number = bracket_matches_table.slot_number
      AND reservations_table.is_third_place = bracket_matches_table.is_third_place
    WHERE bracket_matches_table.id = (timeline_item->>'bracket_match_id')::UUID
    FOR UPDATE OF bracket_matches_table, reservations_table;
  END LOOP;

  preview := public.preview_operational_knockout_schedule_adjustment(
    _bracket_edition_id,
    _payload
  );

  IF jsonb_array_length(COALESCE(preview->'blockers', '[]'::jsonb)) > 0 THEN
    RAISE EXCEPTION 'A programação mudou durante a validação e agora possui conflitos.';
  END IF;

  PERFORM set_config('app.skip_queue_trigger', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  FOR timeline_item IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(preview->'timeline', '[]'::jsonb))
  LOOP
    UPDATE public.championship_bracket_knockout_schedule_reservations AS reservations_table
    SET
      start_at = (timeline_item->>'start_time')::TIMESTAMPTZ,
      end_at = (timeline_item->>'end_time')::TIMESTAMPTZ,
      duration_minutes = (timeline_item->>'duration_minutes')::INTEGER,
      queue_position = (timeline_item->>'queue_position')::INTEGER,
      scheduled_slot = (timeline_item->>'scheduled_slot')::INTEGER
    FROM public.championship_bracket_matches AS bracket_matches_table
    WHERE bracket_matches_table.id = (timeline_item->>'bracket_match_id')::UUID
      AND reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
      AND reservations_table.competition_id = bracket_matches_table.competition_id
      AND reservations_table.round_number = bracket_matches_table.round_number
      AND reservations_table.slot_number = bracket_matches_table.slot_number
      AND reservations_table.is_third_place = bracket_matches_table.is_third_place;

    UPDATE public.championship_bracket_matches AS target_bracket_matches
    SET
      planned_scheduled_date = (timeline_item->>'scheduled_date')::DATE,
      planned_start_time = ((timeline_item->>'start_time')::TIMESTAMPTZ AT TIME ZONE 'America/Sao_Paulo')::TIME,
      planned_end_time = ((timeline_item->>'end_time')::TIMESTAMPTZ AT TIME ZONE 'America/Sao_Paulo')::TIME,
      planned_queue_position = (timeline_item->>'queue_position')::INTEGER,
      planned_scheduled_slot = (timeline_item->>'scheduled_slot')::INTEGER,
      planned_location_group_id = reservations_table.location_group_id,
      planned_court_group_id = reservations_table.court_group_id,
      planned_location_name = reservations_table.location_name,
      planned_court_name = reservations_table.court_name
    FROM public.championship_bracket_knockout_schedule_reservations AS reservations_table
    JOIN public.championship_bracket_matches AS reservation_bracket_matches_table
      ON reservation_bracket_matches_table.bracket_edition_id = reservations_table.bracket_edition_id
      AND reservation_bracket_matches_table.competition_id = reservations_table.competition_id
      AND reservation_bracket_matches_table.round_number = reservations_table.round_number
      AND reservation_bracket_matches_table.slot_number = reservations_table.slot_number
      AND reservation_bracket_matches_table.is_third_place = reservations_table.is_third_place
    WHERE target_bracket_matches.id = (timeline_item->>'bracket_match_id')::UUID
      AND reservation_bracket_matches_table.id = target_bracket_matches.id;

    UPDATE public.matches
    SET
      scheduled_date = (timeline_item->>'scheduled_date')::DATE,
      start_time = (timeline_item->>'start_time')::TIMESTAMPTZ,
      end_time = (timeline_item->>'end_time')::TIMESTAMPTZ,
      queue_position = (timeline_item->>'queue_position')::INTEGER,
      scheduled_slot = (timeline_item->>'scheduled_slot')::INTEGER
    WHERE id = NULLIF(timeline_item->>'match_id', '')::UUID
      AND status = 'SCHEDULED'::public.match_status;
  END LOOP;

  break_action := upper(trim(COALESCE(_payload->'break'->>'action', 'KEEP')));
  break_id_value := NULLIF(trim(COALESCE(_payload->'break'->>'id', '')), '');
  break_scope_type := CASE upper(trim(COALESCE(_payload->'break'->>'scope_type', 'ALL_COURTS')))
    WHEN 'COURT' THEN 'COURT'::public.bracket_day_break_scope_type
    ELSE 'ALL_COURTS'::public.bracket_day_break_scope_type
  END;
  break_start_time_value := NULLIF(_payload->'break'->>'start_time', '')::TIME;
  break_end_time_value := NULLIF(_payload->'break'->>'end_time', '')::TIME;

  IF break_action IN ('REMOVE', 'UPSERT') AND break_id_value LIKE 'legacy:%' THEN
    UPDATE public.championship_bracket_days
    SET break_start_time = NULL, break_end_time = NULL
    WHERE id = day_record.id;
  END IF;

  IF break_action = 'REMOVE' AND break_id_value IS NOT NULL AND break_id_value NOT LIKE 'legacy:%' THEN
    DELETE FROM public.championship_bracket_day_breaks
    WHERE id = break_id_value::UUID
      AND bracket_day_id = day_record.id;
  ELSIF break_action = 'UPSERT' THEN
    IF break_id_value IS NOT NULL AND break_id_value NOT LIKE 'legacy:%' THEN
      UPDATE public.championship_bracket_day_breaks
      SET
        scope_type = break_scope_type,
        break_start_time = break_start_time_value,
        break_end_time = break_end_time_value,
        bracket_court_id = CASE WHEN break_scope_type = 'COURT' THEN target_court_id ELSE NULL END
      WHERE id = break_id_value::UUID
        AND bracket_day_id = day_record.id;
    ELSE
      INSERT INTO public.championship_bracket_day_breaks (
        bracket_day_id,
        scope_type,
        break_start_time,
        break_end_time,
        position,
        bracket_court_id
      ) VALUES (
        day_record.id,
        break_scope_type,
        break_start_time_value,
        break_end_time_value,
        COALESCE((
          SELECT max(position) + 1
          FROM public.championship_bracket_day_breaks
          WHERE bracket_day_id = day_record.id
        ), 1),
        CASE WHEN break_scope_type = 'COURT' THEN target_court_id ELSE NULL END
      );
    END IF;
  END IF;

  IF (preview->>'extends_day_end')::BOOLEAN THEN
    UPDATE public.championship_bracket_days
    SET end_time = ((preview->>'day_end_after')::TIMESTAMPTZ AT TIME ZONE 'America/Sao_Paulo')::TIME
    WHERE id = day_record.id;
  END IF;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  PERFORM set_config('app.skip_queue_trigger', 'false', true);

  UPDATE public.championship_bracket_editions
  SET reprogramming_revision = reprogramming_revision + 1
  WHERE id = _bracket_edition_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'bracket_match_id', timeline_json.value->>'bracket_match_id',
      'match_id', timeline_json.value->>'match_id',
      'start_time', timeline_json.value->>'original_start_time',
      'end_time', timeline_json.value->>'original_end_time',
      'duration_minutes', timeline_json.value->>'original_duration_minutes',
      'queue_position', timeline_json.value->>'queue_position',
      'scheduled_slot', timeline_json.value->>'scheduled_slot'
    )
  ), '[]'::JSONB)
  INTO original_timeline
  FROM jsonb_array_elements(COALESCE(preview->'timeline', '[]'::JSONB)) AS timeline_json;

  PERFORM public.write_admin_action_log(
    'UPDATE'::public.admin_action_type,
    'public.championship_bracket_knockout_schedule_reservations',
    _bracket_edition_id::TEXT,
    'Ajustou a programação operacional futura do mata-mata.',
    jsonb_build_object(
      'timeline', original_timeline,
      'break', preview->'break',
      'day_end_before', preview->'day_end_before'
    ),
    jsonb_build_object(
      'timeline', preview->'timeline',
      'break', preview->'break',
      'day_end_after', preview->'day_end_after'
    ),
    jsonb_build_object(
      'championship_id', edition_record.championship_id,
      'season_year', edition_record.season_year,
      'reprogramming_revision', _expected_revision
    )
  );
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.skip_queue_trigger', 'false', true);
    RAISE;
END;
$function$;

-- Original: apply_operational_schedule_interval(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
CREATE OR REPLACE FUNCTION public.apply_operational_schedule_interval(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  preview JSONB;
  edition_record RECORD;
  day_record RECORD;
  interval_action TEXT;
  interval_id_value TEXT;
  scope_type_value public.bracket_day_break_scope_type;
  target_court_ids UUID[];
  start_time_value TIME;
  end_time_value TIME;
  first_general_break RECORD;
  timeline_item JSONB;
  original_timeline JSONB;
BEGIN
  IF auth.uid() IS NULL
    OR NOT public.has_admin_tab_access('championship_schedule'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para ajustar os intervalos da agenda.';
  END IF;

  SELECT editions_table.id, editions_table.championship_id, editions_table.season_year, editions_table.reprogramming_revision
  INTO edition_record
  FROM public.championship_bracket_editions AS editions_table
  JOIN public.championships AS championships_table ON championships_table.id = editions_table.championship_id
  WHERE editions_table.id = _bracket_edition_id
    AND championships_table.status IN ('REVIEW'::public.championship_status, 'IN_PROGRESS'::public.championship_status)
  FOR UPDATE OF editions_table;

  IF edition_record.id IS NULL THEN
    RAISE EXCEPTION 'A programação operacional não está disponível para este campeonato.';
  END IF;

  IF edition_record.reprogramming_revision <> _expected_revision THEN
    RAISE EXCEPTION 'A agenda foi alterada desde a prévia. Revise o impacto novamente.';
  END IF;

  preview := public.build_operational_schedule_interval_preview(_bracket_edition_id, _payload);

  IF jsonb_array_length(COALESCE(preview->'blockers', '[]'::JSONB)) > 0 THEN
    RAISE EXCEPTION 'A reorganização possui bloqueios e não pode ser confirmada.';
  END IF;

  IF COALESCE((preview->>'extends_day_end')::BOOLEAN, false)
    AND COALESCE((_payload->>'accept_day_end_extension')::BOOLEAN, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Confirme a ampliação do fim do dia antes de aplicar.';
  END IF;

  SELECT * INTO day_record
  FROM public.championship_bracket_days
  WHERE bracket_edition_id = _bracket_edition_id
    AND event_date = (_payload->>'event_date')::DATE
  FOR UPDATE;

  interval_action := upper(trim(COALESCE(_payload->>'action', '')));
  interval_id_value := NULLIF(trim(COALESCE(_payload->>'interval_id', '')), '');
  scope_type_value := CASE upper(trim(COALESCE(_payload->>'scope_type', 'ALL_COURTS')))
    WHEN 'COURT' THEN 'COURT'::public.bracket_day_break_scope_type
    ELSE 'ALL_COURTS'::public.bracket_day_break_scope_type
  END;
  start_time_value := NULLIF(trim(COALESCE(_payload->>'start_time', '')), '')::TIME;
  end_time_value := NULLIF(trim(COALESCE(_payload->>'end_time', '')), '')::TIME;

  SELECT COALESCE(array_agg(value::UUID), ARRAY[]::UUID[])
  INTO target_court_ids
  FROM jsonb_array_elements_text(COALESCE(_payload->'court_ids', '[]'::JSONB)) AS value;

  IF interval_action = 'REMOVE' THEN
    IF interval_id_value LIKE 'legacy:%' THEN
      UPDATE public.championship_bracket_days
      SET break_start_time = NULL, break_end_time = NULL
      WHERE id = day_record.id;

      INSERT INTO public.championship_bracket_day_breaks (
        bracket_day_id,
        break_start_time,
        break_end_time,
        position,
        scope_type,
        bracket_court_id
      ) VALUES (
        day_record.id,
        start_time_value,
        end_time_value,
        COALESCE((SELECT max(position) + 1 FROM public.championship_bracket_day_breaks WHERE bracket_day_id = day_record.id), 1),
        'ALL_COURTS'::public.bracket_day_break_scope_type,
        NULL
      );
    ELSE
      DELETE FROM public.championship_bracket_day_breaks
      WHERE id = interval_id_value::UUID
        AND bracket_day_id = day_record.id;
    END IF;
  ELSE
    IF interval_id_value LIKE 'legacy:%' THEN
      UPDATE public.championship_bracket_days
      SET break_start_time = NULL, break_end_time = NULL
      WHERE id = day_record.id;
    ELSIF interval_id_value IS NOT NULL THEN
      UPDATE public.championship_bracket_day_breaks
      SET break_start_time = start_time_value,
          break_end_time = end_time_value
      WHERE id = interval_id_value::UUID
        AND bracket_day_id = day_record.id;
    ELSIF scope_type_value = 'ALL_COURTS'::public.bracket_day_break_scope_type THEN
      INSERT INTO public.championship_bracket_day_breaks (
        bracket_day_id,
        break_start_time,
        break_end_time,
        position,
        scope_type,
        bracket_court_id
      ) VALUES (
        day_record.id,
        start_time_value,
        end_time_value,
        COALESCE((SELECT max(position) + 1 FROM public.championship_bracket_day_breaks WHERE bracket_day_id = day_record.id), 1),
        'ALL_COURTS'::public.bracket_day_break_scope_type,
        NULL
      );
    ELSE
      INSERT INTO public.championship_bracket_day_breaks (
        bracket_day_id,
        break_start_time,
        break_end_time,
        position,
        scope_type,
        bracket_court_id
      )
      SELECT
        day_record.id,
        start_time_value,
        end_time_value,
        COALESCE((SELECT max(position) FROM public.championship_bracket_day_breaks WHERE bracket_day_id = day_record.id), 0) + row_number() OVER (),
        'COURT'::public.bracket_day_break_scope_type,
        court_id
      FROM unnest(target_court_ids) AS court_id;
    END IF;
  END IF;

  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);
  PERFORM set_config('app.skip_queue_trigger', 'true', true);
  PERFORM set_config('app.allow_operational_schedule_interval_match_update', 'true', true);
  PERFORM set_config('app.allow_manual_schedule_override_update', 'true', true);

  FOR timeline_item IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(preview->'timeline', '[]'::JSONB))
  LOOP
    IF timeline_item->>'item_type' = 'MATCH' THEN
      UPDATE public.matches
      SET start_time = (timeline_item->>'start_time')::TIMESTAMPTZ,
          end_time = (timeline_item->>'end_time')::TIMESTAMPTZ,
          queue_position = (timeline_item->>'queue_position')::INTEGER,
          scheduled_slot = (timeline_item->>'scheduled_slot')::INTEGER
      WHERE id = (timeline_item->>'item_id')::UUID;
    END IF;

    UPDATE public.championship_bracket_matches
    SET planned_start_time = ((timeline_item->>'start_time')::TIMESTAMPTZ AT TIME ZONE 'America/Sao_Paulo')::TIME,
        planned_end_time = ((timeline_item->>'end_time')::TIMESTAMPTZ AT TIME ZONE 'America/Sao_Paulo')::TIME,
        planned_queue_position = (timeline_item->>'queue_position')::INTEGER,
        planned_scheduled_slot = (timeline_item->>'scheduled_slot')::INTEGER
    WHERE id = (timeline_item->>'item_id')::UUID
      OR match_id = (timeline_item->>'item_id')::UUID;
  END LOOP;

  UPDATE public.championship_bracket_knockout_schedule_reservations AS reservations_table
  SET start_at = public.combine_bracket_schedule_timestamp(day_record.event_date, bracket_matches_table.planned_start_time),
      end_at = public.combine_bracket_schedule_timestamp(day_record.event_date, bracket_matches_table.planned_end_time)
  FROM public.championship_bracket_matches AS bracket_matches_table
  WHERE bracket_matches_table.bracket_edition_id = _bracket_edition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.planned_scheduled_date = day_record.event_date
    AND reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
    AND reservations_table.competition_id = bracket_matches_table.competition_id
    AND reservations_table.round_number = bracket_matches_table.round_number
    AND reservations_table.slot_number = bracket_matches_table.slot_number
    AND reservations_table.is_third_place = bracket_matches_table.is_third_place;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  PERFORM set_config('app.skip_queue_trigger', 'false', true);
  PERFORM set_config('app.allow_operational_schedule_interval_match_update', 'false', true);
  PERFORM set_config('app.allow_manual_schedule_override_update', 'false', true);

  UPDATE public.championship_bracket_editions
  SET reprogramming_revision = reprogramming_revision + 1
  WHERE id = _bracket_edition_id;

  SELECT * INTO first_general_break
  FROM public.championship_bracket_day_breaks
  WHERE bracket_day_id = day_record.id
    AND scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
  ORDER BY position, break_start_time
  LIMIT 1;

  UPDATE public.championship_bracket_days
  SET break_start_time = first_general_break.break_start_time,
      break_end_time = first_general_break.break_end_time,
      end_time = GREATEST(
        end_time,
        ((preview->>'day_end_after')::TIMESTAMPTZ AT TIME ZONE 'America/Sao_Paulo')::TIME
      )
  WHERE id = day_record.id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'item_id', value->>'item_id',
    'start_time', value->>'original_start_time',
    'end_time', value->>'original_end_time',
    'queue_position', value->>'queue_position',
    'scheduled_slot', value->>'scheduled_slot'
  )), '[]'::JSONB)
  INTO original_timeline
  FROM jsonb_array_elements(COALESCE(preview->'timeline', '[]'::JSONB));

  PERFORM public.write_admin_action_log(
    'UPDATE'::public.admin_action_type,
    'public.championship_bracket_day_breaks',
    day_record.id::TEXT,
    'Ajustou intervalos operacionais da agenda.',
    jsonb_build_object('timeline', original_timeline, 'breaks', preview->'breaks_before', 'day_end', preview->'day_end_before'),
    jsonb_build_object('timeline', preview->'timeline', 'breaks', preview->'breaks_after', 'day_end', preview->'day_end_after'),
    jsonb_build_object('championship_id', edition_record.championship_id, 'season_year', edition_record.season_year, 'reprogramming_revision', _expected_revision)
  );
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.skip_queue_trigger', 'false', true);
    PERFORM set_config('app.allow_operational_schedule_interval_match_update', 'false', true);
  PERFORM set_config('app.allow_manual_schedule_override_update', 'false', true);
    RAISE;
END;
$function$;

-- Original: build_operational_schedule_interval_preview(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.build_operational_schedule_interval_preview(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  edition_record RECORD;
  day_record RECORD;
  interval_action TEXT;
  interval_id_value TEXT;
  scope_type_value public.bracket_day_break_scope_type;
  start_time_value TIME;
  end_time_value TIME;
  anchor_time_value TIME;
  requested_court_ids UUID[];
  target_court_ids UUID[];
  interval_record RECORD;
  item_record RECORD;
  break_record RECORD;
  cursor_at TIMESTAMPTZ;
  candidate_start_at TIMESTAMPTZ;
  candidate_end_at TIMESTAMPTZ;
  proposed_day_end_at TIMESTAMPTZ;
  blockers JSONB := '[]'::JSONB;
  timeline JSONB := '[]'::JSONB;
BEGIN
  IF auth.uid() IS NULL
    OR NOT public.has_admin_tab_access('championship_schedule'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para ajustar os intervalos da agenda.';
  END IF;

  interval_action := upper(trim(COALESCE(_payload->>'action', '')));
  interval_id_value := NULLIF(trim(COALESCE(_payload->>'interval_id', '')), '');
  scope_type_value := CASE upper(trim(COALESCE(_payload->>'scope_type', 'ALL_COURTS')))
    WHEN 'COURT' THEN 'COURT'::public.bracket_day_break_scope_type
    ELSE 'ALL_COURTS'::public.bracket_day_break_scope_type
  END;
  start_time_value := NULLIF(trim(COALESCE(_payload->>'start_time', '')), '')::TIME;
  end_time_value := NULLIF(trim(COALESCE(_payload->>'end_time', '')), '')::TIME;

  IF interval_action NOT IN ('UPSERT', 'REMOVE') THEN
    RAISE EXCEPTION 'Informe uma ação válida para o intervalo.';
  END IF;

  IF interval_action = 'UPSERT' AND (
    start_time_value IS NULL
    OR end_time_value IS NULL
    OR end_time_value <= start_time_value
  ) THEN
    RAISE EXCEPTION 'Informe início e fim válidos para o intervalo.';
  END IF;

  SELECT
    editions_table.id,
    editions_table.championship_id,
    editions_table.season_year,
    editions_table.reprogramming_revision,
    editions_table.payload_snapshot,
    championships_table.status
  INTO edition_record
  FROM public.championship_bracket_editions AS editions_table
  JOIN public.championships AS championships_table
    ON championships_table.id = editions_table.championship_id
  WHERE editions_table.id = _bracket_edition_id;

  IF edition_record.id IS NULL
    OR edition_record.status NOT IN (
      'REVIEW'::public.championship_status,
      'IN_PROGRESS'::public.championship_status
    ) THEN
    RAISE EXCEPTION 'Os intervalos operacionais só podem ser ajustados em revisão ou durante o campeonato.';
  END IF;

  SELECT * INTO day_record
  FROM public.championship_bracket_days
  WHERE bracket_edition_id = _bracket_edition_id
    AND event_date = NULLIF(trim(COALESCE(_payload->>'event_date', '')), '')::DATE;

  IF day_record.id IS NULL THEN
    RAISE EXCEPTION 'Selecione um dia configurado da agenda.';
  END IF;

  SELECT COALESCE(array_agg(value::UUID), ARRAY[]::UUID[])
  INTO requested_court_ids
  FROM jsonb_array_elements_text(COALESCE(_payload->'court_ids', '[]'::JSONB)) AS value;

  DROP TABLE IF EXISTS operational_schedule_interval_breaks;
  CREATE TEMP TABLE operational_schedule_interval_breaks (
    id TEXT PRIMARY KEY,
    scope_type public.bracket_day_break_scope_type NOT NULL,
    bracket_court_id UUID NULL,
    break_start_time TIME NOT NULL,
    break_end_time TIME NOT NULL,
    is_legacy BOOLEAN NOT NULL DEFAULT false
  ) ON COMMIT DROP;

  INSERT INTO operational_schedule_interval_breaks (
    id,
    scope_type,
    bracket_court_id,
    break_start_time,
    break_end_time
  )
  SELECT
    breaks_table.id::TEXT,
    breaks_table.scope_type,
    breaks_table.bracket_court_id,
    breaks_table.break_start_time,
    breaks_table.break_end_time
  FROM public.championship_bracket_day_breaks AS breaks_table
  WHERE breaks_table.bracket_day_id = day_record.id;

  IF day_record.break_start_time IS NOT NULL
    AND day_record.break_end_time IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM operational_schedule_interval_breaks
      WHERE scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
    ) THEN
    INSERT INTO operational_schedule_interval_breaks (
      id,
      scope_type,
      bracket_court_id,
      break_start_time,
      break_end_time,
      is_legacy
    ) VALUES (
      concat('legacy:', day_record.id),
      'ALL_COURTS'::public.bracket_day_break_scope_type,
      NULL,
      day_record.break_start_time,
      day_record.break_end_time,
      true
    );
  END IF;

  SELECT * INTO interval_record
  FROM operational_schedule_interval_breaks
  WHERE id = interval_id_value;

  IF interval_action = 'REMOVE' AND interval_record.id IS NULL THEN
    RAISE EXCEPTION 'Selecione um intervalo existente para remover.';
  END IF;

  IF interval_id_value IS NOT NULL AND interval_record.id IS NULL THEN
    RAISE EXCEPTION 'O intervalo selecionado não pertence a este dia.';
  END IF;

  IF interval_record.id IS NOT NULL THEN
    scope_type_value := interval_record.scope_type;
    IF interval_action = 'REMOVE' THEN
      anchor_time_value := interval_record.break_start_time;
      DELETE FROM operational_schedule_interval_breaks WHERE id = interval_record.id;
    ELSE
      anchor_time_value := LEAST(interval_record.break_start_time, start_time_value);
      DELETE FROM operational_schedule_interval_breaks WHERE id = interval_record.id;
    END IF;
  ELSE
    anchor_time_value := start_time_value;
  END IF;

  IF scope_type_value = 'ALL_COURTS'::public.bracket_day_break_scope_type THEN
    SELECT COALESCE(array_agg(courts_table.id ORDER BY locations_table.position, courts_table.position), ARRAY[]::UUID[])
    INTO target_court_ids
    FROM public.championship_bracket_courts AS courts_table
    JOIN public.championship_bracket_locations AS locations_table
      ON locations_table.id = courts_table.bracket_location_id
    WHERE locations_table.bracket_day_id = day_record.id;
  ELSIF interval_record.id IS NOT NULL THEN
    target_court_ids := ARRAY[interval_record.bracket_court_id];
  ELSE
    target_court_ids := requested_court_ids;
  END IF;

  IF cardinality(target_court_ids) = 0 THEN
    RAISE EXCEPTION 'Selecione ao menos uma quadra para o intervalo específico.';
  END IF;

  IF cardinality(target_court_ids) <> (
    SELECT count(*)
    FROM public.championship_bracket_courts AS courts_table
    JOIN public.championship_bracket_locations AS locations_table
      ON locations_table.id = courts_table.bracket_location_id
    WHERE locations_table.bracket_day_id = day_record.id
      AND courts_table.id = ANY(target_court_ids)
  ) THEN
    RAISE EXCEPTION 'Uma das quadras selecionadas não pertence ao dia informado.';
  END IF;

  IF interval_action = 'UPSERT' THEN
    IF start_time_value < day_record.start_time THEN
      RAISE EXCEPTION 'O intervalo não pode começar antes do início do dia.';
    END IF;

    INSERT INTO operational_schedule_interval_breaks (
      id,
      scope_type,
      bracket_court_id,
      break_start_time,
      break_end_time
    )
    SELECT
      concat('new-', court_id),
      scope_type_value,
      CASE WHEN scope_type_value = 'COURT'::public.bracket_day_break_scope_type THEN court_id ELSE NULL END,
      start_time_value,
      end_time_value
    FROM unnest(
      CASE
        WHEN scope_type_value = 'ALL_COURTS'::public.bracket_day_break_scope_type THEN ARRAY[target_court_ids[1]]
        ELSE target_court_ids
      END
    ) AS court_id;
  END IF;

  DROP TABLE IF EXISTS operational_schedule_interval_items;
  CREATE TEMP TABLE operational_schedule_interval_items (
    item_id UUID PRIMARY KEY,
    match_id UUID NULL,
    bracket_match_id UUID NULL,
    item_type TEXT NOT NULL,
    match_status TEXT NULL,
    sport_id UUID NULL,
    naipe public.match_naipe NULL,
    home_team_id UUID NULL,
    away_team_id UUID NULL,
    manual_representation_mode TEXT NULL,
    bracket_court_id UUID NOT NULL,
    location_name TEXT NOT NULL,
    court_name TEXT NOT NULL,
    label TEXT NOT NULL,
    original_start_at TIMESTAMPTZ NOT NULL,
    original_end_at TIMESTAMPTZ NOT NULL,
    planned_start_at TIMESTAMPTZ NULL,
    planned_end_at TIMESTAMPTZ NULL,
    planned_queue_position INTEGER NULL,
    planned_scheduled_slot INTEGER NULL
  ) ON COMMIT DROP;

  INSERT INTO operational_schedule_interval_items (
    item_id,
    match_id,
    bracket_match_id,
    item_type,
    match_status,
    sport_id,
    naipe,
    home_team_id,
    away_team_id,
    manual_representation_mode,
    bracket_court_id,
    location_name,
    court_name,
    label,
    original_start_at,
    original_end_at
  )
  SELECT
    matches_table.id,
    matches_table.id,
    bracket_matches_table.id,
    'MATCH',
    matches_table.status::TEXT,
    matches_table.sport_id,
    matches_table.naipe,
    matches_table.home_team_id,
    matches_table.away_team_id,
    matches_table.manual_representation_mode,
    courts_table.id,
    locations_table.name,
    courts_table.name,
    concat_ws(' × ', home_teams_table.name, away_teams_table.name),
    matches_table.start_time,
    matches_table.start_time + make_interval(mins => GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1))
  FROM public.matches AS matches_table
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.bracket_day_id = day_record.id
    AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(matches_table.location)
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
    AND public.normalize_bracket_entity_name(courts_table.name) = public.normalize_bracket_entity_name(matches_table.court_name)
  LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.match_id = matches_table.id
    AND bracket_matches_table.bracket_edition_id = _bracket_edition_id
  LEFT JOIN public.championship_sports AS championship_sports_table
    ON championship_sports_table.championship_id = matches_table.championship_id
    AND championship_sports_table.sport_id = matches_table.sport_id
  LEFT JOIN public.teams AS home_teams_table ON home_teams_table.id = matches_table.home_team_id
  LEFT JOIN public.teams AS away_teams_table ON away_teams_table.id = matches_table.away_team_id
  WHERE matches_table.championship_id = edition_record.championship_id
    AND matches_table.season_year = edition_record.season_year
    AND matches_table.scheduled_date = day_record.event_date
    AND matches_table.start_time IS NOT NULL
    AND courts_table.id = ANY(target_court_ids)
    AND COALESCE(matches_table.is_pending_manual_relocation, false) = false;

  INSERT INTO operational_schedule_interval_items (
    item_id,
    match_id,
    bracket_match_id,
    item_type,
    match_status,
    sport_id,
    naipe,
    home_team_id,
    away_team_id,
    manual_representation_mode,
    bracket_court_id,
    location_name,
    court_name,
    label,
    original_start_at,
    original_end_at
  )
  SELECT
    bracket_matches_table.id,
    NULL,
    bracket_matches_table.id,
    'KNOCKOUT_PLACEHOLDER',
    NULL,
    competitions_table.sport_id,
    competitions_table.naipe,
    NULL,
    NULL,
    NULL,
    courts_table.id,
    locations_table.name,
    courts_table.name,
    concat('A definir • ', COALESCE(sports_table.name, 'Mata-mata')),
    public.combine_bracket_schedule_timestamp(day_record.event_date, bracket_matches_table.planned_start_time),
    public.combine_bracket_schedule_timestamp(
      day_record.event_date,
      COALESCE(
        bracket_matches_table.planned_end_time,
        bracket_matches_table.planned_start_time + make_interval(mins => GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1))
      )
    )
  FROM public.championship_bracket_matches AS bracket_matches_table
  JOIN public.championship_bracket_competitions AS competitions_table
    ON competitions_table.id = bracket_matches_table.competition_id
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.bracket_day_id = day_record.id
    AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(bracket_matches_table.planned_location_name)
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
    AND public.normalize_bracket_entity_name(courts_table.name) = public.normalize_bracket_entity_name(bracket_matches_table.planned_court_name)
  LEFT JOIN public.championship_sports AS championship_sports_table
    ON championship_sports_table.championship_id = edition_record.championship_id
    AND championship_sports_table.sport_id = competitions_table.sport_id
  LEFT JOIN public.sports AS sports_table ON sports_table.id = competitions_table.sport_id
  WHERE bracket_matches_table.bracket_edition_id = _bracket_edition_id
    AND bracket_matches_table.match_id IS NULL
    AND bracket_matches_table.is_bye IS NOT TRUE
    AND bracket_matches_table.planned_scheduled_date = day_record.event_date
    AND bracket_matches_table.planned_start_time IS NOT NULL
    AND courts_table.id = ANY(target_court_ids);

  FOR item_record IN
    SELECT *
    FROM operational_schedule_interval_items
    ORDER BY bracket_court_id, original_start_at, item_id
  LOOP
    IF item_record.original_end_at <= public.combine_bracket_schedule_timestamp(day_record.event_date, anchor_time_value) THEN
      UPDATE operational_schedule_interval_items
      SET planned_start_at = item_record.original_start_at,
          planned_end_at = item_record.original_end_at
      WHERE item_id = item_record.item_id;
      CONTINUE;
    END IF;

    SELECT max(planned_end_at)
    INTO cursor_at
    FROM operational_schedule_interval_items
    WHERE bracket_court_id = item_record.bracket_court_id
      AND planned_end_at IS NOT NULL;

    candidate_start_at := CASE
      WHEN interval_action = 'REMOVE' THEN GREATEST(
        public.combine_bracket_schedule_timestamp(day_record.event_date, anchor_time_value),
        COALESCE(cursor_at, public.combine_bracket_schedule_timestamp(day_record.event_date, anchor_time_value))
      )
      ELSE GREATEST(
        item_record.original_start_at,
        COALESCE(cursor_at, item_record.original_start_at)
      )
    END;
    candidate_end_at := candidate_start_at + (item_record.original_end_at - item_record.original_start_at);

    FOR break_record IN
      SELECT *
      FROM operational_schedule_interval_breaks
      WHERE scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
        OR bracket_court_id = item_record.bracket_court_id
      ORDER BY break_start_time, break_end_time
    LOOP
      IF candidate_start_at < public.combine_bracket_schedule_timestamp(day_record.event_date, break_record.break_end_time)
        AND candidate_end_at > public.combine_bracket_schedule_timestamp(day_record.event_date, break_record.break_start_time) THEN
        candidate_start_at := public.combine_bracket_schedule_timestamp(day_record.event_date, break_record.break_end_time);
        candidate_end_at := candidate_start_at + (item_record.original_end_at - item_record.original_start_at);
      END IF;
    END LOOP;

    UPDATE operational_schedule_interval_items
    SET planned_start_at = candidate_start_at,
        planned_end_at = candidate_end_at
    WHERE item_id = item_record.item_id;
  END LOOP;

  UPDATE operational_schedule_interval_items AS items_table
  SET planned_queue_position = numbered_items.queue_position,
      planned_scheduled_slot = numbered_items.scheduled_slot
  FROM (
    SELECT
      item_id,
      row_number() OVER (
        PARTITION BY bracket_court_id
        ORDER BY planned_start_at, item_id
      )::INTEGER AS queue_position,
      dense_rank() OVER (
        ORDER BY planned_start_at
      )::INTEGER AS scheduled_slot
    FROM operational_schedule_interval_items
  ) AS numbered_items
  WHERE numbered_items.item_id = items_table.item_id;

  SELECT GREATEST(
    public.combine_bracket_schedule_timestamp(day_record.event_date, day_record.end_time),
    COALESCE(max(planned_end_at), public.combine_bracket_schedule_timestamp(day_record.event_date, day_record.end_time))
  )
  INTO proposed_day_end_at
  FROM operational_schedule_interval_items;

  IF (proposed_day_end_at AT TIME ZONE 'America/Sao_Paulo')::DATE <> day_record.event_date THEN
    blockers := blockers || jsonb_build_array('A reorganização ultrapassa a data selecionada.');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM operational_schedule_interval_items AS items_table
    JOIN public.championship_individual_sessions AS sessions_table
      ON sessions_table.championship_id = edition_record.championship_id
      AND sessions_table.season_year = edition_record.season_year
      AND sessions_table.scheduled_date = day_record.event_date
      AND public.normalize_bracket_entity_name(sessions_table.location_name) = public.normalize_bracket_entity_name(items_table.location_name)
      AND public.normalize_bracket_entity_name(sessions_table.court_name) = public.normalize_bracket_entity_name(items_table.court_name)
      AND sessions_table.status <> 'CANCELLED'::public.championship_individual_session_status
      AND sessions_table.start_time < (items_table.planned_end_at AT TIME ZONE 'America/Sao_Paulo')::TIME
      AND sessions_table.end_time > (items_table.planned_start_at AT TIME ZONE 'America/Sao_Paulo')::TIME
  ) THEN
    blockers := blockers || jsonb_build_array('A reorganização conflita com uma sessão individual da quadra.');
  END IF;

  IF EXISTS (
    SELECT 1
    FROM operational_schedule_interval_items AS items_table
    JOIN jsonb_array_elements(
      COALESCE(edition_record.payload_snapshot->'resource_locks', '[]'::JSONB)
    ) AS lock_record(value)
      ON lock_record.value->>'date' = day_record.event_date::TEXT
      AND COALESCE(lock_record.value->>'lock_mode', 'FLEXIBLE') = 'HARD'
      AND public.normalize_bracket_entity_name(COALESCE(lock_record.value->>'location_name', '')) = public.normalize_bracket_entity_name(items_table.location_name)
      AND public.normalize_bracket_entity_name(COALESCE(lock_record.value->>'court_name', '')) = public.normalize_bracket_entity_name(items_table.court_name)
      AND NULLIF(lock_record.value->>'start_time', '')::TIME < (items_table.planned_end_at AT TIME ZONE 'America/Sao_Paulo')::TIME
      AND NULLIF(lock_record.value->>'end_time', '')::TIME > (items_table.planned_start_at AT TIME ZONE 'America/Sao_Paulo')::TIME
  ) THEN
    blockers := blockers || jsonb_build_array('A reorganização conflita com uma reserva fixa da quadra.');
  END IF;

  FOR item_record IN
    SELECT *
    FROM operational_schedule_interval_items
    WHERE match_id IS NOT NULL
      AND sport_id IS NOT NULL
      AND naipe IS NOT NULL
      AND home_team_id IS NOT NULL
      AND away_team_id IS NOT NULL
  LOOP
    IF false AND public.resolve_scheduled_match_rest_gap_conflict(
      edition_record.championship_id,
      edition_record.season_year,
      day_record.event_date,
      item_record.location_name,
      item_record.court_name,
      item_record.planned_start_at,
      item_record.planned_scheduled_slot,
      item_record.planned_queue_position,
      (SELECT created_at FROM public.matches WHERE id = item_record.match_id),
      item_record.match_id,
      item_record.sport_id,
      item_record.naipe,
      item_record.home_team_id,
      item_record.away_team_id,
      EXTRACT(EPOCH FROM (item_record.original_end_at - item_record.original_start_at))::INTEGER / 60
    ) IS NOT NULL THEN
      blockers := blockers || jsonb_build_array('A reorganização viola o descanso mínimo entre jogos.');
    END IF;
  END LOOP;

  IF false AND EXISTS (
    WITH ordered_items AS (
      SELECT
        items_table.*,
        lag(home_team_id) OVER item_order AS previous_home_team_id,
        lag(away_team_id) OVER item_order AS previous_away_team_id,
        lead(home_team_id) OVER item_order AS next_home_team_id,
        lead(away_team_id) OVER item_order AS next_away_team_id
      FROM operational_schedule_interval_items AS items_table
      WHERE match_id IS NOT NULL
      WINDOW item_order AS (
        PARTITION BY bracket_court_id
        ORDER BY planned_start_at, planned_queue_position, item_id
      )
    )
    SELECT 1
    FROM ordered_items
    WHERE COALESCE(manual_representation_mode, 'AUTO') <> 'CO'
      AND (
        previous_home_team_id IN (home_team_id, away_team_id)
        OR previous_away_team_id IN (home_team_id, away_team_id)
        OR next_home_team_id IN (home_team_id, away_team_id)
        OR next_away_team_id IN (home_team_id, away_team_id)
      )
  ) THEN
    blockers := blockers || jsonb_build_array('A sequência planejada cria conflito de representação na mesma quadra.');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'item_id', item_id,
    'item_type', item_type,
    'match_status', match_status,
    'location_name', location_name,
    'court_name', court_name,
    'label', label,
    'original_start_time', original_start_at,
    'original_end_time', original_end_at,
    'start_time', planned_start_at,
    'end_time', planned_end_at,
    'queue_position', planned_queue_position,
    'scheduled_slot', planned_scheduled_slot,
    'is_displaced', original_start_at IS DISTINCT FROM planned_start_at OR original_end_at IS DISTINCT FROM planned_end_at
  ) ORDER BY planned_start_at, item_id), '[]'::JSONB)
  INTO timeline
  FROM operational_schedule_interval_items;

  RETURN jsonb_build_object(
    'revision', edition_record.reprogramming_revision,
    'blockers', blockers,
    'timeline', timeline,
    'breaks_before', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', id,
        'bracket_day_id', day_record.id,
        'break_start_time', break_start_time,
        'break_end_time', break_end_time,
        'position', position,
        'scope_type', scope_type,
        'bracket_court_id', bracket_court_id
      ) ORDER BY break_start_time, id)
      FROM (
        SELECT id, break_start_time, break_end_time, position, scope_type, bracket_court_id
        FROM public.championship_bracket_day_breaks
        WHERE bracket_day_id = day_record.id
      ) AS before_breaks
    ), '[]'::JSONB),
    'breaks_after', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', id,
        'bracket_day_id', day_record.id,
        'break_start_time', break_start_time,
        'break_end_time', break_end_time,
        'position', position,
        'scope_type', scope_type,
        'bracket_court_id', bracket_court_id
      ) ORDER BY break_start_time, id)
      FROM (
        SELECT
          id,
          break_start_time,
          break_end_time,
          row_number() OVER (ORDER BY break_start_time, id)::INTEGER AS position,
          scope_type,
          bracket_court_id
        FROM operational_schedule_interval_breaks
      ) AS after_breaks
    ), '[]'::JSONB),
    'day_end_before', public.combine_bracket_schedule_timestamp(day_record.event_date, day_record.end_time),
    'day_end_after', proposed_day_end_at,
    'extends_day_end', proposed_day_end_at > public.combine_bracket_schedule_timestamp(day_record.event_date, day_record.end_time)
  );
END;
$function$;

-- Original: can_access_admin_panel()
CREATE OR REPLACE FUNCTION public.can_access_admin_panel()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
 SET statement_timeout TO '2s'
AS $function$
  SELECT
    public.has_admin_tab_access('matches'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('control'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('teams'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('sports'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('events'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('links'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('logs'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('users'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('account'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('championship_status'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('championship_schedule'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('score_sheet_review'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('tie_breaks'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('standings'::public.admin_panel_tab, false) OR
    public.has_admin_tab_access('settings'::public.admin_panel_tab, false)
$function$;

-- Original: list_operational_knockout_schedule_adjustment_candidates(_source_bracket_match_id uuid)
CREATE OR REPLACE FUNCTION public.list_operational_knockout_schedule_adjustment_candidates(_source_bracket_match_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  source_item RECORD;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para ajustar a programação.';
  END IF;

  SELECT
    bracket_matches_table.id,
    bracket_matches_table.bracket_edition_id,
    reservations_table.bracket_day_id,
    reservations_table.location_group_id,
    reservations_table.court_group_id,
    reservations_table.bracket_court_id,
    reservations_table.scheduled_date,
    reservations_table.start_at,
    reservations_table.location_name,
    reservations_table.court_name,
    championships_table.status,
    editions_table.reprogramming_revision
  INTO source_item
  FROM public.championship_bracket_matches AS bracket_matches_table
  JOIN public.championship_bracket_knockout_schedule_reservations AS reservations_table
    ON reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
    AND reservations_table.competition_id = bracket_matches_table.competition_id
    AND reservations_table.round_number = bracket_matches_table.round_number
    AND reservations_table.slot_number = bracket_matches_table.slot_number
    AND reservations_table.is_third_place = bracket_matches_table.is_third_place
  JOIN public.championship_bracket_editions AS editions_table
    ON editions_table.id = bracket_matches_table.bracket_edition_id
  JOIN public.championships AS championships_table
    ON championships_table.id = editions_table.championship_id
  LEFT JOIN public.matches AS matches_table
    ON matches_table.id = bracket_matches_table.match_id
  WHERE bracket_matches_table.id = _source_bracket_match_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_bye IS NOT TRUE
    AND reservations_table.start_at > now()
    AND (
      bracket_matches_table.match_id IS NULL
      OR matches_table.status = 'SCHEDULED'::public.match_status
    );

  IF source_item.id IS NULL THEN
    RAISE EXCEPTION 'O jogo selecionado não está disponível para ajuste operacional.';
  END IF;

  IF source_item.status NOT IN (
    'REVIEW'::public.championship_status,
    'IN_PROGRESS'::public.championship_status
  ) THEN
    RAISE EXCEPTION 'A programação só pode ser ajustada em revisão ou durante o campeonato.';
  END IF;

  RETURN jsonb_build_object(
    'revision', source_item.reprogramming_revision,
    'items', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'bracket_match_id', candidate_bracket_matches.id,
          'match_id', candidate_bracket_matches.match_id,
          'is_placeholder', candidate_bracket_matches.match_id IS NULL,
          'sport_name', sports_table.name,
          'naipe', competitions_table.naipe,
          'division', competitions_table.division,
          'round_number', candidate_bracket_matches.round_number,
          'slot_number', candidate_bracket_matches.slot_number,
          'is_third_place', candidate_bracket_matches.is_third_place,
          'scheduled_date', candidate_reservations.scheduled_date,
          'bracket_court_id', candidate_reservations.bracket_court_id,
          'location', candidate_reservations.location_name,
          'court_name', candidate_reservations.court_name,
          'start_time', candidate_reservations.start_at,
          'end_time', candidate_reservations.end_at,
          'duration_minutes', candidate_reservations.duration_minutes,
          'queue_position', candidate_reservations.queue_position,
          'scheduled_slot', candidate_reservations.scheduled_slot,
          'home_team_name', home_teams_table.name,
          'away_team_name', away_teams_table.name
        )
        ORDER BY candidate_reservations.start_at, candidate_reservations.queue_position
      )
      FROM public.championship_bracket_matches AS candidate_bracket_matches
      JOIN public.championship_bracket_knockout_schedule_reservations AS candidate_reservations
        ON candidate_reservations.bracket_edition_id = candidate_bracket_matches.bracket_edition_id
        AND candidate_reservations.competition_id = candidate_bracket_matches.competition_id
        AND candidate_reservations.round_number = candidate_bracket_matches.round_number
        AND candidate_reservations.slot_number = candidate_bracket_matches.slot_number
        AND candidate_reservations.is_third_place = candidate_bracket_matches.is_third_place
      JOIN public.championship_bracket_competitions AS competitions_table
        ON competitions_table.id = candidate_bracket_matches.competition_id
      JOIN public.sports AS sports_table
        ON sports_table.id = competitions_table.sport_id
      LEFT JOIN public.matches AS candidate_matches_table
        ON candidate_matches_table.id = candidate_bracket_matches.match_id
      LEFT JOIN public.teams AS home_teams_table
        ON home_teams_table.id = candidate_matches_table.home_team_id
      LEFT JOIN public.teams AS away_teams_table
        ON away_teams_table.id = candidate_matches_table.away_team_id
      WHERE candidate_bracket_matches.bracket_edition_id = source_item.bracket_edition_id
        AND candidate_bracket_matches.phase = 'KNOCKOUT'::public.bracket_phase
        AND candidate_bracket_matches.is_bye IS NOT TRUE
        AND candidate_reservations.bracket_day_id = source_item.bracket_day_id
        AND candidate_reservations.scheduled_date = source_item.scheduled_date
        AND candidate_reservations.start_at > now()
        AND (
          candidate_reservations.location_group_id = source_item.location_group_id
          OR (
            candidate_reservations.location_group_id IS NULL
            AND source_item.location_group_id IS NULL
            AND public.normalize_bracket_entity_name(candidate_reservations.location_name) = public.normalize_bracket_entity_name(source_item.location_name)
          )
        )
        AND (
          candidate_reservations.court_group_id = source_item.court_group_id
          OR (
            candidate_reservations.court_group_id IS NULL
            AND source_item.court_group_id IS NULL
            AND public.normalize_bracket_entity_name(candidate_reservations.court_name) = public.normalize_bracket_entity_name(source_item.court_name)
          )
        )
        AND (
          candidate_bracket_matches.match_id IS NULL
          OR candidate_matches_table.status = 'SCHEDULED'::public.match_status
        )
    ), '[]'::jsonb)
  );
END;
$function$;

-- Original: normalize_admin_user_name(_name text, _fallback text)
CREATE OR REPLACE FUNCTION public.normalize_admin_user_name(_name text, _fallback text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT COALESCE(
    NULLIF(trim(COALESCE(_name, '')), ''),
    NULLIF(trim(COALESCE(_fallback, '')), ''),
    'Usuário administrativo'
  );
$function$;

-- Original: preview_operational_knockout_schedule_adjustment(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.preview_operational_knockout_schedule_adjustment(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  preview_result JSONB;
  blockers JSONB;
  representation_adjustments JSONB;
BEGIN
  preview_result := public.preview_operational_knockout_schedule_adjustment_base(
    _bracket_edition_id,
    _payload
  );

  SELECT COALESCE(jsonb_agg(blocker.value), '[]'::JSONB)
  INTO blockers
  FROM jsonb_array_elements(COALESCE(preview_result->'blockers', '[]'::JSONB)) AS blocker(value)
  WHERE blocker.value #>> '{}' <> 'A sequência planejada cria conflito de representação na mesma quadra.';

  WITH projected_matches AS (
    SELECT
      operational_items.match_id,
      operational_items.bracket_match_id,
      operational_items.home_team_id,
      operational_items.away_team_id,
      operational_items.sport_name,
      operational_items.naipe,
      operational_items.division,
      operational_items.scheduled_date,
      operational_items.location_name,
      operational_items.court_name,
      operational_items.planned_start_at AS start_time,
      operational_items.scheduled_slot,
      operational_items.queue_position,
      operational_items.manual_representation_mode,
      matches_table.created_at
    FROM operational_knockout_schedule_items AS operational_items
    JOIN public.matches AS matches_table
      ON matches_table.id = operational_items.match_id
    WHERE operational_items.match_id IS NOT NULL
  ),
  scoped_matches AS (
    SELECT *
    FROM projected_matches

    UNION ALL

    SELECT
      matches_table.id,
      NULL::UUID,
      matches_table.home_team_id,
      matches_table.away_team_id,
      sports_table.name,
      matches_table.naipe,
      matches_table.division,
      matches_table.scheduled_date,
      matches_table.location,
      matches_table.court_name,
      matches_table.start_time,
      matches_table.scheduled_slot,
      matches_table.queue_position,
      matches_table.manual_representation_mode,
      matches_table.created_at
    FROM public.matches AS matches_table
    JOIN public.sports AS sports_table
      ON sports_table.id = matches_table.sport_id
    WHERE matches_table.championship_id = (
        SELECT editions_table.championship_id
        FROM public.championship_bracket_editions AS editions_table
        WHERE editions_table.id = _bracket_edition_id
      )
      AND matches_table.season_year = (
        SELECT editions_table.season_year
        FROM public.championship_bracket_editions AS editions_table
        WHERE editions_table.id = _bracket_edition_id
      )
      AND matches_table.status = 'SCHEDULED'::public.match_status
      AND EXISTS (
        SELECT 1
        FROM operational_knockout_schedule_items AS operational_items
        WHERE matches_table.scheduled_date = operational_items.scheduled_date
          AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(operational_items.location_name)
          AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(operational_items.court_name)
      )
      AND NOT EXISTS (
        SELECT 1
        FROM operational_knockout_schedule_items AS operational_items
        WHERE operational_items.match_id = matches_table.id
      )
  ),
  ordered_matches AS (
    SELECT
      scoped_matches.*,
      lag(scoped_matches.match_id) OVER court_order AS previous_match_id,
      lag(scoped_matches.home_team_id) OVER court_order AS previous_home_team_id,
      lag(scoped_matches.away_team_id) OVER court_order AS previous_away_team_id
    FROM scoped_matches
    WINDOW court_order AS (
      PARTITION BY
        scoped_matches.scheduled_date,
        public.normalize_bracket_entity_name(scoped_matches.location_name),
        public.normalize_bracket_entity_name(scoped_matches.court_name)
      ORDER BY
        CASE WHEN scoped_matches.start_time IS NULL THEN 1 ELSE 0 END,
        scoped_matches.start_time ASC NULLS LAST,
        COALESCE(scoped_matches.scheduled_slot, scoped_matches.queue_position) ASC NULLS LAST,
        COALESCE(scoped_matches.queue_position, scoped_matches.scheduled_slot) ASC NULLS LAST,
        scoped_matches.created_at ASC,
        scoped_matches.match_id ASC
    )
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'match_id', match_id,
      'bracket_match_id', bracket_match_id,
      'previous_match_id', previous_match_id,
      'sport_name', sport_name,
      'naipe', naipe,
      'division', division,
      'scheduled_date', scheduled_date,
      'location', location_name,
      'court_name', court_name,
      'representation_mode', 'CO'
    )
    ORDER BY start_time, queue_position, scheduled_slot, match_id
  ), '[]'::JSONB)
  INTO representation_adjustments
  FROM ordered_matches
  WHERE COALESCE(manual_representation_mode, 'AUTO') <> 'CO'
    AND previous_match_id IS NOT NULL
    AND (
      previous_home_team_id IN (home_team_id, away_team_id)
      OR previous_away_team_id IN (home_team_id, away_team_id)
    );

  IF EXISTS (
    SELECT 1
    FROM operational_knockout_schedule_items AS operational_items
    JOIN public.matches AS matches_table
      ON matches_table.championship_id = (
          SELECT editions_table.championship_id
          FROM public.championship_bracket_editions AS editions_table
          WHERE editions_table.id = _bracket_edition_id
        )
      AND matches_table.season_year = (
          SELECT editions_table.season_year
          FROM public.championship_bracket_editions AS editions_table
          WHERE editions_table.id = _bracket_edition_id
        )
      AND matches_table.status = 'SCHEDULED'::public.match_status
      AND matches_table.scheduled_date = operational_items.scheduled_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(operational_items.location_name)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(operational_items.court_name)
      AND matches_table.id IS DISTINCT FROM operational_items.match_id
      AND NOT EXISTS (
        SELECT 1
        FROM operational_knockout_schedule_items AS projected_items
        WHERE projected_items.match_id = matches_table.id
      )
      AND matches_table.start_time < operational_items.planned_end_at
      AND matches_table.end_time > operational_items.planned_start_at
  ) THEN
    blockers := blockers || jsonb_build_array('A programação planejada sobrepõe outra partida agendada na mesma quadra.');
  END IF;

  preview_result := jsonb_set(preview_result, '{blockers}', blockers);

  RETURN jsonb_set(
    preview_result,
    '{representation_adjustments}',
    representation_adjustments
  );
END;
$function$;

-- Original: preview_operational_knockout_schedule_adjustment_base(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.preview_operational_knockout_schedule_adjustment_base(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  selected_bracket_match_ids UUID[];
  source_item RECORD;
  day_record RECORD;
  edition_record RECORD;
  break_action TEXT;
  break_id_value TEXT;
  break_scope_type public.bracket_day_break_scope_type;
  break_start_time_value TIME;
  break_end_time_value TIME;
  duration_minutes_value INTEGER;
  cursor_at TIMESTAMPTZ;
  candidate_start_at TIMESTAMPTZ;
  candidate_end_at TIMESTAMPTZ;
  item_record RECORD;
  break_record RECORD;
  blockers JSONB := '[]'::jsonb;
  timeline JSONB := '[]'::jsonb;
  break_preview JSONB;
  proposed_day_end_at TIMESTAMPTZ;
  current_day_end_at TIMESTAMPTZ;
  rest_conflict_message TEXT;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para ajustar a programação.';
  END IF;

  SELECT COALESCE(array_agg(value::UUID), ARRAY[]::UUID[])
  INTO selected_bracket_match_ids
  FROM jsonb_array_elements_text(COALESCE(_payload->'bracket_match_ids', '[]'::jsonb)) AS value;

  duration_minutes_value := NULLIF(_payload->>'duration_minutes', '')::INTEGER;
  break_action := upper(trim(COALESCE(_payload->'break'->>'action', 'KEEP')));
  break_id_value := NULLIF(trim(COALESCE(_payload->'break'->>'id', '')), '');
  break_scope_type := CASE upper(trim(COALESCE(_payload->'break'->>'scope_type', 'ALL_COURTS')))
    WHEN 'COURT' THEN 'COURT'::public.bracket_day_break_scope_type
    ELSE 'ALL_COURTS'::public.bracket_day_break_scope_type
  END;
  break_start_time_value := NULLIF(_payload->'break'->>'start_time', '')::TIME;
  break_end_time_value := NULLIF(_payload->'break'->>'end_time', '')::TIME;

  IF cardinality(selected_bracket_match_ids) = 0 THEN
    RAISE EXCEPTION 'Selecione ao menos um slot ou jogo eliminatório.';
  END IF;

  IF cardinality(selected_bracket_match_ids) <> (
    SELECT count(DISTINCT bracket_match_id)
    FROM unnest(selected_bracket_match_ids) AS bracket_match_id
  ) THEN
    RAISE EXCEPTION 'A seleção de programação contém itens repetidos.';
  END IF;

  IF duration_minutes_value IS NULL OR duration_minutes_value < 1 THEN
    RAISE EXCEPTION 'Informe uma duração válida em minutos.';
  END IF;

  IF break_action NOT IN ('KEEP', 'REMOVE', 'UPSERT') THEN
    RAISE EXCEPTION 'Informe uma ação válida para o intervalo.';
  END IF;

  IF break_action = 'UPSERT' AND (
    break_start_time_value IS NULL
    OR break_end_time_value IS NULL
    OR break_end_time_value <= break_start_time_value
  ) THEN
    RAISE EXCEPTION 'Informe início e fim válidos para o intervalo.';
  END IF;

  SELECT
    editions_table.id,
    editions_table.championship_id,
    editions_table.season_year,
    editions_table.reprogramming_revision,
    championships_table.status
  INTO edition_record
  FROM public.championship_bracket_editions AS editions_table
  JOIN public.championships AS championships_table
    ON championships_table.id = editions_table.championship_id
  WHERE editions_table.id = _bracket_edition_id;

  IF edition_record.id IS NULL THEN
    RAISE EXCEPTION 'Edição de chaveamento inválida.';
  END IF;

  IF edition_record.status NOT IN (
    'REVIEW'::public.championship_status,
    'IN_PROGRESS'::public.championship_status
  ) THEN
    RAISE EXCEPTION 'A programação só pode ser ajustada em revisão ou durante o campeonato.';
  END IF;

  SELECT
    bracket_matches_table.id,
    reservations_table.bracket_day_id,
    reservations_table.location_group_id,
    reservations_table.court_group_id,
    reservations_table.bracket_court_id,
    reservations_table.scheduled_date,
    reservations_table.location_name,
    reservations_table.court_name
  INTO source_item
  FROM public.championship_bracket_matches AS bracket_matches_table
  JOIN public.championship_bracket_knockout_schedule_reservations AS reservations_table
    ON reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
    AND reservations_table.competition_id = bracket_matches_table.competition_id
    AND reservations_table.round_number = bracket_matches_table.round_number
    AND reservations_table.slot_number = bracket_matches_table.slot_number
    AND reservations_table.is_third_place = bracket_matches_table.is_third_place
  LEFT JOIN public.matches AS matches_table
    ON matches_table.id = bracket_matches_table.match_id
  WHERE bracket_matches_table.id = selected_bracket_match_ids[1]
    AND bracket_matches_table.bracket_edition_id = _bracket_edition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_bye IS NOT TRUE
    AND reservations_table.start_at > now()
    AND (
      bracket_matches_table.match_id IS NULL
      OR matches_table.status = 'SCHEDULED'::public.match_status
    );

  IF source_item.id IS NULL THEN
    RAISE EXCEPTION 'O item inicial não está disponível para ajuste operacional.';
  END IF;

  IF (
    SELECT count(*)
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.championship_bracket_knockout_schedule_reservations AS reservations_table
      ON reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
      AND reservations_table.competition_id = bracket_matches_table.competition_id
      AND reservations_table.round_number = bracket_matches_table.round_number
      AND reservations_table.slot_number = bracket_matches_table.slot_number
      AND reservations_table.is_third_place = bracket_matches_table.is_third_place
    LEFT JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    WHERE bracket_matches_table.id = ANY(selected_bracket_match_ids)
      AND bracket_matches_table.bracket_edition_id = _bracket_edition_id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND bracket_matches_table.is_bye IS NOT TRUE
      AND reservations_table.bracket_day_id = source_item.bracket_day_id
      AND reservations_table.scheduled_date = source_item.scheduled_date
      AND (
        reservations_table.location_group_id = source_item.location_group_id
        OR (
          reservations_table.location_group_id IS NULL
          AND source_item.location_group_id IS NULL
          AND public.normalize_bracket_entity_name(reservations_table.location_name) = public.normalize_bracket_entity_name(source_item.location_name)
        )
      )
      AND (
        reservations_table.court_group_id = source_item.court_group_id
        OR (
          reservations_table.court_group_id IS NULL
          AND source_item.court_group_id IS NULL
          AND public.normalize_bracket_entity_name(reservations_table.court_name) = public.normalize_bracket_entity_name(source_item.court_name)
        )
      )
      AND reservations_table.start_at > now()
      AND (
        bracket_matches_table.match_id IS NULL
        OR matches_table.status = 'SCHEDULED'::public.match_status
      )
  ) <> cardinality(selected_bracket_match_ids) THEN
    RAISE EXCEPTION 'Todos os itens devem ser eliminatórios, futuros e da mesma data e quadra.';
  END IF;

  SELECT * INTO day_record
  FROM public.championship_bracket_days
  WHERE id = source_item.bracket_day_id
    AND bracket_edition_id = _bracket_edition_id;

  IF day_record.id IS NULL THEN
    RAISE EXCEPTION 'O dia programado não foi localizado.';
  END IF;

  DROP TABLE IF EXISTS operational_knockout_schedule_breaks;

  CREATE TEMP TABLE operational_knockout_schedule_breaks (
    id TEXT PRIMARY KEY,
    scope_type public.bracket_day_break_scope_type NOT NULL,
    bracket_court_id UUID NULL,
    break_start_time TIME NOT NULL,
    break_end_time TIME NOT NULL,
    is_legacy BOOLEAN NOT NULL
  ) ON COMMIT DROP;

  INSERT INTO operational_knockout_schedule_breaks (
    id,
    scope_type,
    bracket_court_id,
    break_start_time,
    break_end_time,
    is_legacy
  )
  SELECT
    day_breaks_table.id::TEXT,
    day_breaks_table.scope_type,
    day_breaks_table.bracket_court_id,
    day_breaks_table.break_start_time,
    day_breaks_table.break_end_time,
    false
  FROM public.championship_bracket_day_breaks AS day_breaks_table
  WHERE day_breaks_table.bracket_day_id = day_record.id;

  IF day_record.break_start_time IS NOT NULL
    AND day_record.break_end_time IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM operational_knockout_schedule_breaks
      WHERE scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
    )
  THEN
    INSERT INTO operational_knockout_schedule_breaks (
      id,
      scope_type,
      bracket_court_id,
      break_start_time,
      break_end_time,
      is_legacy
    ) VALUES (
      concat('legacy:', day_record.id),
      'ALL_COURTS'::public.bracket_day_break_scope_type,
      NULL,
      day_record.break_start_time,
      day_record.break_end_time,
      true
    );
  END IF;

  IF break_action = 'REMOVE' THEN
    DELETE FROM operational_knockout_schedule_breaks
    WHERE id = break_id_value;
  ELSIF break_action = 'UPSERT' THEN
    DELETE FROM operational_knockout_schedule_breaks
    WHERE id = break_id_value;

    INSERT INTO operational_knockout_schedule_breaks (
      id,
      scope_type,
      bracket_court_id,
      break_start_time,
      break_end_time,
      is_legacy
    ) VALUES (
      COALESCE(break_id_value, 'new-break'),
      break_scope_type,
      CASE WHEN break_scope_type = 'COURT' THEN source_item.bracket_court_id ELSE NULL END,
      break_start_time_value,
      break_end_time_value,
      false
    );
  END IF;

  DROP TABLE IF EXISTS operational_knockout_schedule_items;

  CREATE TEMP TABLE operational_knockout_schedule_items (
    bracket_match_id UUID PRIMARY KEY,
    reservation_id UUID NOT NULL,
    match_id UUID NULL,
    home_team_id UUID NULL,
    away_team_id UUID NULL,
    naipe public.match_naipe NOT NULL,
    sport_id UUID NOT NULL,
    sport_name TEXT NOT NULL,
    division public.team_division NULL,
    scheduled_date DATE NOT NULL,
    location_name TEXT NOT NULL,
    court_name TEXT NOT NULL,
    location_group_id UUID NULL,
    court_group_id UUID NULL,
    queue_position INTEGER NOT NULL,
    scheduled_slot INTEGER NOT NULL,
    original_start_at TIMESTAMPTZ NOT NULL,
    original_end_at TIMESTAMPTZ NOT NULL,
    original_duration_minutes INTEGER NOT NULL,
    duration_minutes INTEGER NOT NULL,
    planned_start_at TIMESTAMPTZ NULL,
    planned_end_at TIMESTAMPTZ NULL,
    is_selected BOOLEAN NOT NULL,
    is_placeholder BOOLEAN NOT NULL,
    manual_representation_mode TEXT NULL
  ) ON COMMIT DROP;

  INSERT INTO operational_knockout_schedule_items (
    bracket_match_id,
    reservation_id,
    match_id,
    home_team_id,
    away_team_id,
    naipe,
    sport_id,
    sport_name,
    division,
    scheduled_date,
    location_name,
    court_name,
    location_group_id,
    court_group_id,
    queue_position,
    scheduled_slot,
    original_start_at,
    original_end_at,
    original_duration_minutes,
    duration_minutes,
    is_selected,
    is_placeholder,
    manual_representation_mode
  )
  SELECT
    bracket_matches_table.id,
    reservations_table.id,
    bracket_matches_table.match_id,
    matches_table.home_team_id,
    matches_table.away_team_id,
    competitions_table.naipe,
    competitions_table.sport_id,
    sports_table.name,
    competitions_table.division,
    reservations_table.scheduled_date,
    reservations_table.location_name,
    reservations_table.court_name,
    reservations_table.location_group_id,
    reservations_table.court_group_id,
    reservations_table.queue_position,
    reservations_table.scheduled_slot,
    reservations_table.start_at,
    reservations_table.end_at,
    reservations_table.duration_minutes,
    reservations_table.duration_minutes,
    bracket_matches_table.id = ANY(selected_bracket_match_ids),
    bracket_matches_table.match_id IS NULL,
    matches_table.manual_representation_mode
  FROM public.championship_bracket_matches AS bracket_matches_table
  JOIN public.championship_bracket_knockout_schedule_reservations AS reservations_table
    ON reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
    AND reservations_table.competition_id = bracket_matches_table.competition_id
    AND reservations_table.round_number = bracket_matches_table.round_number
    AND reservations_table.slot_number = bracket_matches_table.slot_number
    AND reservations_table.is_third_place = bracket_matches_table.is_third_place
  JOIN public.championship_bracket_competitions AS competitions_table
    ON competitions_table.id = bracket_matches_table.competition_id
  JOIN public.sports AS sports_table
    ON sports_table.id = competitions_table.sport_id
  LEFT JOIN public.matches AS matches_table
    ON matches_table.id = bracket_matches_table.match_id
  WHERE bracket_matches_table.bracket_edition_id = _bracket_edition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_bye IS NOT TRUE
    AND reservations_table.bracket_day_id = source_item.bracket_day_id
    AND reservations_table.scheduled_date = source_item.scheduled_date
    AND (
      reservations_table.location_group_id = source_item.location_group_id
      OR (
        reservations_table.location_group_id IS NULL
        AND source_item.location_group_id IS NULL
        AND public.normalize_bracket_entity_name(reservations_table.location_name) = public.normalize_bracket_entity_name(source_item.location_name)
      )
    )
    AND (
      reservations_table.court_group_id = source_item.court_group_id
      OR (
        reservations_table.court_group_id IS NULL
        AND source_item.court_group_id IS NULL
        AND public.normalize_bracket_entity_name(reservations_table.court_name) = public.normalize_bracket_entity_name(source_item.court_name)
      )
    )
    AND reservations_table.start_at > now()
    AND (
      bracket_matches_table.match_id IS NULL
      OR matches_table.status = 'SCHEDULED'::public.match_status
    );

  UPDATE operational_knockout_schedule_items
  SET duration_minutes = duration_minutes_value
  WHERE is_selected;

  cursor_at := public.combine_bracket_schedule_timestamp(
    day_record.event_date,
    day_record.start_time
  );

  FOR item_record IN
    SELECT *
    FROM operational_knockout_schedule_items
    ORDER BY original_start_at, queue_position, scheduled_slot, bracket_match_id
  LOOP
    candidate_start_at := cursor_at;

    FOR break_record IN
      SELECT *
      FROM operational_knockout_schedule_breaks
      WHERE scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
        OR bracket_court_id = source_item.bracket_court_id
      ORDER BY break_start_time
    LOOP
      IF candidate_start_at < public.combine_bracket_schedule_timestamp(day_record.event_date, break_record.break_end_time)
        AND candidate_start_at + make_interval(mins => item_record.duration_minutes) > public.combine_bracket_schedule_timestamp(day_record.event_date, break_record.break_start_time)
      THEN
        candidate_start_at := public.combine_bracket_schedule_timestamp(
          day_record.event_date,
          break_record.break_end_time
        );
      END IF;
    END LOOP;

    candidate_end_at := candidate_start_at + make_interval(mins => item_record.duration_minutes);

    UPDATE operational_knockout_schedule_items
    SET
      planned_start_at = candidate_start_at,
      planned_end_at = candidate_end_at
    WHERE bracket_match_id = item_record.bracket_match_id;

    cursor_at := candidate_end_at;
  END LOOP;

  SELECT public.combine_bracket_schedule_timestamp(day_record.event_date, day_record.end_time)
  INTO current_day_end_at;

  SELECT max(planned_end_at)
  INTO proposed_day_end_at
  FROM operational_knockout_schedule_items;

  FOR item_record IN
    SELECT *
    FROM operational_knockout_schedule_items
    WHERE match_id IS NOT NULL
  LOOP
    rest_conflict_message := public.resolve_scheduled_match_rest_gap_conflict(
      edition_record.championship_id,
      edition_record.season_year,
      item_record.scheduled_date,
      item_record.location_name,
      item_record.court_name,
      item_record.planned_start_at,
      item_record.scheduled_slot,
      item_record.queue_position,
      (SELECT created_at FROM public.matches WHERE id = item_record.match_id),
      item_record.match_id,
      item_record.sport_id,
      item_record.naipe,
      item_record.home_team_id,
      item_record.away_team_id,
      item_record.duration_minutes
    );

    IF rest_conflict_message IS NOT NULL THEN
      blockers := blockers || jsonb_build_array(rest_conflict_message);
    END IF;
  END LOOP;

  IF EXISTS (
    WITH ordered_items AS (
      SELECT
        operational_items.*,
        lag(home_team_id) OVER item_order AS previous_home_team_id,
        lag(away_team_id) OVER item_order AS previous_away_team_id,
        lead(home_team_id) OVER item_order AS next_home_team_id,
        lead(away_team_id) OVER item_order AS next_away_team_id
      FROM operational_knockout_schedule_items AS operational_items
      WHERE match_id IS NOT NULL
      WINDOW item_order AS (
        ORDER BY planned_start_at, queue_position, scheduled_slot, bracket_match_id
      )
    )
    SELECT 1
    FROM ordered_items
    WHERE COALESCE(manual_representation_mode, 'AUTO') != 'CO'
      AND (
        previous_home_team_id IN (home_team_id, away_team_id)
        OR previous_away_team_id IN (home_team_id, away_team_id)
        OR next_home_team_id IN (home_team_id, away_team_id)
        OR next_away_team_id IN (home_team_id, away_team_id)
      )
  ) THEN
    blockers := blockers || jsonb_build_array('A sequência planejada cria conflito de representação na mesma quadra.');
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'bracket_match_id', bracket_match_id,
      'match_id', match_id,
      'is_placeholder', is_placeholder,
      'is_selected', is_selected,
      'sport_name', sport_name,
      'naipe', naipe,
      'division', division,
      'scheduled_date', scheduled_date,
      'location', location_name,
      'court_name', court_name,
      'queue_position', queue_position,
      'scheduled_slot', scheduled_slot,
      'original_start_time', original_start_at,
      'original_end_time', original_end_at,
      'original_duration_minutes', original_duration_minutes,
      'start_time', planned_start_at,
      'end_time', planned_end_at,
      'duration_minutes', duration_minutes,
      'is_displaced', original_start_at IS DISTINCT FROM planned_start_at
        OR original_end_at IS DISTINCT FROM planned_end_at
    )
    ORDER BY planned_start_at, queue_position, scheduled_slot, bracket_match_id
  ), '[]'::jsonb)
  INTO timeline
  FROM operational_knockout_schedule_items;

  SELECT jsonb_build_object(
    'action', break_action,
    'before', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', id,
        'scope_type', scope_type,
        'start_time', break_start_time,
        'end_time', break_end_time,
        'is_legacy', is_legacy
      ) ORDER BY break_start_time)
      FROM (
        SELECT
          day_breaks_table.id::TEXT AS id,
          day_breaks_table.scope_type,
          day_breaks_table.break_start_time,
          day_breaks_table.break_end_time,
          false AS is_legacy
        FROM public.championship_bracket_day_breaks AS day_breaks_table
        WHERE day_breaks_table.bracket_day_id = day_record.id
        UNION ALL
        SELECT
          concat('legacy:', day_record.id),
          'ALL_COURTS'::public.bracket_day_break_scope_type,
          day_record.break_start_time,
          day_record.break_end_time,
          true
        WHERE day_record.break_start_time IS NOT NULL
          AND day_record.break_end_time IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM public.championship_bracket_day_breaks AS day_breaks_table
            WHERE day_breaks_table.bracket_day_id = day_record.id
              AND day_breaks_table.scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
          )
      ) AS original_breaks
    ), '[]'::jsonb),
    'after', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'id', id,
        'scope_type', scope_type,
        'start_time', break_start_time,
        'end_time', break_end_time,
        'is_legacy', is_legacy
      ) ORDER BY break_start_time)
      FROM operational_knockout_schedule_breaks
    ), '[]'::jsonb)
  ) INTO break_preview;

  RETURN jsonb_build_object(
    'revision', edition_record.reprogramming_revision,
    'timeline', timeline,
    'blockers', blockers,
    'break', break_preview,
    'day_end_before', current_day_end_at,
    'day_end_after', GREATEST(current_day_end_at, proposed_day_end_at),
    'extends_day_end', proposed_day_end_at > current_day_end_at
  );
END;
$function$;

-- Original: preview_operational_schedule_interval(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.preview_operational_schedule_interval(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.build_operational_schedule_interval_preview(_bracket_edition_id, _payload);
END;
$function$;

-- Original: write_admin_action_log(_action_type admin_action_type, _resource_table text, _record_id text, _description text, _old_data jsonb, _new_data jsonb, _metadata jsonb)
CREATE OR REPLACE FUNCTION public.write_admin_action_log(_action_type admin_action_type, _resource_table text, _record_id text DEFAULT NULL::text, _description text DEFAULT NULL::text, _old_data jsonb DEFAULT NULL::jsonb, _new_data jsonb DEFAULT NULL::jsonb, _metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  actor_user_id UUID;
  actor_role public.app_role;
  actor_email TEXT;
  actor_name TEXT;
BEGIN
  actor_user_id := auth.uid();

  IF actor_user_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT public.can_access_admin_panel() THEN
    RETURN;
  END IF;

  SELECT
    users_table.email,
    admin_user_profiles_table.name
  INTO
    actor_email,
    actor_name
  FROM auth.users AS users_table
  LEFT JOIN public.admin_user_profiles AS admin_user_profiles_table
    ON admin_user_profiles_table.user_id = users_table.id
  WHERE users_table.id = actor_user_id
  LIMIT 1;

  SELECT user_roles_table.role
  INTO actor_role
  FROM public.user_roles AS user_roles_table
  WHERE user_roles_table.user_id = actor_user_id
  ORDER BY
    CASE user_roles_table.role::text
      WHEN 'admin' THEN 0
      WHEN 'eventos' THEN 1
      WHEN 'mesa' THEN 2
      ELSE 3
    END
  LIMIT 1;

  INSERT INTO public.admin_action_logs (
    actor_user_id,
    actor_email,
    actor_name,
    actor_role,
    action_type,
    resource_table,
    record_id,
    description,
    old_data,
    new_data,
    metadata
  ) VALUES (
    actor_user_id,
    actor_email,
    public.normalize_admin_user_name(actor_name, actor_email),
    actor_role,
    _action_type,
    _resource_table,
    _record_id,
    _description,
    _old_data,
    _new_data,
    COALESCE(_metadata, '{}'::jsonb)
  );
END;
$function$;
