-- LAJE-150: faithful PostgreSQL implementation of the Supabase operational relocation and slot engine.
-- Used only behind authenticated, authorization-gated laje-api routes.
-- No automatic data modifications when this migration is installed.

-- Original: append_manual_relocation_placeholders(_bracket_edition_id uuid, _preview jsonb)
CREATE OR REPLACE FUNCTION public.append_manual_relocation_placeholders(_bracket_edition_id uuid, _preview jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  target_date DATE := (_preview->>'target_date')::DATE;
  target_location TEXT := _preview->>'target_location';
  target_court_name TEXT := _preview->>'target_court_name';
  selected_start_at TIMESTAMPTZ;
  current_cursor_at TIMESTAMPTZ;
  next_slot INTEGER;
  next_queue_position INTEGER;
  target_location_group_id UUID;
  target_court_group_id UUID;
  placeholder_record RECORD;
  next_start_at TIMESTAMPTZ;
  next_end_at TIMESTAMPTZ;
  duration_minutes INTEGER;
  changes JSONB := COALESCE(_preview->'changes', '[]'::JSONB);
  timeline JSONB := COALESCE(_preview->'timeline', '[]'::JSONB);
  blockers JSONB := COALESCE(_preview->'blockers', '[]'::JSONB);
  slots JSONB := COALESCE(_preview->'slots', '[]'::JSONB);
  next_day_end TEXT := _preview->>'next_day_end';
BEGIN
  IF target_date IS NULL OR target_location IS NULL OR target_court_name IS NULL THEN
    RETURN _preview;
  END IF;

  IF upper(COALESCE(_preview->>'insertion_position', '')) = 'END' THEN
    RETURN _preview;
  END IF;

  SELECT locations_table.location_group_id, courts_table.court_group_id
  INTO target_location_group_id, target_court_group_id
  FROM public.championship_bracket_days AS days_table
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.bracket_day_id = days_table.id
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND days_table.event_date = target_date
    AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(target_location)
    AND public.normalize_bracket_entity_name(courts_table.name) = public.normalize_bracket_entity_name(target_court_name)
  LIMIT 1;

  SELECT min(NULLIF(change_item.value->'after'->>'start_time', '')::TIMESTAMPTZ)
  INTO selected_start_at
  FROM jsonb_array_elements(changes) AS change_item(value)
  WHERE COALESCE((change_item.value->>'is_selected')::BOOLEAN, false);

  SELECT COALESCE(
    jsonb_agg(
      slot_item.value || jsonb_build_object(
        'displaced_placeholders_count', (
          SELECT count(*)
          FROM public.championship_bracket_matches AS bracket_matches_table
          JOIN public.championship_bracket_competitions AS competitions_table
            ON competitions_table.id = bracket_matches_table.competition_id
          WHERE competitions_table.bracket_edition_id = _bracket_edition_id
            AND bracket_matches_table.match_id IS NULL
            AND bracket_matches_table.is_bye = false
            AND bracket_matches_table.planned_scheduled_date = target_date
            AND public.normalize_bracket_entity_name(bracket_matches_table.planned_location_name) = public.normalize_bracket_entity_name(target_location)
            AND public.normalize_bracket_entity_name(bracket_matches_table.planned_court_name) = public.normalize_bracket_entity_name(target_court_name)
            AND bracket_matches_table.planned_start_time IS NOT NULL
            AND public.combine_bracket_schedule_timestamp(target_date, bracket_matches_table.planned_start_time) >= (slot_item.value->>'start_time')::TIMESTAMPTZ
        )
      )
      ORDER BY (slot_item.value->>'start_time')::TIMESTAMPTZ
    ),
    '[]'::JSONB
  )
  INTO slots
  FROM jsonb_array_elements(slots) AS slot_item(value);

  IF selected_start_at IS NULL THEN
    RETURN jsonb_set(_preview, '{slots}', slots, true);
  END IF;

  SELECT COALESCE(
    max(NULLIF(timeline_item.value->>'end_time', '')::TIMESTAMPTZ),
    selected_start_at
  )
  INTO current_cursor_at
  FROM jsonb_array_elements(timeline) AS timeline_item(value);

  SELECT GREATEST(
    COALESCE(max(matches_table.scheduled_slot), 0),
    COALESCE(max(bracket_matches_table.planned_scheduled_slot), 0)
  )
  INTO next_slot
  FROM public.championship_bracket_competitions AS competitions_table
  JOIN public.championship_bracket_editions AS editions_table
    ON editions_table.id = competitions_table.bracket_edition_id
  LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.competition_id = competitions_table.id
    AND bracket_matches_table.match_id IS NULL
    AND bracket_matches_table.is_bye = false
    AND bracket_matches_table.planned_scheduled_date = target_date
    AND public.normalize_bracket_entity_name(bracket_matches_table.planned_location_name) = public.normalize_bracket_entity_name(target_location)
    AND public.normalize_bracket_entity_name(bracket_matches_table.planned_court_name) = public.normalize_bracket_entity_name(target_court_name)
  LEFT JOIN public.matches AS matches_table
    ON matches_table.championship_id = editions_table.championship_id
    AND matches_table.season_year = editions_table.season_year
    AND matches_table.scheduled_date = target_date
    AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
    AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
  WHERE competitions_table.bracket_edition_id = _bracket_edition_id;

  SELECT GREATEST(
    COALESCE(max(matches_table.queue_position), 0),
    COALESCE(max(bracket_matches_table.planned_queue_position), 0)
  )
  INTO next_queue_position
  FROM public.championship_bracket_competitions AS competitions_table
  JOIN public.championship_bracket_editions AS editions_table
    ON editions_table.id = competitions_table.bracket_edition_id
  LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.competition_id = competitions_table.id
    AND bracket_matches_table.match_id IS NULL
    AND bracket_matches_table.is_bye = false
    AND bracket_matches_table.planned_scheduled_date = target_date
    AND public.normalize_bracket_entity_name(bracket_matches_table.planned_location_name) = public.normalize_bracket_entity_name(target_location)
    AND public.normalize_bracket_entity_name(bracket_matches_table.planned_court_name) = public.normalize_bracket_entity_name(target_court_name)
  LEFT JOIN public.matches AS matches_table
    ON matches_table.championship_id = editions_table.championship_id
    AND matches_table.season_year = editions_table.season_year
    AND matches_table.scheduled_date = target_date
    AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
    AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
  WHERE competitions_table.bracket_edition_id = _bracket_edition_id;

  FOR placeholder_record IN
    SELECT
      bracket_matches_table.id,
      bracket_matches_table.round_number,
      bracket_matches_table.is_third_place,
      bracket_matches_table.planned_start_time,
      bracket_matches_table.planned_end_time,
      bracket_matches_table.planned_queue_position,
      bracket_matches_table.planned_scheduled_slot,
      GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1) AS duration_minutes,
      COALESCE(sports_table.name, 'Modalidade') AS sport_name
    FROM public.championship_bracket_matches AS bracket_matches_table
    JOIN public.championship_bracket_competitions AS competitions_table
      ON competitions_table.id = bracket_matches_table.competition_id
    JOIN public.championship_bracket_editions AS editions_table
      ON editions_table.id = competitions_table.bracket_edition_id
    LEFT JOIN public.sports AS sports_table
      ON sports_table.id = competitions_table.sport_id
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = editions_table.championship_id
      AND championship_sports_table.sport_id = competitions_table.sport_id
    WHERE competitions_table.bracket_edition_id = _bracket_edition_id
      AND bracket_matches_table.match_id IS NULL
      AND bracket_matches_table.is_bye = false
      AND bracket_matches_table.planned_scheduled_date = target_date
      AND public.normalize_bracket_entity_name(bracket_matches_table.planned_location_name) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(bracket_matches_table.planned_court_name) = public.normalize_bracket_entity_name(target_court_name)
      AND bracket_matches_table.planned_start_time IS NOT NULL
      AND public.combine_bracket_schedule_timestamp(target_date, bracket_matches_table.planned_start_time) >= selected_start_at
    ORDER BY
      bracket_matches_table.planned_start_time,
      COALESCE(bracket_matches_table.planned_scheduled_slot, bracket_matches_table.planned_queue_position),
      bracket_matches_table.id
  LOOP
    duration_minutes := placeholder_record.duration_minutes;
    next_start_at := GREATEST(
      current_cursor_at,
      public.combine_bracket_schedule_timestamp(
        target_date,
        placeholder_record.planned_start_time
      )
    );
    next_end_at := next_start_at + make_interval(mins => duration_minutes);
    next_slot := next_slot + 1;
    next_queue_position := next_queue_position + 1;

    changes := changes || jsonb_build_array(
      jsonb_build_object(
        'item_type', 'KNOCKOUT_PLACEHOLDER',
        'item_id', placeholder_record.id,
        'match_id', NULL,
        'placeholder_id', placeholder_record.id,
        'label', format(
          'A definir • %s',
          CASE
            WHEN placeholder_record.is_third_place THEN 'Disputa de 3º lugar'
            WHEN placeholder_record.round_number = 1 THEN 'Mata-mata'
            ELSE format('Rodada %s', placeholder_record.round_number)
          END
        ),
        'is_selected', false,
        'before', jsonb_build_object(
          'scheduled_date', target_date,
          'location', target_location,
          'court_name', target_court_name,
          'start_time', public.combine_bracket_schedule_timestamp(target_date, placeholder_record.planned_start_time),
          'end_time', CASE
            WHEN placeholder_record.planned_end_time IS NULL THEN NULL
            ELSE public.combine_bracket_schedule_timestamp(target_date, placeholder_record.planned_end_time)
          END,
          'queue_position', placeholder_record.planned_queue_position,
          'scheduled_slot', placeholder_record.planned_scheduled_slot
        ),
        'after', jsonb_build_object(
          'scheduled_date', target_date,
          'location', target_location,
          'court_name', target_court_name,
          'location_group_id', target_location_group_id,
          'court_group_id', target_court_group_id,
          'start_time', next_start_at,
          'end_time', next_end_at,
          'queue_position', next_queue_position,
          'scheduled_slot', next_slot
        )
      )
    );

    timeline := timeline || jsonb_build_array(
      jsonb_build_object(
        'item_type', 'KNOCKOUT_PLACEHOLDER',
        'item_id', placeholder_record.id,
        'match_id', NULL,
        'placeholder_id', placeholder_record.id,
        'label', format('A definir • %s', placeholder_record.sport_name),
        'status', 'PLANNED',
        'start_time', next_start_at,
        'end_time', next_end_at,
        'location', target_location,
        'court_name', target_court_name,
        'is_relocated', false,
        'is_displaced', true
      )
    );

    current_cursor_at := next_end_at;
  END LOOP;

  IF current_cursor_at IS NOT NULL THEN
    next_day_end := to_char(
      current_cursor_at AT TIME ZONE 'America/Sao_Paulo',
      'HH24:MI'
    );

    IF (current_cursor_at AT TIME ZONE 'America/Sao_Paulo')::DATE > target_date THEN
      blockers := blockers || jsonb_build_array(
        'A realocação desloca slots planejados para depois da meia-noite e deve ser dividida em outro dia configurado.'
      );
    END IF;
  END IF;

  RETURN jsonb_set(
    jsonb_set(
      jsonb_set(
        jsonb_set(
          jsonb_set(_preview, '{changes}', changes, true),
          '{timeline}', timeline,
          true
        ),
        '{slots}', slots,
        true
      ),
      '{blockers}', blockers,
      true
    ),
    '{next_day_end}', to_jsonb(next_day_end),
    true
  );
END;
$function$;

