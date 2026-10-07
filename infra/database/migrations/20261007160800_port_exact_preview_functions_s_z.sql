-- LAJE-126: snapshot de funções exatas v8 S-Z.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.schedule_v8_knockout_batch(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  knockout_record RECORD;
  block_value JSONB;
  court_window RECORD;
  candidate_start_at TIMESTAMPTZ;
  candidate_end_at TIMESTAMPTZ;
  candidate_conflict_end_at TIMESTAMPTZ;
  dependency_ready_at TIMESTAMPTZ;
  group_ready_at TIMESTAMPTZ;
  sequence_position INTEGER;
  duration_value INTEGER;
BEGIN
  UPDATE championship_bracket_preview_private.knockout_matches knockout_matches
  SET start_at = group_ready.ready_at, end_at = group_ready.ready_at
  FROM (
    SELECT matches_table.competition_id, max(slots_table.end_at) AS ready_at
    FROM championship_bracket_preview_private.assignments assignments_table
    JOIN championship_bracket_preview_private.matches matches_table ON matches_table.id = assignments_table.match_id
    JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id = assignments_table.slot_id
    WHERE assignments_table.job_id = _job_id
    GROUP BY matches_table.competition_id
  ) group_ready
  WHERE knockout_matches.job_id = _job_id
    AND knockout_matches.is_bye
    AND knockout_matches.competition_id = group_ready.competition_id;

  SELECT knockout_matches.*, competitions.sport_id, competitions.naipe, competitions.division, competitions.competition_key, jobs_table.payload
  INTO knockout_record
  FROM championship_bracket_preview_private.knockout_matches knockout_matches
  JOIN championship_bracket_preview_private.competitions competitions ON competitions.id = knockout_matches.competition_id
  JOIN championship_bracket_preview_private.jobs jobs_table ON jobs_table.id = knockout_matches.job_id
  WHERE knockout_matches.job_id = _job_id
    AND NOT knockout_matches.is_bye
    AND knockout_matches.scheduled_date IS NULL
    AND (
      knockout_matches.round_number = 1
      OR (
        SELECT count(*)
        FROM championship_bracket_preview_private.knockout_matches predecessors
        WHERE predecessors.id = ANY(knockout_matches.predecessor_match_ids)
          AND predecessors.end_at IS NOT NULL
      ) = cardinality(knockout_matches.predecessor_match_ids)
    )
  ORDER BY knockout_matches.round_number,
    CASE WHEN knockout_matches.phase = 'THIRD_PLACE' THEN 1 ELSE 0 END,
    knockout_matches.slot_number, knockout_matches.logical_key
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    IF EXISTS (
      SELECT 1 FROM championship_bracket_preview_private.knockout_matches knockout_matches
      WHERE knockout_matches.job_id = _job_id
        AND NOT knockout_matches.is_bye
        AND knockout_matches.scheduled_date IS NULL
    ) THEN
      RETURN jsonb_build_object(
        'continue', false,
        'diagnostics', jsonb_build_array(jsonb_build_object(
          'code', 'KNOCKOUT_DEPENDENCY_NOT_SCHEDULED',
          'message', 'Existem partidas eliminatórias sem uma dependência programada.'
        ))
      );
    END IF;
    RETURN jsonb_build_object('continue', false, 'done', true, 'diagnostics', '[]'::jsonb);
  END IF;

  IF knockout_record.round_number = 1 THEN
    SELECT max(slots_table.end_at) INTO group_ready_at
    FROM championship_bracket_preview_private.assignments assignments_table
    JOIN championship_bracket_preview_private.matches group_matches ON group_matches.id = assignments_table.match_id
    JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id = assignments_table.slot_id
    WHERE assignments_table.job_id = _job_id AND group_matches.competition_id = knockout_record.competition_id;
    dependency_ready_at := group_ready_at;
  ELSE
    SELECT max(predecessors.end_at) INTO dependency_ready_at
    FROM championship_bracket_preview_private.knockout_matches predecessors
    WHERE predecessors.id = ANY(knockout_record.predecessor_match_ids);
  END IF;

  IF dependency_ready_at IS NULL THEN
    RETURN jsonb_build_object(
      'continue', false,
      'diagnostics', jsonb_build_array(jsonb_build_object(
        'code', 'KNOCKOUT_DEPENDENCY_NOT_SCHEDULED',
        'message', format('As dependências de %s não possuem término programado.', knockout_record.logical_key),
        'logical_key', knockout_record.logical_key
      ))
    );
  END IF;

  block_value := NULL;
  IF knockout_record.phase = 'FINAL' THEN
    SELECT block_item.value INTO block_value
    FROM jsonb_array_elements(COALESCE(knockout_record.payload -> 'knockout_program_blocks', '[]'::jsonb)) WITH ORDINALITY block_item(value, ordinality)
    WHERE block_item.value ->> 'phase' = 'FINAL'
      AND block_item.value ->> 'sport_id' = knockout_record.sport_id::text
      AND (
        COALESCE(NULLIF(block_item.value ->> 'division_scope', ''), 'ALL') = 'ALL'
        OR COALESCE(NULLIF(block_item.value ->> 'division_scope', ''), 'ALL') = knockout_record.division::text
      )
      AND EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(COALESCE(block_item.value -> 'naipe_sequence', '[]'::jsonb)) seq(value)
        WHERE seq.value = knockout_record.naipe::text
      )
    ORDER BY COALESCE(NULLIF(block_item.value ->> 'display_order', '')::integer, block_item.ordinality::integer)
    LIMIT 1;
  END IF;

  IF block_value IS NOT NULL THEN
    SELECT seq.ordinality::integer INTO sequence_position
    FROM jsonb_array_elements_text(COALESCE(block_value -> 'naipe_sequence', '[]'::jsonb)) WITH ORDINALITY seq(value, ordinality)
    WHERE seq.value = knockout_record.naipe::text;
    duration_value := COALESCE(NULLIF(block_value ->> 'match_duration_minutes_override', '')::integer, knockout_record.duration_minutes);
    candidate_start_at := public.combine_bracket_schedule_timestamp((block_value ->> 'date')::date, (block_value ->> 'start_time')::time)
      + make_interval(mins => (sequence_position - 1) * duration_value);
    candidate_end_at := candidate_start_at + make_interval(mins => duration_value);
    IF sequence_position IS NULL OR duration_value < 1
      OR candidate_end_at > public.combine_bracket_schedule_timestamp((block_value ->> 'date')::date, (block_value ->> 'end_time')::time)
    THEN
      RETURN jsonb_build_object('continue', false, 'diagnostics', jsonb_build_array(jsonb_build_object(
        'code', 'MANUAL_FINAL_CAPACITY_EXCEEDED',
        'message', format('O bloco manual não comporta a final %s.', knockout_record.logical_key),
        'logical_key', knockout_record.logical_key
      )));
    END IF;
    IF candidate_start_at < dependency_ready_at THEN
      RETURN jsonb_build_object('continue', false, 'diagnostics', jsonb_build_array(jsonb_build_object(
        'code', 'MANUAL_FINAL_DEPENDENCY_CONFLICT',
        'message', format('A final manual %s inicia antes das semifinal(is).', knockout_record.logical_key),
        'logical_key', knockout_record.logical_key
      )));
    END IF;
    IF EXISTS (
      SELECT 1 FROM championship_bracket_preview_private.knockout_matches occupied
      WHERE occupied.job_id = _job_id AND occupied.id <> knockout_record.id
        AND occupied.location_key = (block_value ->> 'location_key')::uuid
        AND occupied.court_key = (block_value ->> 'court_key')::uuid
        AND occupied.start_at < candidate_end_at AND occupied.end_at > candidate_start_at
    ) THEN
      RETURN jsonb_build_object('continue', false, 'diagnostics', jsonb_build_array(jsonb_build_object(
        'code', 'MANUAL_FINAL_OVERLAP',
        'message', format('O bloco manual conflita com outra partida em %s.', knockout_record.logical_key),
        'logical_key', knockout_record.logical_key
      )));
    END IF;
    UPDATE championship_bracket_preview_private.knockout_matches SET
      scheduled_date = (block_value ->> 'date')::date,
      location_key = (block_value ->> 'location_key')::uuid,
      location_name = block_value ->> 'location_name',
      court_key = (block_value ->> 'court_key')::uuid,
      court_name = block_value ->> 'court_name',
      start_at = candidate_start_at, end_at = candidate_end_at,
      duration_minutes = duration_value, manual_final = true
    WHERE id = knockout_record.id;
    RETURN jsonb_build_object('continue', true, 'done', false, 'diagnostics', '[]'::jsonb);
  END IF;

  candidate_start_at := NULL;
  candidate_end_at := NULL;
  FOR court_window IN
    SELECT court_windows.*, availability_windows.window_start_at, availability_windows.window_end_at
    FROM championship_bracket_preview_private.resolve_v8_knockout_court_windows(_job_id, knockout_record.sport_id) court_windows
    CROSS JOIN LATERAL public.resolve_championship_bracket_competition_schedule_windows(
      knockout_record.payload, knockout_record.competition_key, court_windows.event_date
    ) availability_windows
    ORDER BY court_windows.event_date, court_windows.location_position, court_windows.court_position, availability_windows.window_start_at
  LOOP
    candidate_conflict_end_at := GREATEST(court_window.free_start_at, court_window.window_start_at, dependency_ready_at);
    LOOP
      EXIT WHEN candidate_conflict_end_at + make_interval(mins => knockout_record.duration_minutes)
        > LEAST(court_window.free_end_at, court_window.window_end_at);
      SELECT max(conflicts.end_at) INTO candidate_end_at
      FROM (
        SELECT slots_table.end_at
        FROM championship_bracket_preview_private.assignments assignments_table
        JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id = assignments_table.slot_id
        WHERE assignments_table.job_id = _job_id
          AND slots_table.event_date = court_window.event_date
          AND slots_table.location_key = court_window.location_key
          AND slots_table.court_key = court_window.court_key
          AND slots_table.start_at < candidate_conflict_end_at + make_interval(mins => knockout_record.duration_minutes)
          AND slots_table.end_at > candidate_conflict_end_at
        UNION ALL
        SELECT scheduled.end_at
        FROM championship_bracket_preview_private.knockout_matches scheduled
        WHERE scheduled.job_id = _job_id AND scheduled.id <> knockout_record.id
          AND scheduled.location_key = court_window.location_key AND scheduled.court_key = court_window.court_key
          AND scheduled.start_at < candidate_conflict_end_at + make_interval(mins => knockout_record.duration_minutes)
          AND scheduled.end_at > candidate_conflict_end_at
      ) conflicts;
      IF candidate_end_at IS NULL THEN
        candidate_start_at := candidate_conflict_end_at;
        candidate_end_at := candidate_start_at + make_interval(mins => knockout_record.duration_minutes);
        EXIT;
      END IF;
      candidate_conflict_end_at := candidate_end_at;
    END LOOP;
    EXIT WHEN candidate_start_at IS NOT NULL;
  END LOOP;

  IF candidate_start_at IS NULL THEN
    RETURN jsonb_build_object('continue', false, 'diagnostics', jsonb_build_array(jsonb_build_object(
      'code', 'KNOCKOUT_NO_AVAILABLE_SLOT',
      'message', format('Não existe janela compatível após as dependências para %s.', knockout_record.logical_key),
      'logical_key', knockout_record.logical_key
    )));
  END IF;

  UPDATE championship_bracket_preview_private.knockout_matches SET
    scheduled_date = court_window.event_date, location_key = court_window.location_key,
    location_name = court_window.location_name, court_key = court_window.court_key,
    court_name = court_window.court_name, start_at = candidate_start_at, end_at = candidate_end_at
  WHERE id = knockout_record.id;
  RETURN jsonb_build_object('continue', true, 'done', false, 'diagnostics', '[]'::jsonb);
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.schedule_v8_knockout_matches(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  knockout_record RECORD;
  block_value JSONB;
  court_window RECORD;
  candidate_start_at TIMESTAMPTZ;
  candidate_end_at TIMESTAMPTZ;
  candidate_conflict_end_at TIMESTAMPTZ;
  dependency_ready_at TIMESTAMPTZ;
  group_ready_at TIMESTAMPTZ;
  sequence_position INTEGER;
  duration_value INTEGER;
  scheduled_count INTEGER;
  expected_count INTEGER;
  diagnostics JSONB := '[]'::jsonb;
BEGIN
  UPDATE championship_bracket_preview_private.knockout_matches knockout_matches
  SET start_at = group_ready.ready_at, end_at = group_ready.ready_at
  FROM (
    SELECT matches_table.competition_id, max(slots_table.end_at) AS ready_at
    FROM championship_bracket_preview_private.assignments assignments_table
    JOIN championship_bracket_preview_private.matches matches_table ON matches_table.id = assignments_table.match_id
    JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id = assignments_table.slot_id
    WHERE assignments_table.job_id = _job_id
    GROUP BY matches_table.competition_id
  ) group_ready
  WHERE knockout_matches.job_id = _job_id
    AND knockout_matches.is_bye
    AND knockout_matches.competition_id = group_ready.competition_id;

  FOR knockout_record IN
    SELECT knockout_matches.*, competitions.sport_id, competitions.naipe, competitions.division, competitions.competition_key, jobs_table.payload
    FROM championship_bracket_preview_private.knockout_matches knockout_matches
    JOIN championship_bracket_preview_private.competitions competitions ON competitions.id = knockout_matches.competition_id
    JOIN championship_bracket_preview_private.jobs jobs_table ON jobs_table.id = knockout_matches.job_id
    WHERE knockout_matches.job_id = _job_id AND NOT knockout_matches.is_bye
    ORDER BY knockout_matches.round_number,
      CASE WHEN knockout_matches.phase = 'THIRD_PLACE' THEN 1 ELSE 0 END,
      knockout_matches.slot_number, knockout_matches.logical_key
  LOOP
    IF knockout_record.round_number = 1 THEN
      SELECT max(slots_table.end_at) INTO group_ready_at
      FROM championship_bracket_preview_private.assignments assignments_table
      JOIN championship_bracket_preview_private.matches group_matches ON group_matches.id = assignments_table.match_id
      JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id = assignments_table.slot_id
      WHERE assignments_table.job_id = _job_id AND group_matches.competition_id = knockout_record.competition_id;
      dependency_ready_at := group_ready_at;
    ELSE
      SELECT max(predecessors.end_at) INTO dependency_ready_at
      FROM championship_bracket_preview_private.knockout_matches predecessors
      WHERE predecessors.id = ANY(knockout_record.predecessor_match_ids);
      IF (SELECT count(*) FROM championship_bracket_preview_private.knockout_matches predecessors WHERE predecessors.id = ANY(knockout_record.predecessor_match_ids) AND predecessors.end_at IS NOT NULL) <> cardinality(knockout_record.predecessor_match_ids) THEN
        dependency_ready_at := NULL;
      END IF;
    END IF;

    IF dependency_ready_at IS NULL THEN
      diagnostics := diagnostics || jsonb_build_array(jsonb_build_object(
        'code', 'KNOCKOUT_DEPENDENCY_NOT_SCHEDULED',
        'message', format('As dependências de %s não possuem término programado.', knockout_record.logical_key),
        'logical_key', knockout_record.logical_key
      ));
      CONTINUE;
    END IF;

    block_value := NULL;
    IF knockout_record.phase = 'FINAL' THEN
      SELECT block_item.value INTO block_value
      FROM jsonb_array_elements(COALESCE(knockout_record.payload -> 'knockout_program_blocks', '[]'::jsonb)) WITH ORDINALITY block_item(value, ordinality)
      WHERE block_item.value ->> 'phase' = 'FINAL'
        AND block_item.value ->> 'sport_id' = knockout_record.sport_id::text
        AND (
          COALESCE(NULLIF(block_item.value ->> 'division_scope', ''), 'ALL') = 'ALL'
          OR COALESCE(NULLIF(block_item.value ->> 'division_scope', ''), 'ALL') = knockout_record.division::text
        )
        AND EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(COALESCE(block_item.value -> 'naipe_sequence', '[]'::jsonb)) seq(value)
          WHERE seq.value = knockout_record.naipe::text
        )
      ORDER BY COALESCE(NULLIF(block_item.value ->> 'display_order', '')::integer, block_item.ordinality::integer)
      LIMIT 1;
    END IF;

    IF block_value IS NOT NULL THEN
      SELECT seq.ordinality::integer INTO sequence_position
      FROM jsonb_array_elements_text(COALESCE(block_value -> 'naipe_sequence', '[]'::jsonb)) WITH ORDINALITY seq(value, ordinality)
      WHERE seq.value = knockout_record.naipe::text;
      duration_value := COALESCE(NULLIF(block_value ->> 'match_duration_minutes_override', '')::integer, knockout_record.duration_minutes);
      candidate_start_at := public.combine_bracket_schedule_timestamp((block_value ->> 'date')::date, (block_value ->> 'start_time')::time)
        + make_interval(mins => (sequence_position - 1) * duration_value);
      candidate_end_at := candidate_start_at + make_interval(mins => duration_value);
      IF sequence_position IS NULL
        OR duration_value < 1
        OR candidate_end_at > public.combine_bracket_schedule_timestamp((block_value ->> 'date')::date, (block_value ->> 'end_time')::time)
      THEN
        diagnostics := diagnostics || jsonb_build_array(jsonb_build_object('code', 'MANUAL_FINAL_CAPACITY_EXCEEDED', 'message', format('O bloco manual não comporta a final %s.', knockout_record.logical_key), 'logical_key', knockout_record.logical_key));
        CONTINUE;
      END IF;
      IF candidate_start_at < dependency_ready_at THEN
        diagnostics := diagnostics || jsonb_build_array(jsonb_build_object('code', 'MANUAL_FINAL_DEPENDENCY_CONFLICT', 'message', format('A final manual %s inicia antes das semifinal(is).', knockout_record.logical_key), 'logical_key', knockout_record.logical_key));
        CONTINUE;
      END IF;
      IF EXISTS (
        SELECT 1 FROM championship_bracket_preview_private.knockout_matches occupied
        WHERE occupied.job_id = _job_id AND occupied.id <> knockout_record.id
          AND occupied.location_key = (block_value ->> 'location_key')::uuid
          AND occupied.court_key = (block_value ->> 'court_key')::uuid
          AND occupied.start_at < candidate_end_at AND occupied.end_at > candidate_start_at
      ) THEN
        diagnostics := diagnostics || jsonb_build_array(jsonb_build_object('code', 'MANUAL_FINAL_OVERLAP', 'message', format('O bloco manual conflita com outra partida em %s.', knockout_record.logical_key), 'logical_key', knockout_record.logical_key));
        CONTINUE;
      END IF;
      UPDATE championship_bracket_preview_private.knockout_matches SET
        scheduled_date = (block_value ->> 'date')::date,
        location_key = (block_value ->> 'location_key')::uuid,
        location_name = block_value ->> 'location_name',
        court_key = (block_value ->> 'court_key')::uuid,
        court_name = block_value ->> 'court_name',
        start_at = candidate_start_at, end_at = candidate_end_at,
        duration_minutes = duration_value, manual_final = true
      WHERE id = knockout_record.id;
      CONTINUE;
    END IF;

    candidate_start_at := NULL;
    candidate_end_at := NULL;
    FOR court_window IN
      SELECT court_windows.*, availability_windows.window_start_at, availability_windows.window_end_at
      FROM championship_bracket_preview_private.resolve_v8_knockout_court_windows(_job_id, knockout_record.sport_id) court_windows
      CROSS JOIN LATERAL public.resolve_championship_bracket_competition_schedule_windows(
        knockout_record.payload, knockout_record.competition_key, court_windows.event_date
      ) availability_windows
      ORDER BY court_windows.event_date, court_windows.location_position, court_windows.court_position, availability_windows.window_start_at
    LOOP
      candidate_conflict_end_at := GREATEST(court_window.free_start_at, court_window.window_start_at, dependency_ready_at);
      LOOP
        EXIT WHEN candidate_conflict_end_at + make_interval(mins => knockout_record.duration_minutes)
          > LEAST(court_window.free_end_at, court_window.window_end_at);
        SELECT max(conflicts.end_at) INTO candidate_end_at
        FROM (
          SELECT slots_table.end_at
          FROM championship_bracket_preview_private.assignments assignments_table
          JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id = assignments_table.slot_id
          WHERE assignments_table.job_id = _job_id
            AND slots_table.event_date = court_window.event_date
            AND slots_table.location_key = court_window.location_key
            AND slots_table.court_key = court_window.court_key
            AND slots_table.start_at < candidate_conflict_end_at + make_interval(mins => knockout_record.duration_minutes)
            AND slots_table.end_at > candidate_conflict_end_at
          UNION ALL
          SELECT scheduled.end_at
          FROM championship_bracket_preview_private.knockout_matches scheduled
          WHERE scheduled.job_id = _job_id AND scheduled.id <> knockout_record.id
            AND scheduled.location_key = court_window.location_key AND scheduled.court_key = court_window.court_key
            AND scheduled.start_at < candidate_conflict_end_at + make_interval(mins => knockout_record.duration_minutes)
            AND scheduled.end_at > candidate_conflict_end_at
        ) conflicts;
        IF candidate_end_at IS NULL THEN
          candidate_start_at := candidate_conflict_end_at;
          candidate_end_at := candidate_start_at + make_interval(mins => knockout_record.duration_minutes);
          EXIT;
        END IF;
        candidate_conflict_end_at := candidate_end_at;
      END LOOP;
      EXIT WHEN candidate_start_at IS NOT NULL;
    END LOOP;

    IF candidate_start_at IS NULL THEN
      diagnostics := diagnostics || jsonb_build_array(jsonb_build_object('code', 'KNOCKOUT_NO_AVAILABLE_SLOT', 'message', format('Não existe janela compatível após as dependências para %s.', knockout_record.logical_key), 'logical_key', knockout_record.logical_key));
    ELSE
      UPDATE championship_bracket_preview_private.knockout_matches SET
        scheduled_date = court_window.event_date, location_key = court_window.location_key,
        location_name = court_window.location_name, court_key = court_window.court_key,
        court_name = court_window.court_name, start_at = candidate_start_at, end_at = candidate_end_at
      WHERE id = knockout_record.id;
    END IF;
  END LOOP;

  SELECT count(*) INTO expected_count FROM championship_bracket_preview_private.knockout_matches WHERE job_id = _job_id AND NOT is_bye;
  SELECT count(*) INTO scheduled_count FROM championship_bracket_preview_private.knockout_matches WHERE job_id = _job_id AND NOT is_bye AND scheduled_date IS NOT NULL AND location_key IS NOT NULL AND court_key IS NOT NULL AND start_at IS NOT NULL AND end_at IS NOT NULL;
  IF scheduled_count <> expected_count THEN
    diagnostics := diagnostics || jsonb_build_array(jsonb_build_object('code', 'KNOCKOUT_INCOMPLETE_SCHEDULE', 'message', format('A agenda do mata-mata programou %s de %s confrontos.', scheduled_count, expected_count), 'target', expected_count, 'obtained', scheduled_count));
  END IF;
  diagnostics := diagnostics || COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'code', 'KNOCKOUT_TEMPORAL_DEPENDENCY_CONFLICT',
      'message', format('%s inicia antes do término de uma partida predecessora.', dependent.logical_key),
      'logical_key', dependent.logical_key
    ) ORDER BY dependent.logical_key)
    FROM championship_bracket_preview_private.knockout_matches dependent
    JOIN LATERAL (
      SELECT max(predecessors.end_at) AS ready_at
      FROM championship_bracket_preview_private.knockout_matches predecessors
      WHERE predecessors.id = ANY(dependent.predecessor_match_ids)
    ) predecessor_window ON true
    WHERE dependent.job_id = _job_id AND NOT dependent.is_bye
      AND cardinality(dependent.predecessor_match_ids) > 0
      AND (dependent.start_at IS NULL OR predecessor_window.ready_at IS NULL OR dependent.start_at < predecessor_window.ready_at)
  ), '[]'::jsonb);
  RETURN diagnostics;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.set_failed_preview_job_completed_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