-- Original: apply_manual_match_relocation(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
CREATE OR REPLACE FUNCTION public.apply_manual_match_relocation(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  preview JSONB;
  current_revision BIGINT;
  target_date DATE;
  target_day_end TIME;
  calculated_day_end TIME;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para realocar jogos.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(format('manual-match-relocation:%s', _bracket_edition_id), 0));

  SELECT reprogramming_revision
  INTO current_revision
  FROM public.championship_bracket_editions
  WHERE id = _bracket_edition_id
  FOR UPDATE;

  IF current_revision IS NULL THEN
    RAISE EXCEPTION 'Edição de chaveamento inválida.';
  END IF;

  IF current_revision <> _expected_revision THEN
    RAISE EXCEPTION 'A prévia está desatualizada. Calcule novamente antes de confirmar.';
  END IF;

  preview := public.build_manual_match_relocation_preview(_bracket_edition_id, _payload);

  IF jsonb_array_length(COALESCE(preview->'blockers', '[]'::JSONB)) > 0 THEN
    RAISE EXCEPTION 'A realocação possui conflitos e não pode ser aplicada.';
  END IF;

  PERFORM set_config('app.allow_manual_schedule_override_update', 'true', true);
  PERFORM set_config('app.allow_pending_manual_relocation_update', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  UPDATE public.matches AS matches_table
  SET
    scheduled_date = changes_table.scheduled_date,
    location = changes_table.location,
    court_name = changes_table.court_name,
    start_time = changes_table.start_time,
    end_time = changes_table.end_time,
    queue_position = changes_table.queue_position,
    scheduled_slot = changes_table.scheduled_slot,
    is_manual_schedule_override = CASE WHEN changes_json.is_selected THEN true ELSE matches_table.is_manual_schedule_override END,
    manual_schedule_override_reason = CASE WHEN changes_json.is_selected THEN preview->>'reason' ELSE matches_table.manual_schedule_override_reason END,
    manual_schedule_override_notes = CASE WHEN changes_json.is_selected THEN NULLIF(preview->>'notes', '') ELSE matches_table.manual_schedule_override_notes END,
    is_pending_manual_relocation = CASE WHEN changes_json.is_selected THEN false ELSE matches_table.is_pending_manual_relocation END,
    pending_manual_relocation_reason = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_reason END,
    pending_manual_relocation_notes = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_notes END,
    pending_manual_relocation_previous_schedule = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_previous_schedule END,
    pending_manual_relocation_previous_label = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_previous_label END,
    pending_manual_relocation_created_by = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_created_by END,
    pending_manual_relocation_at = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_at END
  FROM jsonb_to_recordset(preview->'changes') AS changes_json(item_type TEXT, match_id UUID, is_selected BOOLEAN, after JSONB)
  CROSS JOIN LATERAL jsonb_to_record(changes_json.after) AS changes_table(scheduled_date DATE, location TEXT, court_name TEXT, start_time TIMESTAMPTZ, end_time TIMESTAMPTZ, queue_position INTEGER, scheduled_slot INTEGER)
  WHERE COALESCE(changes_json.item_type, 'MATCH') = 'MATCH'
    AND matches_table.id = changes_json.match_id;

  UPDATE public.championship_bracket_matches AS bracket_matches_table
  SET
    planned_scheduled_date = changes_table.scheduled_date,
    planned_location_group_id = changes_table.location_group_id,
    planned_court_group_id = changes_table.court_group_id,
    planned_location_name = changes_table.location,
    planned_court_name = changes_table.court_name,
    planned_start_time = (changes_table.start_time AT TIME ZONE 'America/Sao_Paulo')::TIME,
    planned_end_time = (changes_table.end_time AT TIME ZONE 'America/Sao_Paulo')::TIME,
    planned_queue_position = changes_table.queue_position,
    planned_scheduled_slot = changes_table.scheduled_slot
  FROM jsonb_to_recordset(preview->'changes') AS changes_json(item_type TEXT, placeholder_id UUID, after JSONB)
  CROSS JOIN LATERAL jsonb_to_record(changes_json.after) AS changes_table(scheduled_date DATE, location TEXT, court_name TEXT, location_group_id UUID, court_group_id UUID, start_time TIMESTAMPTZ, end_time TIMESTAMPTZ, queue_position INTEGER, scheduled_slot INTEGER)
  WHERE changes_json.item_type = 'KNOCKOUT_PLACEHOLDER'
    AND bracket_matches_table.id = changes_json.placeholder_id
    AND bracket_matches_table.match_id IS NULL;

  target_date := (preview->>'target_date')::DATE;
  SELECT end_time INTO target_day_end
  FROM public.championship_bracket_days
  WHERE bracket_edition_id = _bracket_edition_id AND event_date = target_date
  FOR UPDATE;

  calculated_day_end := (preview->>'next_day_end')::TIME;
  IF calculated_day_end > target_day_end THEN
    UPDATE public.championship_bracket_days
    SET end_time = calculated_day_end
    WHERE bracket_edition_id = _bracket_edition_id AND event_date = target_date;
  END IF;

  UPDATE public.championship_bracket_editions
  SET reprogramming_revision = reprogramming_revision + 1
  WHERE id = _bracket_edition_id;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  PERFORM set_config('app.allow_pending_manual_relocation_update', 'false', true);
  PERFORM set_config('app.allow_manual_schedule_override_update', 'false', true);
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.allow_pending_manual_relocation_update', 'false', true);
    PERFORM set_config('app.allow_manual_schedule_override_update', 'false', true);
    RAISE;
END;
$function$;

-- Original: apply_manual_match_relocation_slot(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
CREATE OR REPLACE FUNCTION public.apply_manual_match_relocation_slot(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  preview_result JSONB;
BEGIN
  preview_result := public.build_manual_match_relocation_slot_preview(
    _bracket_edition_id,
    _payload
  );

  PERFORM public.apply_manual_match_relocation_slot_base_schedule_sync(
    _bracket_edition_id,
    _payload,
    _expected_revision
  );

  PERFORM set_config('app.skip_queue_trigger', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  -- scheduled_start_time é a fonte preferencial da UI para jogos agendados.
  UPDATE public.matches AS matches_table
  SET scheduled_start_time = changes_table.start_time
  FROM jsonb_to_recordset(COALESCE(preview_result->'changes', '[]'::JSONB))
    AS changes_json(item_type TEXT, match_id UUID, after JSONB)
  CROSS JOIN LATERAL jsonb_to_record(changes_json.after)
    AS changes_table(start_time TIMESTAMPTZ)
  WHERE COALESCE(changes_json.item_type, 'MATCH') = 'MATCH'
    AND matches_table.id = changes_json.match_id
    AND matches_table.status = 'SCHEDULED'::public.match_status
    AND matches_table.scheduled_start_time IS DISTINCT FROM changes_table.start_time;

  -- Se a partida movimentada já é materializada no mata-mata, o planejamento
  -- do bracket também precisa acompanhar o registro operacional.
  UPDATE public.championship_bracket_matches AS bracket_matches_table
  SET
    planned_scheduled_date = changes_table.scheduled_date,
    planned_location_name = changes_table.location,
    planned_court_name = changes_table.court_name,
    planned_start_time = (changes_table.start_time AT TIME ZONE 'America/Sao_Paulo')::TIME,
    planned_end_time = (changes_table.end_time AT TIME ZONE 'America/Sao_Paulo')::TIME,
    planned_queue_position = changes_table.queue_position,
    planned_scheduled_slot = changes_table.scheduled_slot
  FROM jsonb_to_recordset(COALESCE(preview_result->'changes', '[]'::JSONB))
    AS changes_json(item_type TEXT, match_id UUID, after JSONB)
  CROSS JOIN LATERAL jsonb_to_record(changes_json.after)
    AS changes_table(
      scheduled_date DATE,
      location TEXT,
      court_name TEXT,
      start_time TIMESTAMPTZ,
      end_time TIMESTAMPTZ,
      queue_position INTEGER,
      scheduled_slot INTEGER
    )
  WHERE COALESCE(changes_json.item_type, 'MATCH') = 'MATCH'
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.match_id = changes_json.match_id;

  -- A reserva estrutural é a terceira fonte de verdade. Mantê-la coerente
  -- evita que modais de troca/ajuste mostrem o slot antigo após uma realocação.
  UPDATE public.championship_bracket_knockout_schedule_reservations AS reservations_table
  SET
    scheduled_date = bracket_matches_table.planned_scheduled_date,
    scheduled_slot = bracket_matches_table.planned_scheduled_slot,
    queue_position = bracket_matches_table.planned_queue_position,
    start_at = public.combine_bracket_schedule_timestamp(
      bracket_matches_table.planned_scheduled_date,
      bracket_matches_table.planned_start_time
    ),
    end_at = public.combine_bracket_schedule_timestamp(
      bracket_matches_table.planned_scheduled_date,
      bracket_matches_table.planned_end_time
    ),
    location_name = bracket_matches_table.planned_location_name,
    court_name = bracket_matches_table.planned_court_name
  FROM public.championship_bracket_matches AS bracket_matches_table
  JOIN jsonb_to_recordset(COALESCE(preview_result->'changes', '[]'::JSONB))
    AS changes_json(item_type TEXT, match_id UUID)
    ON COALESCE(changes_json.item_type, 'MATCH') = 'MATCH'
   AND bracket_matches_table.match_id = changes_json.match_id
  WHERE bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND reservations_table.bracket_edition_id = bracket_matches_table.bracket_edition_id
    AND reservations_table.competition_id = bracket_matches_table.competition_id
    AND reservations_table.round_number = bracket_matches_table.round_number
    AND reservations_table.slot_number = bracket_matches_table.slot_number
    AND reservations_table.is_third_place = bracket_matches_table.is_third_place;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  PERFORM set_config('app.skip_queue_trigger', 'false', true);
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.skip_queue_trigger', 'false', true);
    RAISE;
END;
$function$;

-- Original: apply_manual_match_relocation_slot_base_schedule_sync(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
CREATE OR REPLACE FUNCTION public.apply_manual_match_relocation_slot_base_schedule_sync(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  preview JSONB;
  current_revision BIGINT;
  target_date DATE;
  target_day_end TIME;
  calculated_day_end TIME;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para realocar jogos.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(format('manual-match-relocation-slot:%s', _bracket_edition_id), 0));

  SELECT reprogramming_revision INTO current_revision
  FROM public.championship_bracket_editions
  WHERE id = _bracket_edition_id
  FOR UPDATE;

  IF current_revision IS NULL THEN
    RAISE EXCEPTION 'Edição de chaveamento inválida.';
  END IF;

  IF current_revision <> _expected_revision THEN
    RAISE EXCEPTION 'A prévia está desatualizada. Calcule novamente antes de confirmar.';
  END IF;

  preview := public.build_manual_match_relocation_slot_preview(_bracket_edition_id, _payload);

  IF jsonb_array_length(COALESCE(preview->'blockers', '[]'::JSONB)) > 0 THEN
    RAISE EXCEPTION 'O encaixe possui conflitos e não pode ser aplicado.';
  END IF;

  PERFORM set_config('app.allow_manual_schedule_override_update', 'true', true);
  PERFORM set_config('app.allow_pending_manual_relocation_update', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  UPDATE public.matches AS matches_table
  SET
    scheduled_date = changes_table.scheduled_date,
    location = changes_table.location,
    court_name = changes_table.court_name,
    start_time = changes_table.start_time,
    end_time = changes_table.end_time,
    queue_position = changes_table.queue_position,
    scheduled_slot = changes_table.scheduled_slot,
    is_manual_schedule_override = CASE WHEN changes_json.is_selected THEN true ELSE matches_table.is_manual_schedule_override END,
    manual_schedule_override_reason = CASE WHEN changes_json.is_selected THEN preview->>'reason' ELSE matches_table.manual_schedule_override_reason END,
    manual_schedule_override_notes = CASE WHEN changes_json.is_selected THEN NULLIF(preview->>'notes', '') ELSE matches_table.manual_schedule_override_notes END,
    is_pending_manual_relocation = CASE WHEN changes_json.is_selected THEN false ELSE matches_table.is_pending_manual_relocation END,
    pending_manual_relocation_reason = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_reason END,
    pending_manual_relocation_notes = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_notes END,
    pending_manual_relocation_previous_schedule = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_previous_schedule END,
    pending_manual_relocation_previous_label = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_previous_label END,
    pending_manual_relocation_created_by = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_created_by END,
    pending_manual_relocation_at = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_at END
  FROM jsonb_to_recordset(preview->'changes') AS changes_json(item_type TEXT, match_id UUID, is_selected BOOLEAN, after JSONB)
  CROSS JOIN LATERAL jsonb_to_record(changes_json.after) AS changes_table(scheduled_date DATE, location TEXT, court_name TEXT, start_time TIMESTAMPTZ, end_time TIMESTAMPTZ, queue_position INTEGER, scheduled_slot INTEGER)
  WHERE COALESCE(changes_json.item_type, 'MATCH') = 'MATCH'
    AND matches_table.id = changes_json.match_id;

  UPDATE public.championship_bracket_matches AS bracket_matches_table
  SET
    planned_scheduled_date = changes_table.scheduled_date,
    planned_location_group_id = changes_table.location_group_id,
    planned_court_group_id = changes_table.court_group_id,
    planned_location_name = changes_table.location,
    planned_court_name = changes_table.court_name,
    planned_start_time = (changes_table.start_time AT TIME ZONE 'America/Sao_Paulo')::TIME,
    planned_end_time = (changes_table.end_time AT TIME ZONE 'America/Sao_Paulo')::TIME,
    planned_queue_position = changes_table.queue_position,
    planned_scheduled_slot = changes_table.scheduled_slot
  FROM jsonb_to_recordset(preview->'changes') AS changes_json(item_type TEXT, placeholder_id UUID, after JSONB)
  CROSS JOIN LATERAL jsonb_to_record(changes_json.after) AS changes_table(scheduled_date DATE, location TEXT, court_name TEXT, location_group_id UUID, court_group_id UUID, start_time TIMESTAMPTZ, end_time TIMESTAMPTZ, queue_position INTEGER, scheduled_slot INTEGER)
  WHERE changes_json.item_type = 'KNOCKOUT_PLACEHOLDER'
    AND bracket_matches_table.id = changes_json.placeholder_id
    AND bracket_matches_table.match_id IS NULL;

  target_date := (preview->>'target_date')::DATE;
  SELECT end_time INTO target_day_end
  FROM public.championship_bracket_days
  WHERE bracket_edition_id = _bracket_edition_id AND event_date = target_date
  FOR UPDATE;

  calculated_day_end := (preview->>'next_day_end')::TIME;
  IF calculated_day_end > target_day_end THEN
    UPDATE public.championship_bracket_days
    SET end_time = calculated_day_end
    WHERE bracket_edition_id = _bracket_edition_id AND event_date = target_date;
  END IF;

  UPDATE public.championship_bracket_editions
  SET reprogramming_revision = reprogramming_revision + 1
  WHERE id = _bracket_edition_id;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  PERFORM set_config('app.allow_pending_manual_relocation_update', 'false', true);
  PERFORM set_config('app.allow_manual_schedule_override_update', 'false', true);
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.allow_pending_manual_relocation_update', 'false', true);
    PERFORM set_config('app.allow_manual_schedule_override_update', 'false', true);
    RAISE;
END;
$function$;

-- Original: build_manual_match_relocation_preview(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.build_manual_match_relocation_preview(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.append_manual_relocation_placeholders(
    _bracket_edition_id,
    public.build_manual_match_relocation_preview_base(
      _bracket_edition_id,
      _payload
    )
  );
END;
$function$;

-- Original: build_manual_match_relocation_preview_base(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.build_manual_match_relocation_preview_base(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  selected_match_ids UUID[];
  selected_matches_count INTEGER;
  selected_championship_id UUID;
  selected_season_year INTEGER;
  target_date DATE;
  target_location TEXT;
  target_court_name TEXT;
  insertion_position TEXT;
  relocation_reason TEXT;
  relocation_notes TEXT;
  target_start_time TIME;
  effective_start_time TIME;
  previous_day_start TEXT;
  next_day_start TEXT;
  bracket_edition_record RECORD;
  target_day_record RECORD;
  target_court_id UUID;
  target_day_end_at TIMESTAMPTZ;
  current_cursor_at TIMESTAMPTZ;
  planned_end_at TIMESTAMPTZ;
  break_end_at TIMESTAMPTZ;
  plan_record RECORD;
  blockers JSONB := '[]'::JSONB;
  changes JSONB := '[]'::JSONB;
  timeline JSONB := '[]'::JSONB;
  revision_value BIGINT;
  previous_day_end TEXT;
  next_day_end TEXT;
  has_rest_conflict BOOLEAN := false;
BEGIN
  SELECT array_agg(value::UUID)
  INTO selected_match_ids
  FROM jsonb_array_elements_text(COALESCE(_payload->'match_ids', '[]'::JSONB)) AS value;

  target_date := NULLIF(_payload->>'target_date', '')::DATE;
  target_location := NULLIF(trim(COALESCE(_payload->>'target_location', '')), '');
  target_court_name := NULLIF(trim(COALESCE(_payload->>'target_court_name', '')), '');
  insertion_position := upper(trim(COALESCE(_payload->>'insertion_position', '')));
  relocation_reason := upper(trim(COALESCE(_payload->>'reason', '')));
  relocation_notes := NULLIF(trim(COALESCE(_payload->>'notes', '')), '');
  target_start_time := NULLIF(trim(COALESCE(_payload->>'target_start_time', '')), '')::TIME;

  IF COALESCE(cardinality(selected_match_ids), 0) = 0 THEN
    RAISE EXCEPTION 'Selecione ao menos um jogo agendado para realocar.';
  END IF;

  IF cardinality(selected_match_ids) <> (
    SELECT count(DISTINCT match_id)
    FROM unnest(selected_match_ids) AS match_id
  ) THEN
    RAISE EXCEPTION 'A seleção de jogos contém itens repetidos.';
  END IF;

  IF target_date IS NULL OR target_location IS NULL OR target_court_name IS NULL THEN
    RAISE EXCEPTION 'Informe dia, local e quadra de destino.';
  END IF;

  IF insertion_position NOT IN ('START', 'END') THEN
    RAISE EXCEPTION 'A posição da fila deve ser início ou fim.';
  END IF;

  IF relocation_reason NOT IN ('WEATHER', 'COURT_UNAVAILABLE', 'OPERATIONAL_DELAY', 'SAFETY', 'OTHER') THEN
    RAISE EXCEPTION 'Informe um motivo válido para a realocação.';
  END IF;

  SELECT championship_id, season_year, reprogramming_revision
  INTO bracket_edition_record
  FROM public.championship_bracket_editions
  WHERE id = _bracket_edition_id
  LIMIT 1;

  IF bracket_edition_record.championship_id IS NULL THEN
    RAISE EXCEPTION 'Edição de chaveamento inválida.';
  END IF;

  SELECT count(*), (array_agg(championship_id))[1], min(season_year)
  INTO selected_matches_count, selected_championship_id, selected_season_year
  FROM public.matches
  WHERE id = ANY(selected_match_ids)
    AND status = 'SCHEDULED'::public.match_status;

  IF selected_matches_count <> cardinality(selected_match_ids) THEN
    RAISE EXCEPTION 'Somente jogos agendados podem ser realocados.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.matches
    WHERE id = ANY(selected_match_ids)
      AND (championship_id <> selected_championship_id OR season_year <> selected_season_year)
  ) OR selected_championship_id IS DISTINCT FROM bracket_edition_record.championship_id
    OR selected_season_year IS DISTINCT FROM bracket_edition_record.season_year THEN
    RAISE EXCEPTION 'Todos os jogos precisam pertencer à edição selecionada.';
  END IF;

  SELECT days_table.id, days_table.start_time, days_table.end_time
  INTO target_day_record
  FROM public.championship_bracket_days AS days_table
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND days_table.event_date = target_date
  LIMIT 1;

  IF target_day_record.id IS NULL THEN
    RAISE EXCEPTION 'O dia de destino não está configurado na agenda do campeonato.';
  END IF;

  effective_start_time := COALESCE(target_start_time, target_day_record.start_time);

  IF target_start_time IS NOT NULL AND target_start_time >= target_day_record.start_time THEN
    RAISE EXCEPTION 'O novo horário de início deve antecipar o início atual do dia.';
  END IF;

  SELECT courts_table.id
  INTO target_court_id
  FROM public.championship_bracket_locations AS locations_table
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
  WHERE locations_table.bracket_day_id = target_day_record.id
    AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(target_location)
    AND public.normalize_bracket_entity_name(courts_table.name) = public.normalize_bracket_entity_name(target_court_name)
  LIMIT 1;

  IF target_court_id IS NULL THEN
    RAISE EXCEPTION 'A quadra de destino não está configurada nesse dia.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.matches AS selected_matches_table
    WHERE selected_matches_table.id = ANY(selected_match_ids)
      AND NOT EXISTS (
        SELECT 1
        FROM public.championship_bracket_court_sports AS court_sports_table
        WHERE court_sports_table.bracket_court_id = target_court_id
          AND court_sports_table.sport_id = selected_matches_table.sport_id
      )
  ) THEN
    RAISE EXCEPTION 'A quadra de destino não está configurada para todas as modalidades selecionadas.';
  END IF;

  DROP TABLE IF EXISTS pg_temp.manual_match_relocation_plan;
  CREATE TEMP TABLE manual_match_relocation_plan (
    match_id UUID PRIMARY KEY,
    is_selected BOOLEAN NOT NULL,
    source_order INTEGER NOT NULL,
    championship_id UUID NOT NULL,
    season_year INTEGER NOT NULL,
    sport_id UUID NOT NULL,
    naipe public.match_naipe NOT NULL,
    home_team_id UUID NOT NULL,
    away_team_id UUID NOT NULL,
    duration_minutes INTEGER NOT NULL,
    old_scheduled_date DATE NULL,
    old_location TEXT NULL,
    old_court_name TEXT NULL,
    old_start_time TIMESTAMPTZ NULL,
    old_end_time TIMESTAMPTZ NULL,
    old_queue_position INTEGER NULL,
    old_scheduled_slot INTEGER NULL,
    new_start_time TIMESTAMPTZ NULL,
    new_end_time TIMESTAMPTZ NULL,
    new_queue_position INTEGER NULL,
    new_scheduled_slot INTEGER NULL
  ) ON COMMIT DROP;

  INSERT INTO manual_match_relocation_plan (
    match_id, is_selected, source_order, championship_id, season_year, sport_id, naipe,
    home_team_id, away_team_id, duration_minutes, old_scheduled_date, old_location,
    old_court_name, old_start_time, old_end_time, old_queue_position, old_scheduled_slot
  )
  SELECT
    matches_table.id,
    true,
    CASE
      WHEN insertion_position = 'END' AND target_start_time IS NULL THEN 100000 + row_number() OVER (
        ORDER BY matches_table.scheduled_date, matches_table.start_time,
          COALESCE(matches_table.scheduled_slot, matches_table.queue_position), matches_table.created_at, matches_table.id
      )
      ELSE row_number() OVER (
        ORDER BY matches_table.scheduled_date, matches_table.start_time,
          COALESCE(matches_table.scheduled_slot, matches_table.queue_position), matches_table.created_at, matches_table.id
      )
    END,
    matches_table.championship_id,
    matches_table.season_year,
    matches_table.sport_id,
    matches_table.naipe,
    matches_table.home_team_id,
    matches_table.away_team_id,
    GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1),
    matches_table.scheduled_date,
    matches_table.location,
    matches_table.court_name,
    matches_table.start_time,
    matches_table.end_time,
    matches_table.queue_position,
    matches_table.scheduled_slot
  FROM public.matches AS matches_table
  LEFT JOIN public.championship_sports AS championship_sports_table
    ON championship_sports_table.championship_id = matches_table.championship_id
    AND championship_sports_table.sport_id = matches_table.sport_id
  WHERE matches_table.id = ANY(selected_match_ids);

  IF insertion_position IN ('START', 'END') OR target_start_time IS NOT NULL THEN
    INSERT INTO manual_match_relocation_plan (
      match_id, is_selected, source_order, championship_id, season_year, sport_id, naipe,
      home_team_id, away_team_id, duration_minutes, old_scheduled_date, old_location,
      old_court_name, old_start_time, old_end_time, old_queue_position, old_scheduled_slot
    )
    SELECT
      matches_table.id,
      false,
      CASE
        WHEN insertion_position = 'END' THEN row_number() OVER (
          ORDER BY matches_table.start_time, COALESCE(matches_table.scheduled_slot, matches_table.queue_position), matches_table.created_at, matches_table.id
        )
        ELSE 100000 + row_number() OVER (
          ORDER BY matches_table.start_time, COALESCE(matches_table.scheduled_slot, matches_table.queue_position), matches_table.created_at, matches_table.id
        )
      END,
      matches_table.championship_id,
      matches_table.season_year,
      matches_table.sport_id,
      matches_table.naipe,
      matches_table.home_team_id,
      matches_table.away_team_id,
      GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1),
      matches_table.scheduled_date,
      matches_table.location,
      matches_table.court_name,
      matches_table.start_time,
      matches_table.end_time,
      matches_table.queue_position,
      matches_table.scheduled_slot
    FROM public.matches AS matches_table
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = matches_table.championship_id
      AND championship_sports_table.sport_id = matches_table.sport_id
    WHERE matches_table.championship_id = selected_championship_id
      AND matches_table.season_year = selected_season_year
      AND matches_table.status = 'SCHEDULED'::public.match_status
      AND matches_table.id <> ALL(selected_match_ids)
      AND COALESCE(matches_table.is_manual_schedule_override, false) = false
      AND matches_table.scheduled_date = target_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name);
  END IF;

  IF insertion_position = 'END' AND target_start_time IS NULL THEN
    SELECT GREATEST(
      public.combine_bracket_schedule_timestamp(target_date, effective_start_time),
      COALESCE(max(matches_table.start_time + make_interval(mins => GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1))), public.combine_bracket_schedule_timestamp(target_date, effective_start_time))
    )
    INTO current_cursor_at
    FROM public.matches AS matches_table
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = matches_table.championship_id
      AND championship_sports_table.sport_id = matches_table.sport_id
    WHERE matches_table.championship_id = selected_championship_id
      AND matches_table.season_year = selected_season_year
      AND matches_table.id <> ALL(selected_match_ids)
      AND matches_table.scheduled_date = target_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name);
  ELSE
    SELECT GREATEST(
      public.combine_bracket_schedule_timestamp(target_date, effective_start_time),
      COALESCE(max(matches_table.start_time + make_interval(mins => GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1))), public.combine_bracket_schedule_timestamp(target_date, effective_start_time))
    )
    INTO current_cursor_at
    FROM public.matches AS matches_table
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = matches_table.championship_id
      AND championship_sports_table.sport_id = matches_table.sport_id
    WHERE matches_table.championship_id = selected_championship_id
      AND matches_table.season_year = selected_season_year
      AND matches_table.id <> ALL(selected_match_ids)
      AND (
        matches_table.status <> 'SCHEDULED'::public.match_status
        OR COALESCE(matches_table.is_manual_schedule_override, false)
      )
      AND matches_table.scheduled_date = target_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name);
  END IF;

  IF insertion_position = 'END' AND target_start_time IS NULL THEN
    SELECT COALESCE(
      min(old_start_time),
      public.combine_bracket_schedule_timestamp(target_date, effective_start_time)
    )
    INTO current_cursor_at
    FROM manual_match_relocation_plan;
  END IF;

  FOR plan_record IN
    SELECT *
    FROM manual_match_relocation_plan
    WHERE insertion_position IN ('START', 'END') OR is_selected = true OR target_start_time IS NOT NULL
    ORDER BY source_order
  LOOP
    LOOP
      SELECT public.combine_bracket_schedule_timestamp(target_date, breaks_table.break_end_time)
      INTO break_end_at
      FROM public.championship_bracket_day_breaks AS breaks_table
      WHERE breaks_table.bracket_day_id = target_day_record.id
        AND (
          breaks_table.scope_type = 'ALL_COURTS'
          OR (breaks_table.scope_type = 'COURT' AND breaks_table.bracket_court_id = target_court_id)
        )
        AND current_cursor_at < public.combine_bracket_schedule_timestamp(target_date, breaks_table.break_end_time)
        AND current_cursor_at + make_interval(mins => plan_record.duration_minutes) > public.combine_bracket_schedule_timestamp(target_date, breaks_table.break_start_time)
      ORDER BY breaks_table.position, breaks_table.break_start_time
      LIMIT 1;

      EXIT WHEN break_end_at IS NULL;
      current_cursor_at := break_end_at;
      break_end_at := NULL;
    END LOOP;

    planned_end_at := current_cursor_at + make_interval(mins => plan_record.duration_minutes);

    UPDATE manual_match_relocation_plan
    SET new_start_time = current_cursor_at,
        new_end_time = planned_end_at
    WHERE match_id = plan_record.match_id;

    current_cursor_at := planned_end_at;
  END LOOP;

  UPDATE manual_match_relocation_plan AS plan_table
  SET new_queue_position = numbered_matches.position,
      new_scheduled_slot = numbered_matches.slot
  FROM (
    SELECT
      match_id,
      (
        CASE
          WHEN insertion_position = 'END' AND target_start_time IS NULL THEN COALESCE((
            SELECT max(matches_table.queue_position)
            FROM public.matches AS matches_table
            WHERE matches_table.championship_id = selected_championship_id
              AND matches_table.season_year = selected_season_year
              AND matches_table.scheduled_date = target_date
              AND matches_table.id <> ALL(selected_match_ids)
              AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
              AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
          ), 0)
          ELSE 0
        END
        + row_number() OVER (ORDER BY new_start_time, source_order)::INTEGER
      )::INTEGER AS position,
      (
        COALESCE((
          SELECT max(matches_table.scheduled_slot)
          FROM public.matches AS matches_table
          WHERE matches_table.championship_id = selected_championship_id
            AND matches_table.season_year = selected_season_year
            AND matches_table.scheduled_date = target_date
            AND matches_table.id <> ALL(selected_match_ids)
        ), 0)
        + row_number() OVER (ORDER BY new_start_time, source_order)::INTEGER
      )::INTEGER AS slot
    FROM manual_match_relocation_plan
    WHERE new_start_time IS NOT NULL
  ) AS numbered_matches
  WHERE numbered_matches.match_id = plan_table.match_id;

  IF insertion_position = 'END' AND target_start_time IS NULL THEN
    UPDATE manual_match_relocation_plan AS plan_table
    SET
      new_queue_position = numbered_matches.position,
      new_scheduled_slot = numbered_matches.slot
    FROM (
      SELECT
        match_id,
        COALESCE((
          SELECT min(old_queue_position) - 1
          FROM manual_match_relocation_plan
          WHERE new_start_time IS NOT NULL
        ), 0) + row_number() OVER (ORDER BY new_start_time, source_order)::INTEGER AS position,
        COALESCE((
          SELECT min(old_scheduled_slot) - 1
          FROM manual_match_relocation_plan
          WHERE new_start_time IS NOT NULL
        ), 0) + row_number() OVER (ORDER BY new_start_time, source_order)::INTEGER AS slot
      FROM manual_match_relocation_plan
      WHERE new_start_time IS NOT NULL
    ) AS numbered_matches
    WHERE numbered_matches.match_id = plan_table.match_id;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM manual_match_relocation_plan AS first_plan
    JOIN manual_match_relocation_plan AS second_plan
      ON first_plan.match_id < second_plan.match_id
    WHERE (
      first_plan.home_team_id IN (second_plan.home_team_id, second_plan.away_team_id)
      OR first_plan.away_team_id IN (second_plan.home_team_id, second_plan.away_team_id)
    )
      AND public.is_championship_team_rest_gap_conflict(
        first_plan.naipe,
        second_plan.naipe,
        true,
        first_plan.new_queue_position,
        second_plan.new_queue_position,
        first_plan.new_start_time,
        second_plan.new_start_time,
        first_plan.duration_minutes,
        second_plan.duration_minutes,
        false
      )
  ) INTO has_rest_conflict;

  IF has_rest_conflict THEN
    blockers := blockers || jsonb_build_array('A realocação não preserva o descanso mínimo entre atléticas na quadra de destino.');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM manual_match_relocation_plan AS plan_table
    LEFT JOIN public.championship_bracket_matches AS plan_bracket_matches_table
      ON plan_bracket_matches_table.match_id = plan_table.match_id
    JOIN public.matches AS other_matches_table
      ON other_matches_table.championship_id = plan_table.championship_id
      AND other_matches_table.season_year = plan_table.season_year
      AND other_matches_table.scheduled_date = target_date
      AND other_matches_table.status = 'SCHEDULED'::public.match_status
      AND other_matches_table.id NOT IN (SELECT match_id FROM manual_match_relocation_plan)
      AND public.normalize_bracket_entity_name(other_matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(other_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
      AND (
        other_matches_table.home_team_id IN (plan_table.home_team_id, plan_table.away_team_id)
        OR other_matches_table.away_team_id IN (plan_table.home_team_id, plan_table.away_team_id)
      )
    LEFT JOIN public.championship_sports AS other_championship_sports_table
      ON other_championship_sports_table.championship_id = other_matches_table.championship_id
      AND other_championship_sports_table.sport_id = other_matches_table.sport_id
    LEFT JOIN public.championship_bracket_matches AS other_bracket_matches_table
      ON other_bracket_matches_table.match_id = other_matches_table.id
    WHERE public.is_championship_team_rest_gap_conflict(
      plan_table.naipe,
      other_matches_table.naipe,
      true,
      plan_table.new_queue_position,
      other_matches_table.queue_position,
      plan_table.new_start_time,
      other_matches_table.start_time,
      plan_table.duration_minutes,
      GREATEST(COALESCE(other_championship_sports_table.default_match_duration_minutes, 35), 1),
      COALESCE(plan_bracket_matches_table.group_id IS NULL, false)
        OR COALESCE(other_bracket_matches_table.group_id IS NULL, false)
    )
  ) INTO has_rest_conflict;

  IF has_rest_conflict THEN
    blockers := blockers || jsonb_build_array('A realocação não preserva o descanso mínimo em relação a uma reserva manual já existente na quadra de destino.');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM manual_match_relocation_plan AS plan_table
    LEFT JOIN public.championship_bracket_matches AS plan_bracket_matches_table
      ON plan_bracket_matches_table.match_id = plan_table.match_id
    JOIN public.matches AS other_matches_table
      ON other_matches_table.championship_id = plan_table.championship_id
      AND other_matches_table.season_year = plan_table.season_year
      AND other_matches_table.scheduled_date = target_date
      AND other_matches_table.status = 'SCHEDULED'::public.match_status
      AND other_matches_table.id NOT IN (SELECT match_id FROM manual_match_relocation_plan)
      AND (
        public.normalize_bracket_entity_name(other_matches_table.location) <> public.normalize_bracket_entity_name(target_location)
        OR public.normalize_bracket_entity_name(other_matches_table.court_name) <> public.normalize_bracket_entity_name(target_court_name)
      )
      AND (
        other_matches_table.home_team_id IN (plan_table.home_team_id, plan_table.away_team_id)
        OR other_matches_table.away_team_id IN (plan_table.home_team_id, plan_table.away_team_id)
      )
    LEFT JOIN public.championship_sports AS other_championship_sports_table
      ON other_championship_sports_table.championship_id = other_matches_table.championship_id
      AND other_championship_sports_table.sport_id = other_matches_table.sport_id
    LEFT JOIN public.championship_bracket_matches AS other_bracket_matches_table
      ON other_bracket_matches_table.match_id = other_matches_table.id
    WHERE public.is_championship_team_rest_gap_conflict(
      plan_table.naipe,
      other_matches_table.naipe,
      false,
      NULL,
      NULL,
      plan_table.new_start_time,
      other_matches_table.start_time,
      plan_table.duration_minutes,
      GREATEST(COALESCE(other_championship_sports_table.default_match_duration_minutes, 35), 1),
      COALESCE(plan_bracket_matches_table.group_id IS NULL, false)
        OR COALESCE(other_bracket_matches_table.group_id IS NULL, false)
    )
  ) INTO has_rest_conflict;

  IF has_rest_conflict THEN
    blockers := blockers || jsonb_build_array('A realocação não preserva o descanso mínimo em relação a jogos de outra quadra.');
  END IF;

  SELECT to_char(public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI')
  INTO previous_day_start;

  SELECT to_char(public.combine_bracket_schedule_timestamp(target_date, effective_start_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI')
  INTO next_day_start;

  SELECT to_char(public.combine_bracket_schedule_timestamp(target_date, target_day_record.end_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI')
  INTO previous_day_end;

  SELECT to_char(GREATEST(
    public.combine_bracket_schedule_timestamp(target_date, target_day_record.end_time),
    COALESCE(max(new_end_time), public.combine_bracket_schedule_timestamp(target_date, target_day_record.end_time))
  ) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI')
  INTO next_day_end
  FROM manual_match_relocation_plan;

  IF EXISTS (
    SELECT 1
    FROM manual_match_relocation_plan
    WHERE (new_end_time AT TIME ZONE 'America/Sao_Paulo')::DATE > target_date
  ) THEN
    blockers := blockers || jsonb_build_array('A realocação ultrapassa meia-noite e deve ser dividida em outro dia configurado.');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'match_id', plan_table.match_id,
    'is_selected', plan_table.is_selected,
    'before', jsonb_build_object(
      'scheduled_date', plan_table.old_scheduled_date,
      'location', plan_table.old_location,
      'court_name', plan_table.old_court_name,
      'start_time', plan_table.old_start_time,
      'end_time', plan_table.old_end_time,
      'queue_position', plan_table.old_queue_position,
      'scheduled_slot', plan_table.old_scheduled_slot
    ),
    'after', jsonb_build_object(
      'scheduled_date', target_date,
      'location', target_location,
      'court_name', target_court_name,
      'start_time', plan_table.new_start_time,
      'end_time', plan_table.new_end_time,
      'queue_position', plan_table.new_queue_position,
      'scheduled_slot', plan_table.new_scheduled_slot
    )
  ) ORDER BY plan_table.new_start_time, plan_table.source_order), '[]'::JSONB)
  INTO changes
  FROM manual_match_relocation_plan AS plan_table
  WHERE plan_table.new_start_time IS NOT NULL;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'match_id', matches_table.id,
    'status', matches_table.status,
    'start_time', COALESCE(plan_table.new_start_time, matches_table.start_time),
    'end_time', COALESCE(plan_table.new_end_time, matches_table.end_time),
    'location', CASE WHEN plan_table.new_start_time IS NOT NULL THEN target_location ELSE matches_table.location END,
    'court_name', CASE WHEN plan_table.new_start_time IS NOT NULL THEN target_court_name ELSE matches_table.court_name END,
    'is_relocated', COALESCE(plan_table.is_selected, false),
    'is_displaced', COALESCE(plan_table.is_selected, false) = false AND plan_table.match_id IS NOT NULL
  ) ORDER BY COALESCE(plan_table.new_start_time, matches_table.start_time), matches_table.id), '[]'::JSONB)
  INTO timeline
  FROM (
    SELECT
      matches_table.id,
      matches_table.status,
      matches_table.start_time,
      matches_table.end_time,
      matches_table.location,
      matches_table.court_name,
      plan_table.new_start_time,
      plan_table.new_end_time,
      plan_table.is_selected,
      plan_table.match_id AS planned_match_id
    FROM public.matches AS matches_table
    LEFT JOIN manual_match_relocation_plan AS plan_table
      ON plan_table.match_id = matches_table.id
    WHERE matches_table.championship_id = selected_championship_id
      AND matches_table.season_year = selected_season_year
      AND matches_table.scheduled_date = target_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)

    UNION ALL

    SELECT
      plan_table.match_id,
      'SCHEDULED'::public.match_status,
      NULL,
      NULL,
      target_location,
      target_court_name,
      plan_table.new_start_time,
      plan_table.new_end_time,
      plan_table.is_selected,
      plan_table.match_id
    FROM manual_match_relocation_plan AS plan_table
    WHERE plan_table.is_selected
      AND NOT EXISTS (
        SELECT 1
        FROM public.matches AS matches_table
        WHERE matches_table.id = plan_table.match_id
          AND matches_table.scheduled_date = target_date
          AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
          AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
      )
  ) AS matches_table
  LEFT JOIN manual_match_relocation_plan AS plan_table
    ON plan_table.match_id = matches_table.id;

  revision_value := COALESCE(bracket_edition_record.reprogramming_revision, 0);

  RETURN jsonb_build_object(
    'revision', revision_value,
    'blockers', blockers,
    'changes', changes,
    'timeline', timeline,
    'previous_day_start', previous_day_start,
    'next_day_start', next_day_start,
    'advances_day_start', effective_start_time < target_day_record.start_time,
    'previous_day_end', previous_day_end,
    'next_day_end', next_day_end,
    'extends_day_end', next_day_end > previous_day_end,
    'target_date', target_date,
    'target_location', target_location,
    'target_court_name', target_court_name,
    'insertion_position', insertion_position,
    'reason', relocation_reason,
    'notes', relocation_notes,
    'representation_warning', 'A representação dos jogos realocados deve ser conferida na timeline antes da confirmação.'
  );
END;
$function$;

-- Original: build_manual_match_relocation_slot_preview(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.build_manual_match_relocation_slot_preview(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN public.append_manual_relocation_placeholders(
    _bracket_edition_id,
    public.build_manual_match_relocation_slot_preview_base(
      _bracket_edition_id,
      _payload
    )
  );
END;
$function$;

-- Original: build_manual_match_relocation_slot_preview_base(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.build_manual_match_relocation_slot_preview_base(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  selected_match_id UUID;
  selected_match_record RECORD;
  target_date DATE;
  target_location TEXT;
  target_court_name TEXT;
  target_slot_id TEXT;
  target_slot_descriptor TEXT;
  target_anchor_match_id UUID;
  target_anchor_record RECORD;
  target_day_record RECORD;
  target_court_id UUID;
  target_start_at TIMESTAMPTZ;
  current_cursor_at TIMESTAMPTZ;
  planned_end_at TIMESTAMPTZ;
  break_end_at TIMESTAMPTZ;
  plan_record RECORD;
  selected_duration_minutes INTEGER;
  relocation_reason TEXT;
  relocation_notes TEXT;
  revision_value BIGINT;
  slots JSONB := '[]'::JSONB;
  blockers JSONB := '[]'::JSONB;
  changes JSONB := '[]'::JSONB;
  timeline JSONB := '[]'::JSONB;
  previous_day_end TEXT;
  next_day_end TEXT;
  has_rest_conflict BOOLEAN := false;
BEGIN
  SELECT value::UUID
  INTO selected_match_id
  FROM jsonb_array_elements_text(COALESCE(_payload->'match_ids', '[]'::JSONB)) AS value
  LIMIT 1;

  IF jsonb_array_length(COALESCE(_payload->'match_ids', '[]'::JSONB)) <> 1 THEN
    RAISE EXCEPTION 'O encaixe em horário livre aceita somente um jogo agendado.';
  END IF;

  target_date := NULLIF(_payload->>'target_date', '')::DATE;
  target_location := NULLIF(trim(COALESCE(_payload->>'target_location', '')), '');
  target_court_name := NULLIF(trim(COALESCE(_payload->>'target_court_name', '')), '');
  target_slot_id := NULLIF(trim(COALESCE(_payload->>'target_slot_id', '')), '');
  relocation_reason := upper(trim(COALESCE(_payload->>'reason', '')));
  relocation_notes := NULLIF(trim(COALESCE(_payload->>'notes', '')), '');

  IF target_date IS NULL OR target_location IS NULL OR target_court_name IS NULL THEN
    RAISE EXCEPTION 'Informe dia, local e quadra de destino.';
  END IF;

  IF upper(trim(COALESCE(_payload->>'insertion_position', ''))) <> 'SLOT' THEN
    RAISE EXCEPTION 'A posição do encaixe deve ser um horário livre.';
  END IF;

  IF relocation_reason NOT IN ('WEATHER', 'COURT_UNAVAILABLE', 'OPERATIONAL_DELAY', 'SAFETY', 'OTHER') THEN
    RAISE EXCEPTION 'Informe um motivo válido para a realocação.';
  END IF;

  SELECT
    matches_table.*,
    GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1) AS duration_minutes,
    editions_table.reprogramming_revision
  INTO selected_match_record
  FROM public.matches AS matches_table
  JOIN public.championship_bracket_editions AS editions_table
    ON editions_table.id = _bracket_edition_id
    AND editions_table.championship_id = matches_table.championship_id
    AND editions_table.season_year = matches_table.season_year
  LEFT JOIN public.championship_sports AS championship_sports_table
    ON championship_sports_table.championship_id = matches_table.championship_id
    AND championship_sports_table.sport_id = matches_table.sport_id
  WHERE matches_table.id = selected_match_id
    AND matches_table.status = 'SCHEDULED'::public.match_status;

  IF selected_match_record.id IS NULL THEN
    RAISE EXCEPTION 'Somente jogos agendados da edição selecionada podem ser encaixados.';
  END IF;

  selected_duration_minutes := selected_match_record.duration_minutes;
  revision_value := selected_match_record.reprogramming_revision;

  SELECT days_table.id, days_table.start_time, days_table.end_time
  INTO target_day_record
  FROM public.championship_bracket_days AS days_table
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND days_table.event_date = target_date
  LIMIT 1;

  IF target_day_record.id IS NULL THEN
    RAISE EXCEPTION 'O dia de destino não está configurado na agenda do campeonato.';
  END IF;

  SELECT courts_table.id
  INTO target_court_id
  FROM public.championship_bracket_locations AS locations_table
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
  WHERE locations_table.bracket_day_id = target_day_record.id
    AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(target_location)
    AND public.normalize_bracket_entity_name(courts_table.name) = public.normalize_bracket_entity_name(target_court_name)
  LIMIT 1;

  IF target_court_id IS NULL THEN
    RAISE EXCEPTION 'A quadra de destino não está configurada nesse dia.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.championship_bracket_court_sports AS court_sports_table
    WHERE court_sports_table.bracket_court_id = target_court_id
      AND court_sports_table.sport_id = selected_match_record.sport_id
  ) THEN
    RAISE EXCEPTION 'A quadra de destino não está configurada para esta modalidade.';
  END IF;

  IF target_slot_id IS NULL THEN
    SELECT COALESCE(jsonb_agg(slot_data.value ORDER BY slot_data.start_at, slot_data.position), '[]'::JSONB)
    INTO slots
    FROM (
      SELECT
        candidate_matches_table.start_time AS start_at,
        1 AS position,
        jsonb_build_object(
          'id', encode(convert_to(format('BEFORE:%s', candidate_matches_table.id), 'UTF8'), 'base64'),
          'start_time', GREATEST(
            public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time),
            COALESCE((
              SELECT max(COALESCE(previous_matches_table.end_time, previous_matches_table.start_time + make_interval(mins => GREATEST(COALESCE(previous_sports_table.default_match_duration_minutes, 35), 1))))
              FROM public.matches AS previous_matches_table
              LEFT JOIN public.championship_sports AS previous_sports_table
                ON previous_sports_table.championship_id = previous_matches_table.championship_id
                AND previous_sports_table.sport_id = previous_matches_table.sport_id
              WHERE previous_matches_table.championship_id = selected_match_record.championship_id
                AND previous_matches_table.season_year = selected_match_record.season_year
                AND previous_matches_table.id <> selected_match_id
                AND previous_matches_table.scheduled_date = target_date
                AND public.normalize_bracket_entity_name(previous_matches_table.location) = public.normalize_bracket_entity_name(target_location)
                AND public.normalize_bracket_entity_name(previous_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
                AND previous_matches_table.start_time < candidate_matches_table.start_time
            ), public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time))
          ),
          'end_time', GREATEST(
            public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time),
            COALESCE((
              SELECT max(COALESCE(previous_matches_table.end_time, previous_matches_table.start_time + make_interval(mins => GREATEST(COALESCE(previous_sports_table.default_match_duration_minutes, 35), 1))))
              FROM public.matches AS previous_matches_table
              LEFT JOIN public.championship_sports AS previous_sports_table
                ON previous_sports_table.championship_id = previous_matches_table.championship_id
                AND previous_sports_table.sport_id = previous_matches_table.sport_id
              WHERE previous_matches_table.championship_id = selected_match_record.championship_id
                AND previous_matches_table.season_year = selected_match_record.season_year
                AND previous_matches_table.id <> selected_match_id
                AND previous_matches_table.scheduled_date = target_date
                AND public.normalize_bracket_entity_name(previous_matches_table.location) = public.normalize_bracket_entity_name(target_location)
                AND public.normalize_bracket_entity_name(previous_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
                AND previous_matches_table.start_time < candidate_matches_table.start_time
            ), public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time))
          ) + make_interval(mins => selected_duration_minutes),
          'next_match_id', candidate_matches_table.id,
          'next_match_label', concat_ws(' x ', home_teams_table.name, away_teams_table.name),
          'displaced_matches_count', (
            SELECT count(*)
            FROM public.matches AS displaced_matches_table
            WHERE displaced_matches_table.championship_id = selected_match_record.championship_id
              AND displaced_matches_table.season_year = selected_match_record.season_year
              AND displaced_matches_table.status = 'SCHEDULED'::public.match_status
              AND displaced_matches_table.id <> selected_match_id
              AND COALESCE(displaced_matches_table.is_manual_schedule_override, false) = false
              AND COALESCE(displaced_matches_table.is_pending_manual_relocation, false) = false
              AND displaced_matches_table.scheduled_date = target_date
              AND public.normalize_bracket_entity_name(displaced_matches_table.location) = public.normalize_bracket_entity_name(target_location)
              AND public.normalize_bracket_entity_name(displaced_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
              AND displaced_matches_table.start_time >= candidate_matches_table.start_time
          ),
          'is_free_gap', candidate_matches_table.start_time >= GREATEST(
            public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time),
            COALESCE((
              SELECT max(COALESCE(previous_matches_table.end_time, previous_matches_table.start_time + make_interval(mins => GREATEST(COALESCE(previous_sports_table.default_match_duration_minutes, 35), 1))))
              FROM public.matches AS previous_matches_table
              LEFT JOIN public.championship_sports AS previous_sports_table
                ON previous_sports_table.championship_id = previous_matches_table.championship_id
                AND previous_sports_table.sport_id = previous_matches_table.sport_id
              WHERE previous_matches_table.championship_id = selected_match_record.championship_id
                AND previous_matches_table.season_year = selected_match_record.season_year
                AND previous_matches_table.id <> selected_match_id
                AND previous_matches_table.scheduled_date = target_date
                AND public.normalize_bracket_entity_name(previous_matches_table.location) = public.normalize_bracket_entity_name(target_location)
                AND public.normalize_bracket_entity_name(previous_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
                AND previous_matches_table.start_time < candidate_matches_table.start_time
            ), public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time))
          ) + make_interval(mins => selected_duration_minutes),
          'is_projected_from_live_match', EXISTS (
            SELECT 1
            FROM public.matches AS live_matches_table
            WHERE live_matches_table.championship_id = selected_match_record.championship_id
              AND live_matches_table.season_year = selected_match_record.season_year
              AND live_matches_table.status = 'LIVE'::public.match_status
              AND live_matches_table.scheduled_date = target_date
              AND public.normalize_bracket_entity_name(live_matches_table.location) = public.normalize_bracket_entity_name(target_location)
              AND public.normalize_bracket_entity_name(live_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
              AND live_matches_table.start_time < candidate_matches_table.start_time
          )
        ) AS value
      FROM public.matches AS candidate_matches_table
      LEFT JOIN public.teams AS home_teams_table ON home_teams_table.id = candidate_matches_table.home_team_id
      LEFT JOIN public.teams AS away_teams_table ON away_teams_table.id = candidate_matches_table.away_team_id
      WHERE candidate_matches_table.championship_id = selected_match_record.championship_id
        AND candidate_matches_table.season_year = selected_match_record.season_year
        AND candidate_matches_table.status = 'SCHEDULED'::public.match_status
        AND candidate_matches_table.id <> selected_match_id
        AND COALESCE(candidate_matches_table.is_manual_schedule_override, false) = false
        AND COALESCE(candidate_matches_table.is_pending_manual_relocation, false) = false
        AND candidate_matches_table.scheduled_date = target_date
        AND public.normalize_bracket_entity_name(candidate_matches_table.location) = public.normalize_bracket_entity_name(target_location)
        AND public.normalize_bracket_entity_name(candidate_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)

      UNION ALL

      SELECT
        COALESCE(max(COALESCE(existing_matches_table.end_time, existing_matches_table.start_time + make_interval(mins => GREATEST(COALESCE(existing_sports_table.default_match_duration_minutes, 35), 1)))), public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time)),
        2,
        jsonb_build_object(
          'id', encode(convert_to('END', 'UTF8'), 'base64'),
          'start_time', COALESCE(max(COALESCE(existing_matches_table.end_time, existing_matches_table.start_time + make_interval(mins => GREATEST(COALESCE(existing_sports_table.default_match_duration_minutes, 35), 1)))), public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time)),
          'end_time', COALESCE(max(COALESCE(existing_matches_table.end_time, existing_matches_table.start_time + make_interval(mins => GREATEST(COALESCE(existing_sports_table.default_match_duration_minutes, 35), 1)))), public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time)) + make_interval(mins => selected_duration_minutes),
          'next_match_id', NULL,
          'next_match_label', NULL,
          'displaced_matches_count', 0,
          'is_free_gap', true,
          'is_projected_from_live_match', EXISTS (
            SELECT 1 FROM public.matches AS live_matches_table
            WHERE live_matches_table.championship_id = selected_match_record.championship_id
              AND live_matches_table.season_year = selected_match_record.season_year
              AND live_matches_table.status = 'LIVE'::public.match_status
              AND live_matches_table.scheduled_date = target_date
              AND public.normalize_bracket_entity_name(live_matches_table.location) = public.normalize_bracket_entity_name(target_location)
              AND public.normalize_bracket_entity_name(live_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
          )
        )
      FROM public.matches AS existing_matches_table
      LEFT JOIN public.championship_sports AS existing_sports_table
        ON existing_sports_table.championship_id = existing_matches_table.championship_id
        AND existing_sports_table.sport_id = existing_matches_table.sport_id
      WHERE existing_matches_table.championship_id = selected_match_record.championship_id
        AND existing_matches_table.season_year = selected_match_record.season_year
        AND existing_matches_table.id <> selected_match_id
        AND existing_matches_table.scheduled_date = target_date
        AND public.normalize_bracket_entity_name(existing_matches_table.location) = public.normalize_bracket_entity_name(target_location)
        AND public.normalize_bracket_entity_name(existing_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
    ) AS slot_data;

    RETURN jsonb_build_object(
      'revision', revision_value,
      'blockers', '[]'::JSONB,
      'changes', '[]'::JSONB,
      'timeline', '[]'::JSONB,
      'slots', slots,
      'previous_day_start', to_char(public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'next_day_start', to_char(public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'advances_day_start', false,
      'previous_day_end', to_char(public.combine_bracket_schedule_timestamp(target_date, target_day_record.end_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'next_day_end', to_char(public.combine_bracket_schedule_timestamp(target_date, target_day_record.end_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'extends_day_end', false,
      'target_date', target_date,
      'target_location', target_location,
      'target_court_name', target_court_name,
      'insertion_position', 'SLOT',
      'reason', relocation_reason,
      'notes', relocation_notes,
      'representation_warning', NULL
    );
  END IF;

  target_slot_descriptor := convert_from(decode(target_slot_id, 'base64'), 'UTF8');

  IF target_slot_descriptor = 'END' THEN
    SELECT GREATEST(
      public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time),
      COALESCE(max(COALESCE(matches_table.end_time, matches_table.start_time + make_interval(mins => GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1)))), public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time))
    )
    INTO current_cursor_at
    FROM public.matches AS matches_table
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = matches_table.championship_id
      AND championship_sports_table.sport_id = matches_table.sport_id
    WHERE matches_table.championship_id = selected_match_record.championship_id
      AND matches_table.season_year = selected_match_record.season_year
      AND matches_table.id <> selected_match_id
      AND matches_table.scheduled_date = target_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name);
  ELSE
    target_anchor_match_id := NULLIF(split_part(target_slot_descriptor, ':', 2), '')::UUID;

    SELECT matches_table.*
    INTO target_anchor_record
    FROM public.matches AS matches_table
    WHERE matches_table.id = target_anchor_match_id
      AND matches_table.championship_id = selected_match_record.championship_id
      AND matches_table.season_year = selected_match_record.season_year
      AND matches_table.status = 'SCHEDULED'::public.match_status
      AND COALESCE(matches_table.is_manual_schedule_override, false) = false
      AND COALESCE(matches_table.is_pending_manual_relocation, false) = false
      AND matches_table.scheduled_date = target_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name);

    IF target_anchor_record.id IS NULL OR target_slot_descriptor NOT LIKE 'BEFORE:%' THEN
      RAISE EXCEPTION 'O horário livre selecionado não está mais disponível. Busque os horários novamente.';
    END IF;

    target_start_at := target_anchor_record.start_time;

    SELECT GREATEST(
      public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time),
      COALESCE(max(COALESCE(matches_table.end_time, matches_table.start_time + make_interval(mins => GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1)))), public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time))
    )
    INTO current_cursor_at
    FROM public.matches AS matches_table
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = matches_table.championship_id
      AND championship_sports_table.sport_id = matches_table.sport_id
    WHERE matches_table.championship_id = selected_match_record.championship_id
      AND matches_table.season_year = selected_match_record.season_year
      AND matches_table.id <> selected_match_id
      AND matches_table.scheduled_date = target_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
      AND matches_table.start_time < target_start_at;
  END IF;

  CREATE TEMP TABLE manual_match_relocation_slot_plan (
    match_id UUID PRIMARY KEY,
    is_selected BOOLEAN NOT NULL,
    source_order INTEGER NOT NULL,
    championship_id UUID NOT NULL,
    season_year INTEGER NOT NULL,
    sport_id UUID NOT NULL,
    naipe public.match_naipe NOT NULL,
    home_team_id UUID NOT NULL,
    away_team_id UUID NOT NULL,
    duration_minutes INTEGER NOT NULL,
    old_scheduled_date DATE NULL,
    old_location TEXT NULL,
    old_court_name TEXT NULL,
    old_start_time TIMESTAMPTZ NULL,
    old_end_time TIMESTAMPTZ NULL,
    old_queue_position INTEGER NULL,
    old_scheduled_slot INTEGER NULL,
    new_start_time TIMESTAMPTZ NULL,
    new_end_time TIMESTAMPTZ NULL,
    new_queue_position INTEGER NULL,
    new_scheduled_slot INTEGER NULL
  ) ON COMMIT DROP;

  INSERT INTO manual_match_relocation_slot_plan (
    match_id, is_selected, source_order, championship_id, season_year, sport_id, naipe,
    home_team_id, away_team_id, duration_minutes, old_scheduled_date, old_location,
    old_court_name, old_start_time, old_end_time, old_queue_position, old_scheduled_slot
  ) VALUES (
    selected_match_record.id, true, 0, selected_match_record.championship_id,
    selected_match_record.season_year, selected_match_record.sport_id, selected_match_record.naipe,
    selected_match_record.home_team_id, selected_match_record.away_team_id, selected_duration_minutes,
    selected_match_record.scheduled_date, selected_match_record.location, selected_match_record.court_name,
    selected_match_record.start_time, selected_match_record.end_time, selected_match_record.queue_position,
    selected_match_record.scheduled_slot
  );

  IF target_slot_descriptor <> 'END' THEN
    INSERT INTO manual_match_relocation_slot_plan (
      match_id, is_selected, source_order, championship_id, season_year, sport_id, naipe,
      home_team_id, away_team_id, duration_minutes, old_scheduled_date, old_location,
      old_court_name, old_start_time, old_end_time, old_queue_position, old_scheduled_slot
    )
    SELECT
      matches_table.id, false,
      row_number() OVER (ORDER BY matches_table.start_time, COALESCE(matches_table.scheduled_slot, matches_table.queue_position), matches_table.created_at, matches_table.id),
      matches_table.championship_id, matches_table.season_year, matches_table.sport_id, matches_table.naipe,
      matches_table.home_team_id, matches_table.away_team_id,
      GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1),
      matches_table.scheduled_date, matches_table.location, matches_table.court_name, matches_table.start_time,
      matches_table.end_time, matches_table.queue_position, matches_table.scheduled_slot
    FROM public.matches AS matches_table
    LEFT JOIN public.championship_sports AS championship_sports_table
      ON championship_sports_table.championship_id = matches_table.championship_id
      AND championship_sports_table.sport_id = matches_table.sport_id
    WHERE matches_table.championship_id = selected_match_record.championship_id
      AND matches_table.season_year = selected_match_record.season_year
      AND matches_table.status = 'SCHEDULED'::public.match_status
      AND matches_table.id <> selected_match_id
      AND COALESCE(matches_table.is_manual_schedule_override, false) = false
      AND COALESCE(matches_table.is_pending_manual_relocation, false) = false
      AND matches_table.scheduled_date = target_date
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
      AND matches_table.start_time >= target_start_at;
  END IF;

  FOR plan_record IN
    SELECT * FROM manual_match_relocation_slot_plan ORDER BY source_order
  LOOP
    IF NOT plan_record.is_selected THEN
      current_cursor_at := GREATEST(current_cursor_at, plan_record.old_start_time);
    END IF;

    LOOP
      SELECT public.combine_bracket_schedule_timestamp(target_date, breaks_table.break_end_time)
      INTO break_end_at
      FROM public.championship_bracket_day_breaks AS breaks_table
      WHERE breaks_table.bracket_day_id = target_day_record.id
        AND (breaks_table.scope_type = 'ALL_COURTS' OR (breaks_table.scope_type = 'COURT' AND breaks_table.bracket_court_id = target_court_id))
        AND current_cursor_at < public.combine_bracket_schedule_timestamp(target_date, breaks_table.break_end_time)
        AND current_cursor_at + make_interval(mins => plan_record.duration_minutes) > public.combine_bracket_schedule_timestamp(target_date, breaks_table.break_start_time)
      ORDER BY breaks_table.position, breaks_table.break_start_time
      LIMIT 1;

      EXIT WHEN break_end_at IS NULL;
      current_cursor_at := break_end_at;
      break_end_at := NULL;
    END LOOP;

    planned_end_at := current_cursor_at + make_interval(mins => plan_record.duration_minutes);
    UPDATE manual_match_relocation_slot_plan
    SET new_start_time = current_cursor_at, new_end_time = planned_end_at
    WHERE match_id = plan_record.match_id;
    current_cursor_at := planned_end_at;
  END LOOP;

  UPDATE manual_match_relocation_slot_plan AS plan_table
  SET new_queue_position = numbered_matches.position,
      new_scheduled_slot = numbered_matches.slot
  FROM (
    SELECT
      plan_table.match_id,
      (
        COALESCE((
          SELECT count(*)
          FROM public.matches AS previous_matches_table
          WHERE previous_matches_table.championship_id = selected_match_record.championship_id
            AND previous_matches_table.season_year = selected_match_record.season_year
            AND previous_matches_table.scheduled_date = target_date
            AND public.normalize_bracket_entity_name(previous_matches_table.location) = public.normalize_bracket_entity_name(target_location)
            AND public.normalize_bracket_entity_name(previous_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
            AND previous_matches_table.id NOT IN (SELECT match_id FROM manual_match_relocation_slot_plan)
            AND previous_matches_table.start_time < plan_table.new_start_time
        ), 0) + row_number() OVER (ORDER BY plan_table.new_start_time, plan_table.source_order)
      )::INTEGER AS position,
      (
        COALESCE((
          SELECT max(previous_matches_table.scheduled_slot)
          FROM public.matches AS previous_matches_table
          WHERE previous_matches_table.championship_id = selected_match_record.championship_id
            AND previous_matches_table.season_year = selected_match_record.season_year
            AND previous_matches_table.scheduled_date = target_date
            AND previous_matches_table.id NOT IN (SELECT match_id FROM manual_match_relocation_slot_plan)
        ), 0) + row_number() OVER (ORDER BY plan_table.new_start_time, plan_table.source_order)
      )::INTEGER AS slot
    FROM manual_match_relocation_slot_plan AS plan_table
  ) AS numbered_matches
  WHERE plan_table.match_id = numbered_matches.match_id;

  IF EXISTS (
    SELECT 1
    FROM manual_match_relocation_slot_plan AS plan_table
    JOIN public.matches AS other_matches_table
      ON other_matches_table.championship_id = plan_table.championship_id
      AND other_matches_table.season_year = plan_table.season_year
      AND other_matches_table.scheduled_date = target_date
      AND other_matches_table.id NOT IN (SELECT match_id FROM manual_match_relocation_slot_plan)
      AND public.normalize_bracket_entity_name(other_matches_table.location) = public.normalize_bracket_entity_name(target_location)
      AND public.normalize_bracket_entity_name(other_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name)
      AND other_matches_table.start_time < plan_table.new_end_time
      AND COALESCE(
        other_matches_table.end_time,
        other_matches_table.start_time + interval '35 minutes'
      ) > plan_table.new_start_time
  ) THEN
    blockers := blockers || jsonb_build_array('O encaixe cria sobreposição física com uma ocupação fixa da quadra.');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM manual_match_relocation_slot_plan AS first_plan
    JOIN manual_match_relocation_slot_plan AS second_plan
      ON first_plan.match_id < second_plan.match_id
    WHERE (first_plan.home_team_id IN (second_plan.home_team_id, second_plan.away_team_id) OR first_plan.away_team_id IN (second_plan.home_team_id, second_plan.away_team_id))
      AND public.is_championship_team_rest_gap_conflict(first_plan.naipe, second_plan.naipe, true, first_plan.new_queue_position, second_plan.new_queue_position, first_plan.new_start_time, second_plan.new_start_time, first_plan.duration_minutes, second_plan.duration_minutes, false)
  ) INTO has_rest_conflict;

  IF has_rest_conflict THEN
    blockers := blockers || jsonb_build_array('O encaixe não preserva o descanso mínimo entre atléticas na quadra de destino.');
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM manual_match_relocation_slot_plan AS plan_table
    JOIN public.matches AS other_matches_table
      ON other_matches_table.championship_id = plan_table.championship_id
      AND other_matches_table.season_year = plan_table.season_year
      AND other_matches_table.scheduled_date = target_date
      AND other_matches_table.id NOT IN (SELECT match_id FROM manual_match_relocation_slot_plan)
      AND (other_matches_table.home_team_id IN (plan_table.home_team_id, plan_table.away_team_id) OR other_matches_table.away_team_id IN (plan_table.home_team_id, plan_table.away_team_id))
    LEFT JOIN public.championship_sports AS other_sports_table
      ON other_sports_table.championship_id = other_matches_table.championship_id
      AND other_sports_table.sport_id = other_matches_table.sport_id
    WHERE public.is_championship_team_rest_gap_conflict(
      plan_table.naipe, other_matches_table.naipe,
      public.normalize_bracket_entity_name(other_matches_table.location) = public.normalize_bracket_entity_name(target_location)
        AND public.normalize_bracket_entity_name(other_matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name),
      plan_table.new_queue_position, other_matches_table.queue_position,
      plan_table.new_start_time, other_matches_table.start_time,
      plan_table.duration_minutes, GREATEST(COALESCE(other_sports_table.default_match_duration_minutes, 35), 1), false
    )
  ) INTO has_rest_conflict;

  IF has_rest_conflict THEN
    blockers := blockers || jsonb_build_array('O encaixe não preserva o descanso mínimo em relação aos demais jogos.');
  END IF;

  SELECT to_char(public.combine_bracket_schedule_timestamp(target_date, target_day_record.end_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') INTO previous_day_end;
  SELECT to_char(GREATEST(public.combine_bracket_schedule_timestamp(target_date, target_day_record.end_time), COALESCE(max(new_end_time), public.combine_bracket_schedule_timestamp(target_date, target_day_record.end_time))) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') INTO next_day_end FROM manual_match_relocation_slot_plan;

  IF EXISTS (SELECT 1 FROM manual_match_relocation_slot_plan WHERE (new_end_time AT TIME ZONE 'America/Sao_Paulo')::DATE > target_date) THEN
    blockers := blockers || jsonb_build_array('O encaixe ultrapassa meia-noite e deve ser dividido em outro dia configurado.');
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'match_id', plan_table.match_id,
    'is_selected', plan_table.is_selected,
    'before', jsonb_build_object('scheduled_date', plan_table.old_scheduled_date, 'location', plan_table.old_location, 'court_name', plan_table.old_court_name, 'start_time', plan_table.old_start_time, 'end_time', plan_table.old_end_time, 'queue_position', plan_table.old_queue_position, 'scheduled_slot', plan_table.old_scheduled_slot),
    'after', jsonb_build_object('scheduled_date', target_date, 'location', target_location, 'court_name', target_court_name, 'start_time', plan_table.new_start_time, 'end_time', plan_table.new_end_time, 'queue_position', plan_table.new_queue_position, 'scheduled_slot', plan_table.new_scheduled_slot)
  ) ORDER BY plan_table.new_start_time, plan_table.source_order), '[]'::JSONB)
  INTO changes
  FROM manual_match_relocation_slot_plan AS plan_table;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'match_id', matches_table.id,
    'status', matches_table.status,
    'start_time', COALESCE(plan_table.new_start_time, matches_table.start_time),
    'end_time', COALESCE(plan_table.new_end_time, matches_table.end_time),
    'location', COALESCE(CASE WHEN plan_table.match_id IS NOT NULL THEN target_location END, matches_table.location),
    'court_name', COALESCE(CASE WHEN plan_table.match_id IS NOT NULL THEN target_court_name END, matches_table.court_name),
    'is_relocated', COALESCE(plan_table.is_selected, false),
    'is_displaced', COALESCE(plan_table.is_selected, false) = false AND plan_table.match_id IS NOT NULL
  ) ORDER BY COALESCE(plan_table.new_start_time, matches_table.start_time), matches_table.id), '[]'::JSONB)
  INTO timeline
  FROM public.matches AS matches_table
  LEFT JOIN manual_match_relocation_slot_plan AS plan_table ON plan_table.match_id = matches_table.id
  WHERE matches_table.championship_id = selected_match_record.championship_id
    AND matches_table.season_year = selected_match_record.season_year
    AND matches_table.scheduled_date = target_date
    AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(target_location)
    AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(target_court_name);

  IF NOT EXISTS (SELECT 1 FROM public.matches WHERE id = selected_match_id AND scheduled_date = target_date AND public.normalize_bracket_entity_name(location) = public.normalize_bracket_entity_name(target_location) AND public.normalize_bracket_entity_name(court_name) = public.normalize_bracket_entity_name(target_court_name)) THEN
    timeline := timeline || jsonb_build_array(jsonb_build_object('match_id', selected_match_id, 'status', 'SCHEDULED', 'start_time', (SELECT new_start_time FROM manual_match_relocation_slot_plan WHERE is_selected), 'end_time', (SELECT new_end_time FROM manual_match_relocation_slot_plan WHERE is_selected), 'location', target_location, 'court_name', target_court_name, 'is_relocated', true, 'is_displaced', false));
  END IF;

  RETURN jsonb_build_object(
    'revision', revision_value,
    'blockers', blockers,
    'changes', changes,
    'timeline', timeline,
    'slots', slots,
    'previous_day_start', to_char(public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
    'next_day_start', to_char(public.combine_bracket_schedule_timestamp(target_date, target_day_record.start_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
    'advances_day_start', false,
    'previous_day_end', previous_day_end,
    'next_day_end', next_day_end,
    'extends_day_end', next_day_end > previous_day_end,
    'target_date', target_date,
    'target_location', target_location,
    'target_court_name', target_court_name,
    'insertion_position', 'SLOT',
    'reason', relocation_reason,
    'notes', relocation_notes,
    'representation_warning', 'A representação dos jogos encaixados e reposicionados deve ser conferida na timeline antes da confirmação.'
  );
END;
$function$;

-- Original: hold_matches_for_manual_relocation(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.hold_matches_for_manual_relocation(_bracket_edition_id uuid, _payload jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  selected_match_ids UUID[];
  selected_matches_count INTEGER;
  current_revision BIGINT;
  hold_reason TEXT;
  hold_notes TEXT;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para guardar jogos para realocação.';
  END IF;

  SELECT array_agg(value::UUID)
  INTO selected_match_ids
  FROM jsonb_array_elements_text(COALESCE(_payload->'match_ids', '[]'::JSONB)) AS value;

  hold_reason := upper(trim(COALESCE(_payload->>'reason', '')));
  hold_notes := NULLIF(trim(COALESCE(_payload->>'notes', '')), '');

  IF COALESCE(cardinality(selected_match_ids), 0) = 0 THEN
    RAISE EXCEPTION 'Selecione ao menos um jogo agendado.';
  END IF;

  IF cardinality(selected_match_ids) <> (
    SELECT count(DISTINCT match_id)
    FROM unnest(selected_match_ids) AS match_id
  ) THEN
    RAISE EXCEPTION 'A seleção de jogos contém itens repetidos.';
  END IF;

  IF hold_reason NOT IN ('WEATHER', 'COURT_UNAVAILABLE', 'OPERATIONAL_DELAY', 'SAFETY', 'OTHER') THEN
    RAISE EXCEPTION 'Informe um motivo válido para guardar os jogos.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(format('pending-manual-match-relocation:%s', _bracket_edition_id), 0));

  SELECT reprogramming_revision
  INTO current_revision
  FROM public.championship_bracket_editions
  WHERE id = _bracket_edition_id
  FOR UPDATE;

  IF current_revision IS NULL THEN
    RAISE EXCEPTION 'Edição de chaveamento inválida.';
  END IF;

  SELECT count(*)
  INTO selected_matches_count
  FROM public.matches AS matches_table
  JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.match_id = matches_table.id
  WHERE bracket_matches_table.bracket_edition_id = _bracket_edition_id
    AND matches_table.id = ANY(selected_match_ids)
    AND matches_table.status = 'SCHEDULED'::public.match_status
    AND COALESCE(matches_table.is_pending_manual_relocation, false) = false;

  IF selected_matches_count <> cardinality(selected_match_ids) THEN
    RAISE EXCEPTION 'Somente jogos agendados desta edição podem ser guardados.';
  END IF;

  PERFORM set_config('app.allow_manual_schedule_override_update', 'true', true);
  PERFORM set_config('app.allow_pending_manual_relocation_update', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  UPDATE public.matches AS matches_table
  SET
    is_pending_manual_relocation = true,
    pending_manual_relocation_reason = hold_reason,
    pending_manual_relocation_notes = hold_notes,
    pending_manual_relocation_previous_schedule = jsonb_build_object(
      'scheduled_date', matches_table.scheduled_date,
      'location', matches_table.location,
      'court_name', matches_table.court_name,
      'start_time', matches_table.start_time,
      'end_time', matches_table.end_time,
      'queue_position', matches_table.queue_position,
      'scheduled_slot', matches_table.scheduled_slot
    ),
    pending_manual_relocation_previous_label = COALESCE(
      NULLIF(
        trim(COALESCE(_payload->'previous_labels'->>matches_table.id::TEXT, '')),
        ''
      ),
      format(
        'Jogo %s',
        COALESCE(matches_table.scheduled_slot, matches_table.queue_position)
      )
    ),
    pending_manual_relocation_created_by = auth.uid(),
    pending_manual_relocation_at = now(),
    scheduled_date = NULL,
    location = NULL,
    court_name = NULL,
    start_time = NULL,
    end_time = NULL,
    queue_position = NULL,
    scheduled_slot = NULL
  WHERE matches_table.id = ANY(selected_match_ids);

  UPDATE public.championship_bracket_editions
  SET reprogramming_revision = reprogramming_revision + 1
  WHERE id = _bracket_edition_id;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  PERFORM set_config('app.allow_pending_manual_relocation_update', 'false', true);
  PERFORM set_config('app.allow_manual_schedule_override_update', 'false', true);
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.allow_pending_manual_relocation_update', 'false', true);
    PERFORM set_config('app.allow_manual_schedule_override_update', 'false', true);
    RAISE;
END;
$function$;

-- Original: list_editable_match_schedule_slots(_match_id uuid, _target_date date, _target_location text, _target_court_name text, _sport_id uuid, _naipe match_naipe, _home_team_id uuid, _away_team_id uuid)
CREATE OR REPLACE FUNCTION public.list_editable_match_schedule_slots(_match_id uuid, _target_date date, _target_location text, _target_court_name text, _sport_id uuid DEFAULT NULL::uuid, _naipe match_naipe DEFAULT NULL::match_naipe, _home_team_id uuid DEFAULT NULL::uuid, _away_team_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(slot_number integer, start_time timestamp with time zone, start_time_label text, is_current_slot boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  source_match RECORD;
  latest_bracket_edition_id UUID;
  target_day_id UUID;
  target_court_id UUID;
  target_day_start_time TIME;
  target_day_end_time TIME;
  resolved_sport_id UUID;
  resolved_naipe public.match_naipe;
  resolved_home_team_id UUID;
  resolved_away_team_id UUID;
  duration_minutes INTEGER;
  current_start_minutes INTEGER;
  day_end_minutes INTEGER;
  slot_index INTEGER := 0;
  break_record RECORD;
  break_start_minutes INTEGER;
  break_end_minutes INTEGER;
  changed BOOLEAN;
  candidate_start_time TIMESTAMPTZ;
  candidate_time_label TEXT;
  candidate_conflict_message TEXT;
  candidate_is_current_slot BOOLEAN;
  slot_is_occupied BOOLEAN;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para editar a logística dos jogos.';
  END IF;

  IF _match_id IS NULL THEN
    RAISE EXCEPTION 'Informe o jogo para listar os horários disponíveis.';
  END IF;

  IF _target_date IS NULL THEN
    RAISE EXCEPTION 'Informe o dia desejado para listar os horários disponíveis.';
  END IF;

  IF NULLIF(trim(COALESCE(_target_location, '')), '') IS NULL
    OR NULLIF(trim(COALESCE(_target_court_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Informe local e quadra para listar os horários disponíveis.';
  END IF;

  SELECT
    matches_table.id,
    matches_table.championship_id,
    matches_table.season_year,
    matches_table.sport_id,
    matches_table.naipe,
    matches_table.home_team_id,
    matches_table.away_team_id,
    matches_table.location,
    matches_table.court_name,
    matches_table.scheduled_date,
    matches_table.start_time,
    matches_table.scheduled_slot,
    matches_table.queue_position,
    matches_table.created_at
  INTO source_match
  FROM public.matches AS matches_table
  WHERE matches_table.id = _match_id
  LIMIT 1;

  IF source_match.id IS NULL THEN
    RAISE EXCEPTION 'Não foi possível localizar o jogo selecionado.';
  END IF;

  resolved_sport_id := COALESCE(_sport_id, source_match.sport_id);
  resolved_naipe := COALESCE(_naipe, source_match.naipe);
  resolved_home_team_id := COALESCE(_home_team_id, source_match.home_team_id);
  resolved_away_team_id := COALESCE(_away_team_id, source_match.away_team_id);

  IF resolved_sport_id IS NULL OR resolved_naipe IS NULL OR resolved_home_team_id IS NULL OR resolved_away_team_id IS NULL THEN
    RAISE EXCEPTION 'O jogo precisa ter modalidade, naipe e duas atléticas válidas para listar horários.';
  END IF;

  SELECT editions_table.id
  INTO latest_bracket_edition_id
  FROM public.championship_bracket_editions AS editions_table
  WHERE editions_table.championship_id = source_match.championship_id
    AND editions_table.season_year = source_match.season_year
  ORDER BY editions_table.updated_at DESC NULLS LAST, editions_table.created_at DESC
  LIMIT 1;

  IF latest_bracket_edition_id IS NULL THEN
    RAISE EXCEPTION 'Não há agenda de chaveamento configurada para esta edição.';
  END IF;

  SELECT
    days_table.id,
    days_table.start_time,
    days_table.end_time,
    courts_table.id
  INTO
    target_day_id,
    target_day_start_time,
    target_day_end_time,
    target_court_id
  FROM public.championship_bracket_days AS days_table
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.bracket_day_id = days_table.id
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
  JOIN public.championship_bracket_court_sports AS court_sports_table
    ON court_sports_table.bracket_court_id = courts_table.id
  WHERE days_table.bracket_edition_id = latest_bracket_edition_id
    AND days_table.event_date = _target_date
    AND court_sports_table.sport_id = resolved_sport_id
    AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(_target_location)
    AND public.normalize_bracket_entity_name(courts_table.name) = public.normalize_bracket_entity_name(_target_court_name)
  ORDER BY locations_table.position ASC, courts_table.position ASC
  LIMIT 1;

  IF target_day_id IS NULL OR target_court_id IS NULL THEN
    RAISE EXCEPTION 'A quadra selecionada não está disponível para esta modalidade no dia informado.';
  END IF;

  IF target_day_start_time IS NULL OR target_day_end_time IS NULL OR target_day_end_time <= target_day_start_time THEN
    RAISE EXCEPTION 'A grade de horários deste dia está inválida.';
  END IF;

  duration_minutes := GREATEST(
    COALESCE(public.resolve_championship_sport_duration_minutes(source_match.championship_id, resolved_sport_id), 35),
    1
  );

  current_start_minutes := FLOOR(EXTRACT(EPOCH FROM target_day_start_time) / 60.0)::INTEGER;
  day_end_minutes := FLOOR(EXTRACT(EPOCH FROM target_day_end_time) / 60.0)::INTEGER;

  LOOP
    changed := true;

    WHILE changed LOOP
      changed := false;

      FOR break_record IN
        SELECT
          breaks_table.break_start_time,
          breaks_table.break_end_time
        FROM public.championship_bracket_day_breaks AS breaks_table
        WHERE breaks_table.bracket_day_id = target_day_id
          AND (
            breaks_table.scope_type = 'ALL_COURTS'
            OR (breaks_table.scope_type = 'COURT' AND breaks_table.bracket_court_id = target_court_id)
          )
        ORDER BY breaks_table.position ASC, breaks_table.break_start_time ASC
      LOOP
        break_start_minutes := FLOOR(EXTRACT(EPOCH FROM break_record.break_start_time) / 60.0)::INTEGER;
        break_end_minutes := FLOOR(EXTRACT(EPOCH FROM break_record.break_end_time) / 60.0)::INTEGER;

        IF current_start_minutes < break_end_minutes
          AND current_start_minutes + duration_minutes > break_start_minutes THEN
          current_start_minutes := break_end_minutes;
          changed := true;
        END IF;
      END LOOP;
    END LOOP;

    EXIT WHEN current_start_minutes + duration_minutes > day_end_minutes;

    slot_index := slot_index + 1;
    candidate_start_time := make_timestamptz(
      EXTRACT(YEAR FROM _target_date)::INTEGER,
      EXTRACT(MONTH FROM _target_date)::INTEGER,
      EXTRACT(DAY FROM _target_date)::INTEGER,
      FLOOR(current_start_minutes / 60.0)::INTEGER,
      MOD(current_start_minutes, 60),
      0,
      'America/Sao_Paulo'
    );
    candidate_time_label := to_char(timezone('America/Sao_Paulo', candidate_start_time), 'HH24:MI');

    candidate_is_current_slot :=
      source_match.scheduled_date IS NOT DISTINCT FROM _target_date
      AND public.normalize_bracket_entity_name(source_match.location) = public.normalize_bracket_entity_name(_target_location)
      AND public.normalize_bracket_entity_name(source_match.court_name) = public.normalize_bracket_entity_name(_target_court_name)
      AND source_match.start_time IS NOT DISTINCT FROM candidate_start_time
      AND COALESCE(source_match.scheduled_slot, slot_index) = slot_index;

    SELECT EXISTS (
      SELECT 1
      FROM public.matches AS matches_table
      WHERE matches_table.championship_id = source_match.championship_id
        AND matches_table.season_year = source_match.season_year
        AND matches_table.status = 'SCHEDULED'::public.match_status
        AND matches_table.scheduled_date = _target_date
        AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(_target_location)
        AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(_target_court_name)
        AND matches_table.id <> source_match.id
        AND (
          matches_table.start_time IS NOT DISTINCT FROM candidate_start_time
          OR COALESCE(matches_table.scheduled_slot, matches_table.queue_position) = slot_index
        )
    )
    INTO slot_is_occupied;

    candidate_conflict_message := public.resolve_scheduled_match_rest_gap_conflict(
      source_match.championship_id,
      source_match.season_year,
      _target_date,
      _target_location,
      _target_court_name,
      candidate_start_time,
      slot_index,
      NULL,
      source_match.created_at,
      source_match.id,
      resolved_sport_id,
      resolved_naipe,
      resolved_home_team_id,
      resolved_away_team_id,
      duration_minutes
    );

    IF (NOT slot_is_occupied OR candidate_is_current_slot) AND candidate_conflict_message IS NULL THEN
      slot_number := slot_index;
      start_time := candidate_start_time;
      start_time_label := candidate_time_label;
      is_current_slot := candidate_is_current_slot;
      RETURN NEXT;
    END IF;

    current_start_minutes := current_start_minutes + duration_minutes;
  END LOOP;

  RETURN;
END;
$function$;

-- Original: preview_manual_match_relocation(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.preview_manual_match_relocation(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para realocar jogos.';
  END IF;

  RETURN public.build_manual_match_relocation_preview(_bracket_edition_id, _payload);
END;
$function$;

-- Original: preview_manual_match_relocation_slot(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.preview_manual_match_relocation_slot(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para realocar jogos.';
  END IF;

  RETURN public.build_manual_match_relocation_slot_preview(_bracket_edition_id, _payload);
END;
$function$;

-- Original: update_scheduled_match_logistics(_match_id uuid, _scheduled_date date, _location text, _court_name text, _slot_start_time timestamp with time zone, _representation_mode text, _sport_id uuid, _naipe match_naipe, _home_team_id uuid, _away_team_id uuid)
CREATE OR REPLACE FUNCTION public.update_scheduled_match_logistics(_match_id uuid, _scheduled_date date, _location text, _court_name text, _slot_start_time timestamp with time zone, _representation_mode text DEFAULT 'AUTO'::text, _sport_id uuid DEFAULT NULL::uuid, _naipe match_naipe DEFAULT NULL::match_naipe, _home_team_id uuid DEFAULT NULL::uuid, _away_team_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  source_match RECORD;
  target_slot RECORD;
  normalized_representation_mode TEXT := upper(trim(COALESCE(_representation_mode, 'AUTO')));
  should_preserve_current_queue_position BOOLEAN := false;
  next_queue_position INTEGER;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para editar a logística dos jogos.';
  END IF;

  IF _match_id IS NULL THEN
    RAISE EXCEPTION 'Informe o jogo para atualizar a logística.';
  END IF;

  IF _scheduled_date IS NULL
    OR NULLIF(trim(COALESCE(_location, '')), '') IS NULL
    OR NULLIF(trim(COALESCE(_court_name, '')), '') IS NULL
    OR _slot_start_time IS NULL THEN
    RAISE EXCEPTION 'Informe dia, local, quadra e horário para atualizar a logística.';
  END IF;

  IF normalized_representation_mode NOT IN ('AUTO', 'CO') THEN
    RAISE EXCEPTION 'Modo de representação inválido.';
  END IF;

  SELECT
    matches_table.id,
    matches_table.championship_id,
    matches_table.season_year,
    matches_table.location,
    matches_table.court_name,
    matches_table.scheduled_date,
    matches_table.start_time,
    matches_table.queue_position,
    matches_table.scheduled_slot
  INTO source_match
  FROM public.matches AS matches_table
  WHERE matches_table.id = _match_id
  LIMIT 1
  FOR UPDATE;

  IF source_match.id IS NULL THEN
    RAISE EXCEPTION 'Não foi possível localizar o jogo para atualizar a logística.';
  END IF;

  SELECT slot_rows.slot_number, slot_rows.start_time
  INTO target_slot
  FROM public.list_editable_match_schedule_slots(
    _match_id,
    _scheduled_date,
    _location,
    _court_name,
    _sport_id,
    _naipe,
    _home_team_id,
    _away_team_id
  ) AS slot_rows
  WHERE slot_rows.start_time = _slot_start_time
  LIMIT 1;

  IF target_slot.slot_number IS NULL THEN
    RAISE EXCEPTION 'O horário selecionado não está mais disponível para esta quadra.';
  END IF;

  should_preserve_current_queue_position :=
    source_match.scheduled_date IS NOT DISTINCT FROM _scheduled_date
    AND public.normalize_bracket_entity_name(source_match.location) = public.normalize_bracket_entity_name(_location)
    AND public.normalize_bracket_entity_name(source_match.court_name) = public.normalize_bracket_entity_name(_court_name)
    AND source_match.start_time IS NOT DISTINCT FROM target_slot.start_time
    AND source_match.scheduled_slot IS NOT DISTINCT FROM target_slot.slot_number;

  IF should_preserve_current_queue_position THEN
    next_queue_position := source_match.queue_position;
  ELSE
    next_queue_position := NULL;
  END IF;

  BEGIN
    PERFORM set_config('app.skip_queue_trigger', 'true', true);

    UPDATE public.matches
    SET
      scheduled_date = _scheduled_date,
      location = trim(_location),
      court_name = trim(_court_name),
      start_time = target_slot.start_time,
      end_time = NULL,
      scheduled_slot = target_slot.slot_number,
      queue_position = next_queue_position,
      manual_representation_mode = normalized_representation_mode
    WHERE id = _match_id;

    PERFORM set_config('app.skip_queue_trigger', 'false', true);
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM set_config('app.skip_queue_trigger', 'false', true);
      RAISE;
  END;
END;
$function$;