BEGIN
  IF NEW.status = 'FAILED'
    AND NEW.completed_at IS NULL
  THEN
    NEW.completed_at := now();
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.sync_failed_v8_processed_slots()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
BEGIN
  IF NEW.algorithm_version =
      'async-exact-v8'
    AND NEW.status = 'FAILED'
    AND OLD.status IS DISTINCT FROM
      NEW.status
  THEN
    SELECT count(*)::integer
    INTO NEW.processed_slots
    FROM championship_bracket_preview_private.assignments
      AS assignments_table
    WHERE assignments_table.job_id =
      NEW.id;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.try_manifest_daily_interday_repair(_job_id uuid, _closed_date date, _final_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  inbound_record RECORD;
  outbound_record RECORD;
  final_slot_record RECORD;
  attempted_count INTEGER;
  outbound_gap INTEGER;
  repaired BOOLEAN := false;
  repair_result JSONB;
BEGIN
  SELECT count(*)::integer
  INTO attempted_count
  FROM championship_bracket_preview_private.manifest_daily_interday_repairs
  WHERE job_id = _job_id
    AND final_date = _final_date;

  IF attempted_count >= 60 THEN
    RETURN jsonb_build_object(
      'repaired',
      false,
      'status',
      'REPAIR_LIMIT_REACHED',
      'attempts',
      attempted_count
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.assignments
      AS assignments_table
    JOIN championship_bracket_preview_private.slots
      AS slots_table
      ON slots_table.id =
        assignments_table.slot_id
    WHERE assignments_table.job_id =
        _job_id
      AND slots_table.event_date =
        _final_date
      AND slots_table.structural_phase =
        'GROUP_STAGE'
  ) THEN
    RETURN jsonb_build_object(
      'repaired',
      false,
      'status',
      'FINAL_DATE_NOT_EMPTY'
    );
  END IF;

  FOR inbound_record IN
    SELECT
      matches_table.id AS match_id,
      matches_table.competition_id,
      matches_table.home_team_id,
      matches_table.away_team_id,
      matches_table.round_number,
      matches_table.slot_number,
      groups_table.group_number,
      competitions_table.naipe,
      competitions_table.sport_name,
      competitions_table.competition_key,
      (
        SELECT count(*)::integer
        FROM championship_bracket_preview_private.manifest_solver_candidates
          AS final_candidate
        JOIN championship_bracket_preview_private.slots
          AS final_slot
          ON final_slot.id =
            final_candidate.slot_id
        WHERE final_candidate.job_id =
            _job_id
          AND final_candidate.match_id =
            matches_table.id
          AND final_slot.event_date =
            _final_date
          AND final_slot.structural_phase =
            'GROUP_STAGE'
      ) AS final_candidate_count,
      (
        SELECT count(*)::integer
        FROM championship_bracket_preview_private.matches
          AS pressure_match
        JOIN championship_bracket_preview_private.competitions
          AS pressure_competition
          ON pressure_competition.id =
            pressure_match.competition_id
        WHERE pressure_match.job_id =
            _job_id
          AND NOT pressure_match.assigned
          AND pressure_competition.naipe =
            competitions_table.naipe
          AND (
            pressure_match.home_team_id IN (
              matches_table.home_team_id,
              matches_table.away_team_id
            )
            OR pressure_match.away_team_id IN (
              matches_table.home_team_id,
              matches_table.away_team_id
            )
          )
          AND EXISTS (
            SELECT 1
            FROM championship_bracket_preview_private.manifest_solver_candidates
              AS pressure_candidate
            JOIN championship_bracket_preview_private.slots
              AS pressure_slot
              ON pressure_slot.id =
                pressure_candidate.slot_id
            WHERE pressure_candidate.job_id =
                _job_id
              AND pressure_candidate.match_id =
                pressure_match.id
              AND pressure_slot.event_date =
                _final_date
              AND pressure_slot.structural_phase =
                'GROUP_STAGE'
          )
      ) AS team_pressure
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    JOIN championship_bracket_preview_private.groups
      AS groups_table
      ON groups_table.id =
        matches_table.group_id
    WHERE matches_table.job_id =
        _job_id
      AND NOT matches_table.assigned
      AND EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.manifest_solver_candidates
          AS final_candidate
        JOIN championship_bracket_preview_private.slots
          AS final_slot
          ON final_slot.id =
            final_candidate.slot_id
        WHERE final_candidate.job_id =
            _job_id
          AND final_candidate.match_id =
            matches_table.id
          AND final_slot.event_date =
            _final_date
          AND final_slot.structural_phase =
            'GROUP_STAGE'
      )
    ORDER BY
      team_pressure DESC,
      final_candidate_count,
      matches_table.round_number,
      groups_table.group_number,
      matches_table.slot_number,
      matches_table.id
  LOOP
    FOR outbound_record IN
      SELECT
        assignments_table.match_id,
        assignments_table.slot_id,
        slots_table.event_date,
        slots_table.start_at,
        slots_table.end_at,
        outbound_match.home_team_id,
        outbound_match.away_team_id,
        outbound_match.round_number,
        outbound_match.slot_number,
        outbound_match.applied_rest_gap,
        outbound_match.relaxed_rest_gap_applied,
        outbound_group.group_number
      FROM championship_bracket_preview_private.assignments
        AS assignments_table
      JOIN championship_bracket_preview_private.slots
        AS slots_table
        ON slots_table.id =
          assignments_table.slot_id
      JOIN championship_bracket_preview_private.matches
        AS outbound_match
        ON outbound_match.id =
          assignments_table.match_id
      JOIN championship_bracket_preview_private.groups
        AS outbound_group
        ON outbound_group.id =
          outbound_match.group_id
      WHERE assignments_table.job_id =
          _job_id
        AND outbound_match.competition_id =
          inbound_record.competition_id
        AND slots_table.event_date <=
          _closed_date
        AND slots_table.event_date <
          _final_date
        AND slots_table.structural_phase =
          'GROUP_STAGE'
        AND EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.manifest_solver_candidates
            AS inbound_candidate
          WHERE inbound_candidate.job_id =
              _job_id
            AND inbound_candidate.match_id =
              inbound_record.match_id
            AND inbound_candidate.slot_id =
              assignments_table.slot_id
        )
        AND EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.manifest_solver_candidates
            AS outbound_final_candidate
          JOIN championship_bracket_preview_private.slots
            AS outbound_final_slot
            ON outbound_final_slot.id =
              outbound_final_candidate.slot_id
          WHERE outbound_final_candidate.job_id =
              _job_id
            AND outbound_final_candidate.match_id =
              outbound_match.id
            AND outbound_final_slot.event_date =
              _final_date
            AND outbound_final_slot.structural_phase =
              'GROUP_STAGE'
        )
        AND NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.manifest_daily_interday_repairs
            AS previous_attempt
          WHERE previous_attempt.job_id =
              _job_id
            AND previous_attempt.final_date =
              _final_date
            AND previous_attempt.inbound_match_id =
              inbound_record.match_id
            AND previous_attempt.outbound_match_id =
              outbound_match.id
            AND previous_attempt.earlier_slot_id =
              assignments_table.slot_id
        )
      ORDER BY
        slots_table.event_date DESC,
        outbound_match.round_number DESC,
        outbound_group.group_number,
        outbound_match.slot_number,
        assignments_table.slot_id
    LOOP
      SELECT
        final_slot.id
      INTO final_slot_record
      FROM championship_bracket_preview_private.manifest_solver_candidates
        AS final_candidate
      JOIN championship_bracket_preview_private.slots
        AS final_slot
        ON final_slot.id =
          final_candidate.slot_id
      WHERE final_candidate.job_id =
          _job_id
        AND final_candidate.match_id =
          outbound_record.match_id
        AND final_slot.event_date =
          _final_date
        AND final_slot.structural_phase =
          'GROUP_STAGE'
        AND championship_bracket_preview_private.is_manifest_csp_dynamic_candidate_eligible(
          _job_id,
          outbound_record.match_id,
          final_slot.id,
          2
        )
      ORDER BY
        final_slot.start_at,
        final_slot.location_position,
        final_slot.court_position,
        final_slot.cursor_position,
        final_slot.id
      LIMIT 1;

      IF final_slot_record.id IS NULL THEN
        INSERT INTO championship_bracket_preview_private.manifest_daily_interday_repairs (
          job_id,
          closed_date,
          final_date,
          inbound_match_id,
          outbound_match_id,
          earlier_slot_id,
          final_candidate_slot_id,
          success,
          failure_reason
        )
        VALUES (
          _job_id,
          _closed_date,
          _final_date,
          inbound_record.match_id,
          outbound_record.match_id,
          outbound_record.slot_id,
          NULL,
          false,
          'OUTBOUND_WITHOUT_DYNAMIC_FINAL_SLOT'
        )
        ON CONFLICT DO NOTHING;

        CONTINUE;
      END IF;

      outbound_gap :=
        LEAST(
          3,
          GREATEST(
            COALESCE(
              outbound_record.applied_rest_gap,
              3
            ),
            2
          )
        );

      DELETE FROM championship_bracket_preview_private.assignments
      WHERE job_id = _job_id
        AND match_id =
          outbound_record.match_id
        AND slot_id =
          outbound_record.slot_id;

      UPDATE championship_bracket_preview_private.matches
      SET
        assigned = false
      WHERE job_id = _job_id
        AND id =
          outbound_record.match_id;

      IF championship_bracket_preview_private.is_manifest_csp_dynamic_candidate_eligible(
        _job_id,
        inbound_record.match_id,
        outbound_record.slot_id,
        outbound_gap
      ) THEN
        INSERT INTO championship_bracket_preview_private.assignments (
          job_id,
          match_id,
          slot_id
        )
        VALUES (
          _job_id,
          inbound_record.match_id,
          outbound_record.slot_id
        );

        UPDATE championship_bracket_preview_private.matches
        SET
          assigned = true,
          applied_rest_gap =
            outbound_gap,
          relaxed_rest_gap_applied =
            outbound_gap = 2
        WHERE job_id = _job_id
          AND id =
            inbound_record.match_id;

        INSERT INTO championship_bracket_preview_private.manifest_daily_interday_repairs (
          job_id,
          closed_date,
          final_date,
          inbound_match_id,
          outbound_match_id,
          earlier_slot_id,
          final_candidate_slot_id,
          success,
          failure_reason
        )
        VALUES (
          _job_id,
          _closed_date,
          _final_date,
          inbound_record.match_id,
          outbound_record.match_id,
          outbound_record.slot_id,
          final_slot_record.id,
          true,
          NULL
        )
        ON CONFLICT DO NOTHING;

        repair_result :=
          jsonb_build_object(
            'repaired',
            true,
            'status',
            'SWAPPED_TO_EARLIER_DAY',
            'closed_date',
            _closed_date,
            'final_date',
            _final_date,
            'earlier_date',
            outbound_record.event_date,
            'earlier_slot_id',
            outbound_record.slot_id,
            'inbound_match_id',
            inbound_record.match_id,
            'outbound_match_id',
            outbound_record.match_id,
            'outbound_final_candidate_slot_id',
            final_slot_record.id,
            'competition_key',
            inbound_record.competition_key,
            'sport_name',
            inbound_record.sport_name,
            'naipe',
            inbound_record.naipe
          );

        UPDATE championship_bracket_preview_private.manifest_daily_solver_state
        SET
          interday_repairs_count =
            interday_repairs_count + 1,
          last_interday_repair =
            repair_result,
          updated_at = now()
        WHERE job_id = _job_id;

        repaired := true;

        RETURN repair_result;
      END IF;

      INSERT INTO championship_bracket_preview_private.assignments (
        job_id,
        match_id,
        slot_id
      )
      VALUES (
        _job_id,
        outbound_record.match_id,
        outbound_record.slot_id
      );

      UPDATE championship_bracket_preview_private.matches
      SET
        assigned = true,
        applied_rest_gap =
          outbound_record.applied_rest_gap,
        relaxed_rest_gap_applied =
          outbound_record.relaxed_rest_gap_applied
      WHERE job_id = _job_id
        AND id =
          outbound_record.match_id;

      INSERT INTO championship_bracket_preview_private.manifest_daily_interday_repairs (
        job_id,
        closed_date,
        final_date,
        inbound_match_id,
        outbound_match_id,
        earlier_slot_id,
        final_candidate_slot_id,
        success,
        failure_reason
      )
      VALUES (
        _job_id,
        _closed_date,
        _final_date,
        inbound_record.match_id,
        outbound_record.match_id,
        outbound_record.slot_id,
        final_slot_record.id,
        false,
        'INBOUND_NOT_ELIGIBLE_IN_EARLIER_SLOT'
      )
      ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object(
    'repaired',
    repaired,
    'status',
    'NO_VALID_INTERDAY_REPAIR'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.try_place_match_backtracking(_job_id uuid, _match_id uuid, _target_slot_id bigint, _path_match_ids uuid[] DEFAULT ARRAY[]::uuid[], _reserved_slot_ids bigint[] DEFAULT ARRAY[]::bigint[], _depth integer DEFAULT 0, _maximum_depth integer DEFAULT 12, _maximum_candidates_per_match integer DEFAULT 120, _maximum_relocations_per_level integer DEFAULT 40, _deadline timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  current_assignment RECORD;
  has_current_assignment BOOLEAN := false;
  original_match_number INTEGER;
  effective_deadline TIMESTAMPTZ :=
    COALESCE(
      _deadline,
      clock_timestamp() + interval '8 seconds'
    );
  next_path UUID[];
  next_reserved_slots BIGINT[];
BEGIN
  IF clock_timestamp() >= effective_deadline THEN
    RETURN false;
  END IF;

  IF _depth > GREATEST(
    COALESCE(_maximum_depth, 12),
    1
  ) THEN
    RETURN false;
  END IF;

  IF _match_id = ANY(
    COALESCE(
      _path_match_ids,
      ARRAY[]::UUID[]
    )
  ) THEN
    RETURN false;
  END IF;

  IF NOT championship_bracket_preview_private.is_match_slot_static_eligible(
    _job_id,
    _match_id,
    _target_slot_id
  ) THEN
    RETURN false;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.slots AS target_slot
    JOIN championship_bracket_preview_private.slots AS reserved_slot
      ON reserved_slot.job_id = target_slot.job_id
      AND reserved_slot.id = ANY(
        COALESCE(
          _reserved_slot_ids,
          ARRAY[]::BIGINT[]
        )
      )
      AND reserved_slot.court_key = target_slot.court_key
      AND reserved_slot.start_at < target_slot.end_at
      AND reserved_slot.end_at > target_slot.start_at
    WHERE target_slot.job_id = _job_id
      AND target_slot.id = _target_slot_id
  ) THEN
    RETURN false;
  END IF;

  SELECT
    assignment.slot_id,
    assignment.match_number,
    assignment.assigned_at
  INTO current_assignment
  FROM championship_bracket_preview_private.assignments AS assignment
  WHERE assignment.job_id = _job_id
    AND assignment.match_id = _match_id;

  has_current_assignment := FOUND;

  IF has_current_assignment THEN
    original_match_number :=
      current_assignment.match_number;

    IF current_assignment.slot_id = _target_slot_id
      AND championship_bracket_preview_private.is_match_slot_eligible(
        _job_id,
        _match_id,
        _target_slot_id,
        true
      )
    THEN
      RETURN true;
    END IF;
  END IF;

  next_path :=
    array_append(
      COALESCE(
        _path_match_ids,
        ARRAY[]::UUID[]
      ),
      _match_id
    );

  next_reserved_slots :=
    array_append(
      COALESCE(
        _reserved_slot_ids,
        ARRAY[]::BIGINT[]
      ),
      _target_slot_id
    );

  BEGIN
    IF has_current_assignment THEN
      DELETE FROM championship_bracket_preview_private.assignments
      WHERE job_id = _job_id
        AND match_id = _match_id;

      UPDATE championship_bracket_preview_private.matches
      SET assigned = false
      WHERE job_id = _job_id
        AND id = _match_id;
    END IF;

    IF championship_bracket_preview_private.try_resolve_match_slot_backtracking(
      _job_id,
      _match_id,
      _target_slot_id,
      original_match_number,
      next_path,
      next_reserved_slots,
      _depth,
      GREATEST(
        COALESCE(_maximum_depth, 12),
        1
      ),
      GREATEST(
        COALESCE(_maximum_candidates_per_match, 120),
        1
      ),
      GREATEST(
        COALESCE(_maximum_relocations_per_level, 40),
        1
      ),
      0,
      effective_deadline
    ) THEN
      RETURN true;
    END IF;

    RAISE EXCEPTION
      USING
        ERRCODE = 'LJ001',
        MESSAGE = 'Backtracking branch failed';

  EXCEPTION
    WHEN SQLSTATE 'LJ001' THEN
      RETURN false;
  END;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.try_place_match_backtracking_status(_job_id uuid, _match_id uuid, _target_slot_id bigint, _path_match_ids uuid[], _reserved_slot_ids bigint[], _depth integer, _maximum_depth integer, _maximum_candidates_per_match integer, _maximum_relocations_per_level integer, _relaxed_match_id uuid, _relaxed_rest_gap integer, _deadline timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  current_assignment RECORD;
  has_current_assignment BOOLEAN := false;
  original_match_number INTEGER;
  next_path UUID[];
  next_reserved_slots BIGINT[];
  branch_status TEXT;
BEGIN
  IF clock_timestamp() >= _deadline THEN
    RETURN 'TIMEOUT';
  END IF;

  IF _depth > GREATEST(
    COALESCE(_maximum_depth, 12),
    1
  ) THEN
    RETURN 'DEAD_END';
  END IF;

  IF _match_id = ANY(
    COALESCE(
      _path_match_ids,
      ARRAY[]::UUID[]
    )
  ) THEN
    RETURN 'DEAD_END';
  END IF;

  IF NOT championship_bracket_preview_private.is_match_slot_static_eligible(
    _job_id,
    _match_id,
    _target_slot_id
  ) THEN
    RETURN 'DEAD_END';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.slots
      AS target_slot
    JOIN championship_bracket_preview_private.slots
      AS reserved_slot
      ON reserved_slot.job_id =
        target_slot.job_id
      AND reserved_slot.id = ANY(
        COALESCE(
          _reserved_slot_ids,
          ARRAY[]::BIGINT[]
        )
      )
      AND reserved_slot.court_key =
        target_slot.court_key
      AND reserved_slot.start_at <
        target_slot.end_at
      AND reserved_slot.end_at >
        target_slot.start_at
    WHERE target_slot.job_id = _job_id
      AND target_slot.id =
        _target_slot_id
  ) THEN
    RETURN 'DEAD_END';
  END IF;

  SELECT
    assignment.slot_id,
    assignment.match_number,
    assignment.assigned_at
  INTO current_assignment
  FROM championship_bracket_preview_private.assignments
    AS assignment
  WHERE assignment.job_id = _job_id
    AND assignment.match_id = _match_id;

  has_current_assignment := FOUND;

  IF has_current_assignment THEN
    original_match_number :=
      current_assignment.match_number;

    IF current_assignment.slot_id =
      _target_slot_id
      AND championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
        _job_id,
        _match_id,
        _target_slot_id,
        CASE
          WHEN _relaxed_match_id IS NOT NULL
            AND _match_id =
              _relaxed_match_id
          THEN GREATEST(
            COALESCE(
              _relaxed_rest_gap,
              3
            ),
            1
          )
          ELSE 3
        END
      )
    THEN
      RETURN 'SUCCESS';
    END IF;
  END IF;

  next_path :=
    array_append(
      COALESCE(
        _path_match_ids,
        ARRAY[]::UUID[]
      ),
      _match_id
    );

  next_reserved_slots :=
    array_append(
      COALESCE(
        _reserved_slot_ids,
        ARRAY[]::BIGINT[]
      ),
      _target_slot_id
    );

  BEGIN
    IF has_current_assignment THEN
      DELETE FROM championship_bracket_preview_private.assignments
      WHERE job_id = _job_id
        AND match_id = _match_id;

      UPDATE championship_bracket_preview_private.matches
      SET assigned = false
      WHERE job_id = _job_id
        AND id = _match_id;
    END IF;

    branch_status :=
      championship_bracket_preview_private.try_resolve_match_slot_backtracking_status(
        _job_id,
        _match_id,
        _target_slot_id,
        original_match_number,
        next_path,
        next_reserved_slots,
        _depth,
        GREATEST(
          COALESCE(
            _maximum_depth,
            12
          ),
          1
        ),
        GREATEST(
          COALESCE(
            _maximum_candidates_per_match,
            120
          ),
          1
        ),
        GREATEST(
          COALESCE(
            _maximum_relocations_per_level,
            40
          ),
          1
        ),
        0,
        _relaxed_match_id,
        GREATEST(
          COALESCE(
            _relaxed_rest_gap,
            3
          ),
          1
        ),
        _deadline
      );

    IF branch_status = 'SUCCESS' THEN
      RETURN 'SUCCESS';
    END IF;

    IF branch_status = 'TIMEOUT' THEN
      RAISE EXCEPTION
        USING
          ERRCODE = 'LJ003',
          MESSAGE = 'Backtracking branch timed out';
    END IF;

    RAISE EXCEPTION
      USING
        ERRCODE = 'LJ001',
        MESSAGE = 'Backtracking branch failed';

  EXCEPTION
    WHEN SQLSTATE 'LJ003' THEN
      RETURN 'TIMEOUT';
    WHEN SQLSTATE 'LJ001' THEN
      RETURN 'DEAD_END';
  END;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.try_relocate_for_match(_job_id uuid, _pending_match_id uuid, _maximum_moves integer DEFAULT 100)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  candidate_slot_record RECORD;
  effective_deadline TIMESTAMPTZ := clock_timestamp() + interval '8 seconds';
  candidate_limit INTEGER := LEAST(
    GREATEST(
      COALESCE(_maximum_moves, 100) * 3,
      300
    ),
    1000
  );
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.matches AS pending_match
    WHERE pending_match.job_id = _job_id
      AND pending_match.id = _pending_match_id
      AND pending_match.assigned = false
  ) THEN
    RETURN false;
  END IF;

  FOR candidate_slot_record IN
    SELECT
      slots_table.id AS slot_id
    FROM championship_bracket_preview_private.slots AS slots_table
    WHERE slots_table.job_id = _job_id
      AND championship_bracket_preview_private.is_match_slot_eligible(
        _job_id,
        _pending_match_id,
        slots_table.id,
        true
      )
    ORDER BY
      slots_table.event_date,
      slots_table.start_at,
      slots_table.location_position,
      slots_table.court_position,
      slots_table.cursor_position
    LIMIT candidate_limit
  LOOP
    INSERT INTO championship_bracket_preview_private.assignments (
      job_id,
      match_id,
      slot_id
    )
    VALUES (
      _job_id,
      _pending_match_id,
      candidate_slot_record.slot_id
    );

    UPDATE championship_bracket_preview_private.matches
    SET assigned = true
    WHERE job_id = _job_id
      AND id = _pending_match_id;

    RETURN true;
  END LOOP;

  FOR candidate_slot_record IN
    SELECT candidate_slot.*
    FROM championship_bracket_preview_private.resolve_match_relocation_candidate_slots(
      _job_id,
      _pending_match_id,
      NULL,
      ARRAY[]::BIGINT[],
      candidate_limit
    ) AS candidate_slot
    ORDER BY
      candidate_slot.event_date,
      candidate_slot.start_at,
      candidate_slot.location_key,
      candidate_slot.court_key,
      candidate_slot.sequence_index,
      candidate_slot.slot_id
  LOOP
    EXIT WHEN clock_timestamp() >= effective_deadline;

    IF championship_bracket_preview_private.try_place_match_backtracking(
      _job_id,
      _pending_match_id,
      candidate_slot_record.slot_id,
      ARRAY[]::UUID[],
      ARRAY[]::BIGINT[],
      0,
      12,
      120,
      40,
      effective_deadline
    ) THEN
      RETURN true;
    END IF;
  END LOOP;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.try_relocate_for_match_search(_job_id uuid, _pending_match_id uuid, _maximum_moves integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  pending_match_record RECORD;
  candidate_slot_record RECORD;
  tier_record RECORD;
  current_phase TEXT;
  current_tier TEXT;
  current_rest_gap INTEGER;
  branch_status TEXT;
  attempt_started_at TIMESTAMPTZ;
  overall_deadline TIMESTAMPTZ;
  candidate_deadline TIMESTAMPTZ;
  attempted_candidates INTEGER := 0;
  has_relaxation_opportunity BOOLEAN := false;
  has_retryable_after_attempt BOOLEAN := false;
  next_timeout_count INTEGER;
  state_status TEXT;
  attempt_result_status TEXT;
BEGIN
  SELECT *
  INTO pending_match_record
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND id = _pending_match_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'assigned',
      false,
      'progressed',
      false,
      'exhausted',
      true,
      'attempted_candidates',
      0
    );
  END IF;

  IF pending_match_record.assigned
    OR pending_match_record.relocation_search_exhausted
  THEN
    RETURN jsonb_build_object(
      'assigned',
      pending_match_record.assigned,
      'progressed',
      false,
      'exhausted',
      pending_match_record.relocation_search_exhausted,
      'attempted_candidates',
      0
    );
  END IF;

  current_phase :=
    CASE
      WHEN pending_match_record.relocation_search_phase =
        'RELAXED'
      THEN 'RELAXED'
      ELSE 'STRICT'
    END;

  current_tier :=
    CASE
      WHEN pending_match_record.relocation_search_tier IN (
        'FAST',
        'MEDIUM',
        'DEEP'
      )
      THEN pending_match_record.relocation_search_tier
      ELSE 'FAST'
    END;

  current_rest_gap :=
    CASE
      WHEN current_phase = 'RELAXED'
      THEN 2
      ELSE 3
    END;

  IF pending_match_record.relocation_search_tier
    IS DISTINCT FROM current_tier
  THEN
    UPDATE championship_bracket_preview_private.matches
    SET relocation_search_tier = current_tier
    WHERE job_id = _job_id
      AND id = _pending_match_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.relocation_ranked_candidate_cache_runs
      AS cache_runs
    WHERE cache_runs.job_id = _job_id
      AND cache_runs.match_id = _pending_match_id
      AND cache_runs.phase = current_phase
  ) THEN
    DELETE FROM championship_bracket_preview_private.relocation_ranked_candidate_cache
      AS cached_candidates
    WHERE cached_candidates.job_id = _job_id
      AND cached_candidates.match_id = _pending_match_id
      AND cached_candidates.phase = current_phase;

    INSERT INTO championship_bracket_preview_private.relocation_ranked_candidate_cache (
      job_id,
      match_id,
      phase,
      slot_id,
      candidate_rank
    )
    SELECT
      _job_id,
      _pending_match_id,
      current_phase,
      ranked_candidates.slot_id,
      ranked_candidates.candidate_rank
    FROM championship_bracket_preview_private.resolve_match_relocation_candidate_slots_ranked_v7(
      _job_id,
      _pending_match_id,
      NULL,
      ARRAY[]::BIGINT[],
      0,
      120,
      current_rest_gap
    ) AS ranked_candidates
    ON CONFLICT DO NOTHING;

    INSERT INTO championship_bracket_preview_private.relocation_ranked_candidate_cache_runs (
      job_id,
      match_id,
      phase
    )
    VALUES (
      _job_id,
      _pending_match_id,
      current_phase
    )
    ON CONFLICT (
      job_id,
      match_id,
      phase
    )
    DO UPDATE SET
      generated_at = now();

    RETURN jsonb_build_object(
      'assigned',
      false,
      'progressed',
      true,
      'exhausted',
      false,
      'cache_generated',
      true,
      'search_tier',
      current_tier,
      'search_phase',
      current_phase,
      'rest_gap',
      current_rest_gap,
      'attempted_candidates',
      0
    );
  END IF;

  SELECT *
  INTO tier_record
  FROM (
    VALUES
      (
        'FAST'::TEXT,
        2,
        12,
        4,
        400,
        1
      ),
      (
        'MEDIUM'::TEXT,
        6,
        48,
        16,
        1800,
        1
      ),
      (
        'DEEP'::TEXT,
        12,
        120,
        40,
        7000,
        3
      )
  ) AS tiers(
    search_tier,
    max_depth,
    candidate_limit,
    relocation_limit,
    budget_ms,
    retry_limit
  )
  WHERE tiers.search_tier = current_tier;

  IF NOT FOUND THEN
    current_tier := 'FAST';

    UPDATE championship_bracket_preview_private.matches
    SET
      relocation_search_tier = 'FAST',
      relocation_candidate_cursor = 0
    WHERE job_id = _job_id
      AND id = _pending_match_id;

    SELECT *
    INTO tier_record
    FROM (
      VALUES
        (
          'FAST'::TEXT,
          2,
          12,
          4,
          400,
          1
        )
    ) AS tiers(
      search_tier,
      max_depth,
      candidate_limit,
      relocation_limit,
      budget_ms,
      retry_limit
    );
  END IF;

  overall_deadline :=
    clock_timestamp()
    + interval '10 seconds';

  FOR candidate_slot_record IN
    SELECT
      cached_candidates.candidate_rank,
      cached_candidates.slot_id,
      candidate_states.status
        AS candidate_status,
      COALESCE(
        candidate_states.timeout_count,
        0
      ) AS timeout_count
    FROM championship_bracket_preview_private.relocation_ranked_candidate_cache
      AS cached_candidates
    LEFT JOIN championship_bracket_preview_private.relocation_candidate_tier_states
      AS candidate_states
      ON candidate_states.job_id = _job_id
      AND candidate_states.match_id = _pending_match_id
      AND candidate_states.phase = current_phase
      AND candidate_states.search_tier = current_tier
      AND candidate_states.slot_id =
        cached_candidates.slot_id
    WHERE cached_candidates.job_id = _job_id
      AND cached_candidates.match_id = _pending_match_id
      AND cached_candidates.phase = current_phase
      AND cached_candidates.candidate_rank
        <= tier_record.candidate_limit
      AND (
        candidate_states.status IS NULL
        OR (
          candidate_states.status =
            current_tier || '_TIMEOUT'
          AND candidate_states.timeout_count
            < tier_record.retry_limit
        )
      )
    ORDER BY cached_candidates.candidate_rank
  LOOP
    IF clock_timestamp() >= overall_deadline THEN
      RETURN jsonb_build_object(
        'assigned',
        false,
        'progressed',
        attempted_candidates > 0,
        'exhausted',
        false,
        'attempted_candidates',
        attempted_candidates,
        'candidate_cursor',
        (
          SELECT relocation_candidate_cursor
          FROM championship_bracket_preview_private.matches
          WHERE job_id = _job_id
            AND id = _pending_match_id
        ),
        'search_tier',
        current_tier,
        'search_phase',
        current_phase,
        'rest_gap',
        current_rest_gap
      );
    END IF;

    attempted_candidates :=
      attempted_candidates + 1;

    attempt_started_at :=
      clock_timestamp();

    candidate_deadline :=
      LEAST(
        overall_deadline,
        clock_timestamp()
          + make_interval(
              secs =>
                tier_record.budget_ms::double precision
                / 1000.0
            )
      );

    branch_status :=
      championship_bracket_preview_private.try_place_match_backtracking_status(
        _job_id,
        _pending_match_id,
        candidate_slot_record.slot_id,
        ARRAY[]::UUID[],
        ARRAY[]::BIGINT[],
        0,
        tier_record.max_depth,
        tier_record.candidate_limit,
        tier_record.relocation_limit,
        CASE
          WHEN current_phase = 'RELAXED'
          THEN _pending_match_id
          ELSE NULL
        END,
        2,
        candidate_deadline
      );

    attempt_result_status :=
      CASE
        WHEN branch_status = 'SUCCESS'
        THEN 'SUCCESS'
        WHEN branch_status = 'TIMEOUT'
        THEN current_tier || '_TIMEOUT'
        ELSE current_tier || '_DEAD_END'
      END;

    INSERT INTO championship_bracket_preview_private.relocation_attempt_metrics (
      job_id,
      match_id,
      phase,
      rest_gap,
      search_tier,
      candidate_rank,
      candidate_slot_id,
      max_depth,
      candidate_limit,
      relocation_limit,
      result_status,
      timeout_count,
      relocations_used,
      branches_examined,
      duration_ms
    )
    VALUES (
      _job_id,
      _pending_match_id,
      current_phase,
      current_rest_gap,
      current_tier,
      candidate_slot_record.candidate_rank,
      candidate_slot_record.slot_id,
      tier_record.max_depth,
      tier_record.candidate_limit,
      tier_record.relocation_limit,
      attempt_result_status,
      candidate_slot_record.timeout_count,
      0,
      0,
      (
        extract(
          epoch FROM (
            clock_timestamp()
              - attempt_started_at
          )
        ) * 1000
      )::integer
    );

    UPDATE championship_bracket_preview_private.matches
    SET
      relocation_candidate_cursor =
        GREATEST(
          relocation_candidate_cursor,
          candidate_slot_record.candidate_rank::integer
        ),
      relocation_attempt_count =
        relocation_attempt_count + 1
    WHERE job_id = _job_id
      AND id = _pending_match_id;

    IF branch_status = 'SUCCESS' THEN
      UPDATE championship_bracket_preview_private.matches
      SET
        relaxed_rest_gap_applied =
          current_phase = 'RELAXED',
        applied_rest_gap =
          current_rest_gap,
        relocation_candidate_cursor = 0,
        relocation_search_exhausted = false,
        relocation_attempt_count = 0,
        relocation_search_phase = 'STRICT',
        relocation_search_tier = 'FAST'
      WHERE job_id = _job_id
        AND id = _pending_match_id;

      DELETE FROM championship_bracket_preview_private.relocation_ranked_candidate_cache
      WHERE job_id = _job_id;

      DELETE FROM championship_bracket_preview_private.relocation_ranked_candidate_cache_runs
      WHERE job_id = _job_id;

      DELETE FROM championship_bracket_preview_private.relocation_candidate_tier_states
      WHERE job_id = _job_id;

      DELETE FROM championship_bracket_preview_private.relocation_candidate_states
      WHERE job_id = _job_id;

      UPDATE championship_bracket_preview_private.matches
      SET
        relocation_candidate_cursor = 0,
        relocation_search_exhausted = false,
        relocation_search_phase = 'STRICT',
        relocation_search_tier = 'FAST',
        relaxed_rest_gap_applied = false,
        applied_rest_gap = 3
      WHERE job_id = _job_id
        AND assigned = false;

      RETURN jsonb_build_object(
        'assigned',
        true,
        'progressed',
        true,
        'exhausted',
        false,
        'attempted_candidates',
        attempted_candidates,
        'search_tier',
        current_tier,
        'search_phase',
        current_phase,
        'rest_gap',
        current_rest_gap
      );
    END IF;

    IF branch_status = 'TIMEOUT' THEN
      next_timeout_count :=
        candidate_slot_record.timeout_count + 1;

      state_status :=
        CASE
          WHEN next_timeout_count
            >= tier_record.retry_limit
          THEN current_tier || '_SEARCH_LIMIT'
          ELSE current_tier || '_TIMEOUT'
        END;

      IF next_timeout_count
        < tier_record.retry_limit
      THEN
        has_retryable_after_attempt := true;
      END IF;
    ELSE
      next_timeout_count :=
        candidate_slot_record.timeout_count;

      state_status :=
        current_tier || '_DEAD_END';
    END IF;

    INSERT INTO championship_bracket_preview_private.relocation_candidate_tier_states (
      job_id,
      match_id,
      phase,
      search_tier,
      slot_id,
      status,
      attempt_count,
      timeout_count,
      last_attempt_at
    )
    VALUES (
      _job_id,
      _pending_match_id,
      current_phase,
      current_tier,
      candidate_slot_record.slot_id,
      state_status,
      1,
      next_timeout_count,
      now()
    )
    ON CONFLICT (
      job_id,
      match_id,
      phase,
      search_tier,
      slot_id
    )
    DO UPDATE SET
      status = EXCLUDED.status,
      attempt_count =
        championship_bracket_preview_private
          .relocation_candidate_tier_states
          .attempt_count + 1,
      timeout_count =
        EXCLUDED.timeout_count,
      last_attempt_at =
        now();
  END LOOP;

  IF has_retryable_after_attempt THEN
    RETURN jsonb_build_object(
      'assigned',
      false,
      'progressed',
      attempted_candidates > 0,
      'exhausted',
      false,
      'attempted_candidates',
      attempted_candidates,
      'candidate_cursor',
      (
        SELECT relocation_candidate_cursor
        FROM championship_bracket_preview_private.matches
        WHERE job_id = _job_id
          AND id = _pending_match_id
      ),
      'search_tier',
      current_tier,
      'search_phase',
      current_phase,
      'rest_gap',
      current_rest_gap
    );
  END IF;

  IF current_tier = 'FAST' THEN
    UPDATE championship_bracket_preview_private.matches
    SET
      relocation_search_tier = 'MEDIUM',
      relocation_candidate_cursor = 0
    WHERE job_id = _job_id
      AND id = _pending_match_id;

    RETURN jsonb_build_object(
      'assigned',
      false,
      'progressed',
      true,
      'exhausted',
      false,
      'tier_changed',
      true,
      'search_tier',
      'MEDIUM',
      'search_phase',
      current_phase,
      'rest_gap',
      current_rest_gap,
      'attempted_candidates',
      attempted_candidates
    );
  END IF;

  IF current_tier = 'MEDIUM' THEN
    UPDATE championship_bracket_preview_private.matches
    SET
      relocation_search_tier = 'DEEP',
      relocation_candidate_cursor = 0
    WHERE job_id = _job_id
      AND id = _pending_match_id;

    RETURN jsonb_build_object(
      'assigned',
      false,
      'progressed',
      true,
      'exhausted',
      false,
      'tier_changed',
      true,
      'search_tier',
      'DEEP',
      'search_phase',
      current_phase,
      'rest_gap',
      current_rest_gap,
      'attempted_candidates',
      attempted_candidates
    );
  END IF;

  IF current_phase = 'STRICT' THEN
    SELECT EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.resolve_match_relocation_candidate_slots(
        _job_id,
        _pending_match_id,
        NULL,
        ARRAY[]::BIGINT[],
        1000000
      ) AS candidate_slot
      WHERE EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.assignments
          AS assignments_table
        WHERE assignments_table.job_id = _job_id
          AND championship_bracket_preview_private.is_match_rest_conflict_with_gap(
            _job_id,
            _pending_match_id,
            candidate_slot.slot_id,
            assignments_table.match_id,
            3
          )
          AND NOT championship_bracket_preview_private.is_match_rest_conflict_with_gap(
            _job_id,
            _pending_match_id,
            candidate_slot.slot_id,
            assignments_table.match_id,
            2
          )
      )
    )
    INTO has_relaxation_opportunity;

    IF has_relaxation_opportunity THEN
      DELETE FROM championship_bracket_preview_private.relocation_ranked_candidate_cache
      WHERE job_id = _job_id
        AND match_id = _pending_match_id
        AND phase = 'RELAXED';

      DELETE FROM championship_bracket_preview_private.relocation_ranked_candidate_cache_runs
      WHERE job_id = _job_id
        AND match_id = _pending_match_id
        AND phase = 'RELAXED';

      DELETE FROM championship_bracket_preview_private.relocation_candidate_tier_states
      WHERE job_id = _job_id
        AND match_id = _pending_match_id
        AND phase = 'RELAXED';

      UPDATE championship_bracket_preview_private.matches
      SET
        relocation_search_phase = 'RELAXED',
        relocation_search_tier = 'FAST',
        relocation_candidate_cursor = 0
      WHERE job_id = _job_id
        AND id = _pending_match_id;

      RETURN jsonb_build_object(
        'assigned',
        false,
        'progressed',
        true,
        'exhausted',
        false,
        'phase_changed',
        true,
        'search_tier',
        'FAST',
        'search_phase',
        'RELAXED',
        'rest_gap',
        2,
        'attempted_candidates',
        attempted_candidates
      );
    END IF;
  END IF;

  UPDATE championship_bracket_preview_private.matches
  SET
    relocation_search_exhausted = true,
    relocation_candidate_cursor = 0
  WHERE job_id = _job_id
    AND id = _pending_match_id
    AND assigned = false;

  RETURN jsonb_build_object(
    'assigned',
    false,
    'progressed',
    attempted_candidates > 0,
    'exhausted',
    true,
    'attempted_candidates',
    attempted_candidates,
    'search_tier',
    current_tier,
    'search_phase',
    current_phase,
    'rest_gap',
    current_rest_gap
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.try_resolve_match_slot_backtracking(_job_id uuid, _match_id uuid, _target_slot_id bigint, _match_number integer, _path_match_ids uuid[], _reserved_slot_ids bigint[], _depth integer, _maximum_depth integer, _maximum_candidates_per_match integer, _maximum_relocations integer, _relocations_used integer, _deadline timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  blocker_record RECORD;
  candidate_slot_record RECORD;
  target_event_date DATE;
  target_court_key UUID;
  target_start_at TIMESTAMPTZ;
  target_end_at TIMESTAMPTZ;
  target_round_number INTEGER;
  has_hard_blockers BOOLEAN := false;
BEGIN
  IF clock_timestamp() >= _deadline THEN
    RETURN false;
  END IF;

  IF _depth > GREATEST(_maximum_depth, 1) THEN
    RETURN false;
  END IF;

  IF _relocations_used >= GREATEST(_maximum_relocations, 1) THEN
    RETURN false;
  END IF;

  SELECT
    target_slot.event_date,
    target_slot.court_key,
    target_slot.start_at,
    target_slot.end_at,
    target_match.round_number
  INTO
    target_event_date,
    target_court_key,
    target_start_at,
    target_end_at,
    target_round_number
  FROM championship_bracket_preview_private.slots AS target_slot
  JOIN championship_bracket_preview_private.matches AS target_match
    ON target_match.job_id = target_slot.job_id
    AND target_match.id = _match_id
  WHERE target_slot.job_id = _job_id
    AND target_slot.id = _target_slot_id;

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  IF championship_bracket_preview_private.is_match_slot_eligible(
    _job_id,
    _match_id,
    _target_slot_id,
    true
  ) THEN
    INSERT INTO championship_bracket_preview_private.assignments (
      job_id,
      match_id,
      slot_id,
      match_number
    )
    VALUES (
      _job_id,
      _match_id,
      _target_slot_id,
      _match_number
    );

    UPDATE championship_bracket_preview_private.matches
    SET assigned = true
    WHERE job_id = _job_id
      AND id = _match_id;

    RETURN true;
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.resolve_match_slot_blockers(
      _job_id,
      _match_id,
      _target_slot_id
    ) AS blockers
    WHERE blockers.blocker_match_id <> _match_id
      AND NOT (
        blockers.blocker_match_id = ANY(
          COALESCE(
            _path_match_ids,
            ARRAY[]::UUID[]
          )
        )
      )
      AND blockers.blocker_reasons && ARRAY[
        'EARLIER_ROUND_PENDING',
        'COURT_OCCUPATION',
        'TEAM_REST_CONSTRAINT',
        'ROUND_ORDER_CONSTRAINT'
      ]::TEXT[]
  )
  INTO has_hard_blockers;

  FOR blocker_record IN
    SELECT
      blockers.blocker_match_id,
      blockers.blocker_slot_id,
      blockers.blocker_is_assigned,
      blockers.blocker_reasons,
      blocker_match.round_number AS blocker_round_number,
      blocker_match.priority_weight AS blocker_priority_weight,
      blocker_match.slot_number AS blocker_slot_number,
      blocker_match.logical_key AS blocker_logical_key
    FROM championship_bracket_preview_private.resolve_match_slot_blockers(
      _job_id,
      _match_id,
      _target_slot_id
    ) AS blockers
    LEFT JOIN championship_bracket_preview_private.matches AS blocker_match
      ON blocker_match.job_id = _job_id
      AND blocker_match.id = blockers.blocker_match_id
    WHERE blockers.blocker_match_id <> _match_id
      AND NOT (
        blockers.blocker_match_id = ANY(
          COALESCE(
            _path_match_ids,
            ARRAY[]::UUID[]
          )
        )
      )
      AND (
        (
          has_hard_blockers
          AND blockers.blocker_reasons && ARRAY[
            'EARLIER_ROUND_PENDING',
            'COURT_OCCUPATION',
            'TEAM_REST_CONSTRAINT',
            'ROUND_ORDER_CONSTRAINT'
          ]::TEXT[]
        )
        OR (
          NOT has_hard_blockers
          AND 'TARGET_CAPACITY' = ANY(
            blockers.blocker_reasons
          )
        )
      )
    ORDER BY
      CASE
        WHEN 'EARLIER_ROUND_PENDING' = ANY(blockers.blocker_reasons)
          THEN 1
        WHEN 'COURT_OCCUPATION' = ANY(blockers.blocker_reasons)
          THEN 2
        WHEN 'TEAM_REST_CONSTRAINT' = ANY(blockers.blocker_reasons)
          THEN 3
        WHEN 'ROUND_ORDER_CONSTRAINT' = ANY(blockers.blocker_reasons)
          THEN 4
        ELSE 5
      END,
      blocker_match.priority_weight DESC NULLS LAST,
      blocker_match.round_number NULLS LAST,
      blocker_match.slot_number NULLS LAST,
      blocker_match.logical_key NULLS LAST,
      blockers.blocker_match_id
  LOOP
    FOR candidate_slot_record IN
      SELECT candidate_slot.*
      FROM championship_bracket_preview_private.resolve_match_relocation_candidate_slots_ranked(
        _job_id,
        blocker_record.blocker_match_id,
        blocker_record.blocker_slot_id,
        _reserved_slot_ids,
        0,
        _maximum_candidates_per_match
      ) AS candidate_slot
      WHERE (
        NOT (
          'TARGET_CAPACITY' = ANY(
            blocker_record.blocker_reasons
          )
        )
        OR candidate_slot.event_date <> target_event_date
        OR candidate_slot.court_key <> target_court_key
      )
      AND (
        NOT (
          'EARLIER_ROUND_PENDING' = ANY(
            blocker_record.blocker_reasons
          )
        )
        OR candidate_slot.end_at <= target_start_at
      )
      AND (
        NOT (
          'ROUND_ORDER_CONSTRAINT' = ANY(
            blocker_record.blocker_reasons
          )
        )
        OR blocker_record.blocker_round_number IS NULL
        OR (
          blocker_record.blocker_round_number < target_round_number
          AND candidate_slot.end_at <= target_start_at
        )
        OR (
          blocker_record.blocker_round_number > target_round_number
          AND candidate_slot.start_at >= target_end_at
        )
        OR blocker_record.blocker_round_number = target_round_number
      )
      ORDER BY candidate_slot.candidate_rank
    LOOP
      EXIT WHEN clock_timestamp() >= _deadline;

      BEGIN
        IF NOT championship_bracket_preview_private.try_place_match_backtracking(
          _job_id,
          blocker_record.blocker_match_id,
          candidate_slot_record.slot_id,
          _path_match_ids,
          _reserved_slot_ids,
          _depth + 1,
          _maximum_depth,
          _maximum_candidates_per_match,
          _maximum_relocations,
          _deadline
        ) THEN
          RAISE EXCEPTION
            USING
              ERRCODE = 'LJ002',
              MESSAGE = 'Relocation branch failed';
        END IF;

        IF championship_bracket_preview_private.try_resolve_match_slot_backtracking(
          _job_id,
          _match_id,
          _target_slot_id,
          _match_number,
          array_append(
            COALESCE(
              _path_match_ids,
              ARRAY[]::UUID[]
            ),
            blocker_record.blocker_match_id
          ),
          _reserved_slot_ids,
          _depth + 1,
          _maximum_depth,
          _maximum_candidates_per_match,
          _maximum_relocations,
          _relocations_used + 1,
          _deadline
        ) THEN
          RETURN true;
        END IF;

        RAISE EXCEPTION
          USING
            ERRCODE = 'LJ002',
            MESSAGE = 'Relocation branch reached dead end';

      EXCEPTION
        WHEN SQLSTATE 'LJ002' THEN
          NULL;
      END;
    END LOOP;
  END LOOP;

  RETURN false;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.try_resolve_match_slot_backtracking_status(_job_id uuid, _match_id uuid, _target_slot_id bigint, _match_number integer, _path_match_ids uuid[], _reserved_slot_ids bigint[], _depth integer, _maximum_depth integer, _maximum_candidates_per_match integer, _maximum_relocations integer, _relocations_used integer, _relaxed_match_id uuid, _relaxed_rest_gap integer, _deadline timestamp with time zone)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  blocker_record RECORD;
  candidate_slot_record RECORD;
  target_event_date DATE;
  target_court_key UUID;
  target_start_at TIMESTAMPTZ;
  target_end_at TIMESTAMPTZ;
  target_round_number INTEGER;
  effective_rest_gap INTEGER;
  blocker_rest_gap INTEGER;
  branch_status TEXT;
  saw_blocker BOOLEAN := false;
  inserted_assignment BOOLEAN;
BEGIN
  IF clock_timestamp() >= _deadline THEN
    RETURN 'TIMEOUT';
  END IF;

  IF _depth > GREATEST(
    COALESCE(_maximum_depth, 12),
    1
  ) THEN
    RETURN 'DEAD_END';
  END IF;

  IF _relocations_used >= GREATEST(
    COALESCE(_maximum_relocations, 40),
    1
  ) THEN
    RETURN 'DEAD_END';
  END IF;

  effective_rest_gap :=
    CASE
      WHEN _relaxed_match_id IS NOT NULL
        AND _match_id = _relaxed_match_id
      THEN GREATEST(
        COALESCE(
          _relaxed_rest_gap,
          3
        ),
        1
      )
      ELSE 3
    END;

  SELECT
    target_slot.event_date,
    target_slot.court_key,
    target_slot.start_at,
    target_slot.end_at,
    target_match.round_number
  INTO
    target_event_date,
    target_court_key,
    target_start_at,
    target_end_at,
    target_round_number
  FROM championship_bracket_preview_private.slots
    AS target_slot
  JOIN championship_bracket_preview_private.matches
    AS target_match
    ON target_match.job_id =
      target_slot.job_id
    AND target_match.id =
      _match_id
  WHERE target_slot.job_id = _job_id
    AND target_slot.id =
      _target_slot_id;

  IF NOT FOUND THEN
    RETURN 'DEAD_END';
  END IF;

  IF clock_timestamp() >= _deadline THEN
    RETURN 'TIMEOUT';
  END IF;

  IF championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
    _job_id,
    _match_id,
    _target_slot_id,
    effective_rest_gap
  ) THEN
    inserted_assignment := false;

    INSERT INTO championship_bracket_preview_private.assignments (
      job_id,
      match_id,
      slot_id,
      match_number
    )
    VALUES (
      _job_id,
      _match_id,
      _target_slot_id,
      _match_number
    )
    ON CONFLICT DO NOTHING
    RETURNING true
    INTO inserted_assignment;

    IF NOT COALESCE(
      inserted_assignment,
      false
    ) THEN
      RETURN 'DEAD_END';
    END IF;

    UPDATE championship_bracket_preview_private.matches
    SET assigned = true
    WHERE job_id = _job_id
      AND id = _match_id;

    RETURN 'SUCCESS';
  END IF;

  FOR blocker_record IN
    WITH raw_blockers AS MATERIALIZED (
      SELECT
        blockers.blocker_match_id,
        blockers.blocker_slot_id,
        blockers.blocker_is_assigned,
        blockers.blocker_reasons,
        blocker_match.round_number
          AS blocker_round_number,
        blocker_match.priority_weight
          AS blocker_priority_weight,
        blocker_match.slot_number
          AS blocker_slot_number,
        blocker_match.logical_key
          AS blocker_logical_key,
        blockers.blocker_reasons && ARRAY[
          'EARLIER_ROUND_PENDING',
          'COURT_OCCUPATION',
          'TEAM_REST_CONSTRAINT',
          'ROUND_ORDER_CONSTRAINT'
        ]::TEXT[] AS is_hard_blocker
      FROM championship_bracket_preview_private.resolve_match_slot_blockers_with_rest_gap(
        _job_id,
        _match_id,
        _target_slot_id,
        effective_rest_gap
      ) AS blockers
      LEFT JOIN championship_bracket_preview_private.matches
        AS blocker_match
        ON blocker_match.job_id = _job_id
        AND blocker_match.id =
          blockers.blocker_match_id
      WHERE blockers.blocker_match_id <> _match_id
        AND NOT (
          blockers.blocker_match_id = ANY(
            COALESCE(
              _path_match_ids,
              ARRAY[]::UUID[]
            )
          )
        )
    ),
    annotated_blockers AS (
      SELECT
        raw_blockers.*,
        bool_or(
          raw_blockers.is_hard_blocker
        ) OVER () AS has_hard_blockers
      FROM raw_blockers
    )
    SELECT
      annotated_blockers.blocker_match_id,
      annotated_blockers.blocker_slot_id,
      annotated_blockers.blocker_is_assigned,
      annotated_blockers.blocker_reasons,
      annotated_blockers.blocker_round_number,
      annotated_blockers.blocker_priority_weight,
      annotated_blockers.blocker_slot_number,
      annotated_blockers.blocker_logical_key
    FROM annotated_blockers
    WHERE (
      annotated_blockers.has_hard_blockers
      AND annotated_blockers.is_hard_blocker
    )
    OR (
      NOT annotated_blockers.has_hard_blockers
      AND 'TARGET_CAPACITY' = ANY(
        annotated_blockers.blocker_reasons
      )
    )
    ORDER BY
      CASE
        WHEN 'EARLIER_ROUND_PENDING' = ANY(
          annotated_blockers.blocker_reasons
        )
        THEN 1
        WHEN 'COURT_OCCUPATION' = ANY(
          annotated_blockers.blocker_reasons
        )
        THEN 2
        WHEN 'TEAM_REST_CONSTRAINT' = ANY(
          annotated_blockers.blocker_reasons
        )
        THEN 3
        WHEN 'ROUND_ORDER_CONSTRAINT' = ANY(
          annotated_blockers.blocker_reasons
        )
        THEN 4
        ELSE 5
      END,
      annotated_blockers.blocker_priority_weight
        DESC NULLS LAST,
      annotated_blockers.blocker_round_number
        NULLS LAST,
      annotated_blockers.blocker_slot_number
        NULLS LAST,
      annotated_blockers.blocker_logical_key
        NULLS LAST,
      annotated_blockers.blocker_match_id
  LOOP
    saw_blocker := true;

    IF clock_timestamp() >= _deadline THEN
      RETURN 'TIMEOUT';
    END IF;

    blocker_rest_gap :=
      CASE
        WHEN _relaxed_match_id IS NOT NULL
          AND blocker_record.blocker_match_id =
            _relaxed_match_id
        THEN GREATEST(
          COALESCE(
            _relaxed_rest_gap,
            3
          ),
          1
        )
        ELSE 3
      END;

    FOR candidate_slot_record IN
      SELECT
        candidate_slot.*
      FROM championship_bracket_preview_private.resolve_match_relocation_candidate_slots(
        _job_id,
        blocker_record.blocker_match_id,
        blocker_record.blocker_slot_id,
        _reserved_slot_ids,
        GREATEST(
          COALESCE(
            _maximum_candidates_per_match,
            120
          ),
          1
        )
      ) AS candidate_slot
      WHERE (
        NOT (
          'TARGET_CAPACITY' = ANY(
            blocker_record.blocker_reasons
          )
        )
        OR candidate_slot.event_date <>
          target_event_date
        OR candidate_slot.court_key <>
          target_court_key
      )
      AND (
        NOT (
          'EARLIER_ROUND_PENDING' = ANY(
            blocker_record.blocker_reasons
          )
        )
        OR candidate_slot.end_at <=
          target_start_at
      )
      AND (
        NOT (
          'ROUND_ORDER_CONSTRAINT' = ANY(
            blocker_record.blocker_reasons
          )
        )
        OR blocker_record.blocker_round_number
          IS NULL
        OR (
          blocker_record.blocker_round_number <
            target_round_number
          AND candidate_slot.end_at <=
            target_start_at
        )
        OR (
          blocker_record.blocker_round_number >
            target_round_number
          AND candidate_slot.start_at >=
            target_end_at
        )
        OR blocker_record.blocker_round_number =
          target_round_number
      )
      AND (
        NOT (
          'TEAM_REST_CONSTRAINT' = ANY(
            blocker_record.blocker_reasons
          )
        )
        OR NOT championship_bracket_preview_private.is_match_pair_rest_conflict(
          _job_id,
          _match_id,
          _target_slot_id,
          blocker_record.blocker_match_id,
          candidate_slot.slot_id,
          effective_rest_gap
        )
      )
      ORDER BY
        CASE
          WHEN championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
            _job_id,
            blocker_record.blocker_match_id,
            candidate_slot.slot_id,
            blocker_rest_gap
          )
          THEN 0
          ELSE 1
        END,
        candidate_slot.day_distance,
        candidate_slot.time_distance_seconds,
        candidate_slot.event_date,
        candidate_slot.start_at,
        candidate_slot.location_key,
        candidate_slot.court_key,
        candidate_slot.sequence_index,
        candidate_slot.slot_id
    LOOP
      IF clock_timestamp() >= _deadline THEN
        RETURN 'TIMEOUT';
      END IF;

      BEGIN
        branch_status :=
          championship_bracket_preview_private.try_place_match_backtracking_status(
            _job_id,
            blocker_record.blocker_match_id,
            candidate_slot_record.slot_id,
            _path_match_ids,
            _reserved_slot_ids,
            _depth + 1,
            _maximum_depth,
            _maximum_candidates_per_match,
            _maximum_relocations,
            _relaxed_match_id,
            _relaxed_rest_gap,
            _deadline
          );

        IF branch_status = 'TIMEOUT' THEN
          RAISE EXCEPTION
            USING
              ERRCODE = 'LJ003',
              MESSAGE = 'Relocation branch timed out';
        END IF;

        IF branch_status <> 'SUCCESS' THEN
          RAISE EXCEPTION
            USING
              ERRCODE = 'LJ002',
              MESSAGE = 'Relocation branch failed';
        END IF;

        branch_status :=
          championship_bracket_preview_private.try_resolve_match_slot_backtracking_status(
            _job_id,
            _match_id,
            _target_slot_id,
            _match_number,
            array_append(
              COALESCE(
                _path_match_ids,
                ARRAY[]::UUID[]
              ),
              blocker_record.blocker_match_id
            ),
            _reserved_slot_ids,
            _depth + 1,
            _maximum_depth,
            _maximum_candidates_per_match,
            _maximum_relocations,
            _relocations_used + 1,
            _relaxed_match_id,
            _relaxed_rest_gap,
            _deadline
          );

        IF branch_status = 'SUCCESS' THEN
          RETURN 'SUCCESS';
        END IF;

        IF branch_status = 'TIMEOUT' THEN
          RAISE EXCEPTION
            USING
              ERRCODE = 'LJ003',
              MESSAGE = 'Relocation branch timed out';
        END IF;

        RAISE EXCEPTION
          USING
            ERRCODE = 'LJ002',
            MESSAGE = 'Relocation branch reached dead end';

      EXCEPTION
        WHEN SQLSTATE 'LJ003' THEN
          RETURN 'TIMEOUT';

        WHEN SQLSTATE 'LJ002' THEN
          NULL;
      END;
    END LOOP;
  END LOOP;

  IF NOT saw_blocker THEN
    IF clock_timestamp() >= _deadline THEN
      RETURN 'TIMEOUT';
    END IF;

    IF NOT championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
      _job_id,
      _match_id,
      _target_slot_id,
      effective_rest_gap
    ) THEN
      RETURN 'DEAD_END';
    END IF;

    inserted_assignment := false;

    INSERT INTO championship_bracket_preview_private.assignments (
      job_id,
      match_id,
      slot_id,
      match_number
    )
    VALUES (
      _job_id,
      _match_id,
      _target_slot_id,
      _match_number
    )
    ON CONFLICT DO NOTHING
    RETURNING true
    INTO inserted_assignment;

    IF NOT COALESCE(
      inserted_assignment,
      false
    ) THEN
      RETURN 'DEAD_END';
    END IF;

    UPDATE championship_bracket_preview_private.matches
    SET assigned = true
    WHERE job_id = _job_id
      AND id = _match_id;

    RETURN 'SUCCESS';
  END IF;

  IF clock_timestamp() >= _deadline THEN
    RETURN 'TIMEOUT';
  END IF;

  RETURN 'DEAD_END';
END;
$function$;

SET check_function_bodies = on;
