-- LAJE-126: snapshot de funções exatas v8 P-R.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.prepare_manifest_csp_candidates(_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
BEGIN
  DELETE FROM championship_bracket_preview_private.manifest_solver_candidates
  WHERE job_id = _job_id;

  INSERT INTO championship_bracket_preview_private.manifest_solver_candidates (
    job_id,
    match_id,
    slot_id,
    base_rank
  )
  SELECT
    _job_id,
    ranked.match_id,
    ranked.slot_id,
    ranked.base_rank
  FROM (
    SELECT
      matches_table.id AS match_id,
      slots_table.id AS slot_id,
      row_number() OVER (
        PARTITION BY matches_table.id
        ORDER BY
          slots_table.event_date,
          slots_table.start_at,
          slots_table.location_position,
          slots_table.court_position,
          slots_table.structural_phase_slot_number,
          slots_table.id
      )::integer AS base_rank
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.slots
      AS slots_table
      ON slots_table.job_id = _job_id
      AND slots_table.structural_phase = 'GROUP_STAGE'
      AND slots_table.structural_competition_id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
      AND championship_bracket_preview_private.is_match_slot_static_eligible(
        _job_id,
        matches_table.id,
        slots_table.id
      )
  ) AS ranked;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.probe_manifest_daily_date_feasibility(_job_id uuid, _event_date date, _rest_gap integer DEFAULT 2, _max_backtracks integer DEFAULT 800, _max_milliseconds integer DEFAULT 6000)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  started_clock TIMESTAMPTZ :=
    clock_timestamp();
  open_frame RECORD;
  parent_frame RECORD;
  candidate_record RECORD;
  next_slot_id BIGINT;
  next_depth INTEGER;
  day_total INTEGER;
  day_assigned INTEGER;
  max_assigned INTEGER := 0;
  backtracks INTEGER := 0;
  decisions INTEGER := 0;
  should_backtrack BOOLEAN;
  result_status TEXT := 'EXHAUSTED';
  elapsed_ms INTEGER;
  result JSONB;
BEGIN
  IF _rest_gap NOT IN (2, 3) THEN
    RAISE EXCEPTION
      'rest_gap inválido para probe diário: %',
      _rest_gap;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.assignments
      AS assignments_table
    JOIN championship_bracket_preview_private.slots
      AS slots_table
      ON slots_table.id =
        assignments_table.slot_id
    WHERE assignments_table.job_id = _job_id
      AND slots_table.event_date = _event_date
      AND slots_table.structural_phase =
        'GROUP_STAGE'
  ) THEN
    RETURN jsonb_build_object(
      'feasible',
      false,
      'status',
      'DATE_NOT_EMPTY',
      'date',
      _event_date
    );
  END IF;

  PERFORM championship_bracket_preview_private.cleanup_manifest_daily_probe(
    _job_id,
    _event_date,
    _rest_gap
  );

  SELECT count(*)::integer
  INTO day_total
  FROM championship_bracket_preview_private.slots
    AS slots_table
  WHERE slots_table.job_id = _job_id
    AND slots_table.event_date = _event_date
    AND slots_table.structural_phase =
      'GROUP_STAGE';

  IF day_total = 0 THEN
    RETURN jsonb_build_object(
      'feasible',
      true,
      'status',
      'NO_GROUP_SLOTS',
      'date',
      _event_date,
      'day_total',
      0
    );
  END IF;

  LOOP
    elapsed_ms :=
      (
        extract(
          epoch FROM (
            clock_timestamp()
              - started_clock
          )
        ) * 1000
      )::integer;

    IF elapsed_ms >= _max_milliseconds THEN
      result_status := 'TIMEOUT';
      EXIT;
    END IF;

    IF backtracks >= _max_backtracks THEN
      result_status := 'BACKTRACK_LIMIT';
      EXIT;
    END IF;

    SELECT count(*)::integer
    INTO day_assigned
    FROM championship_bracket_preview_private.assignments
      AS assignments_table
    JOIN championship_bracket_preview_private.slots
      AS slots_table
      ON slots_table.id =
        assignments_table.slot_id
    WHERE assignments_table.job_id = _job_id
      AND slots_table.event_date = _event_date
      AND slots_table.structural_phase =
        'GROUP_STAGE';

    max_assigned :=
      GREATEST(
        max_assigned,
        day_assigned
      );

    IF day_assigned = day_total THEN
      result_status := 'FEASIBLE';
      EXIT;
    END IF;

    should_backtrack := false;

    SELECT *
    INTO open_frame
    FROM championship_bracket_preview_private.manifest_daily_probe_frames
    WHERE job_id = _job_id
      AND event_date = _event_date
      AND rest_gap = _rest_gap
      AND chosen_match_id IS NULL
    ORDER BY depth DESC
    LIMIT 1;

    IF NOT FOUND THEN
      SELECT slots_table.id
      INTO next_slot_id
      FROM championship_bracket_preview_private.slots
        AS slots_table
      WHERE slots_table.job_id = _job_id
        AND slots_table.event_date = _event_date
        AND slots_table.structural_phase =
          'GROUP_STAGE'
        AND NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.assignments
            AS occupied_assignment
          WHERE occupied_assignment.job_id =
              _job_id
            AND occupied_assignment.slot_id =
              slots_table.id
        )
      ORDER BY
        slots_table.start_at,
        slots_table.location_position,
        slots_table.court_position,
        slots_table.cursor_position,
        slots_table.id
      LIMIT 1;

      IF next_slot_id IS NULL THEN
        should_backtrack := true;
      ELSE
        SELECT COALESCE(
          max(frames_table.depth),
          0
        ) + 1
        INTO next_depth
        FROM championship_bracket_preview_private.manifest_daily_probe_frames
          AS frames_table
        WHERE frames_table.job_id = _job_id
          AND frames_table.event_date =
            _event_date
          AND frames_table.rest_gap =
            _rest_gap;

        INSERT INTO championship_bracket_preview_private.manifest_daily_probe_frames (
          job_id,
          event_date,
          rest_gap,
          depth,
          slot_id,
          chosen_match_id
        )
        VALUES (
          _job_id,
          _event_date,
          _rest_gap,
          next_depth,
          next_slot_id,
          NULL
        );

        CONTINUE;
      END IF;
    ELSE
      SELECT candidate.*
      INTO candidate_record
      FROM championship_bracket_preview_private.resolve_manifest_daily_slot_candidate(
        _job_id,
        _event_date,
        open_frame.slot_id,
        _rest_gap
      ) AS candidate
      WHERE NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.manifest_daily_probe_tried_matches
          AS tried_match
        WHERE tried_match.job_id = _job_id
          AND tried_match.event_date =
            _event_date
          AND tried_match.rest_gap =
            _rest_gap
          AND tried_match.depth =
            open_frame.depth
          AND tried_match.slot_id =
            open_frame.slot_id
          AND tried_match.match_id =
            candidate.match_id
      )
      ORDER BY
        candidate.round_number,
        candidate.round_group_usage,
        candidate.group_day_usage,
        candidate.future_candidate_count,
        candidate.group_number,
        candidate.slot_number,
        candidate.match_id
      LIMIT 1;

      IF FOUND THEN
        INSERT INTO championship_bracket_preview_private.manifest_daily_probe_tried_matches (
          job_id,
          event_date,
          rest_gap,
          depth,
          slot_id,
          match_id
        )
        VALUES (
          _job_id,
          _event_date,
          _rest_gap,
          open_frame.depth,
          open_frame.slot_id,
          candidate_record.match_id
        )
        ON CONFLICT DO NOTHING;

        INSERT INTO championship_bracket_preview_private.assignments (
          job_id,
          match_id,
          slot_id
        )
        VALUES (
          _job_id,
          candidate_record.match_id,
          open_frame.slot_id
        );

        UPDATE championship_bracket_preview_private.matches
        SET
          assigned = true,
          applied_rest_gap = _rest_gap,
          relaxed_rest_gap_applied =
            _rest_gap = 2
        WHERE job_id = _job_id
          AND id =
            candidate_record.match_id;

        UPDATE championship_bracket_preview_private.manifest_daily_probe_frames
        SET
          chosen_match_id =
            candidate_record.match_id,
          updated_at = now()
        WHERE job_id = _job_id
          AND event_date = _event_date
          AND rest_gap = _rest_gap
          AND depth =
            open_frame.depth;

        decisions :=
          decisions + 1;

        CONTINUE;
      END IF;

      DELETE FROM championship_bracket_preview_private.manifest_daily_probe_tried_matches
      WHERE job_id = _job_id
        AND event_date = _event_date
        AND rest_gap = _rest_gap
        AND depth =
          open_frame.depth;

      DELETE FROM championship_bracket_preview_private.manifest_daily_probe_frames
      WHERE job_id = _job_id
        AND event_date = _event_date
        AND rest_gap = _rest_gap
        AND depth =
          open_frame.depth;

      should_backtrack := true;
    END IF;

    IF should_backtrack THEN
      SELECT *
      INTO parent_frame
      FROM championship_bracket_preview_private.manifest_daily_probe_frames
      WHERE job_id = _job_id
        AND event_date = _event_date
        AND rest_gap = _rest_gap
        AND chosen_match_id IS NOT NULL
      ORDER BY depth DESC
      LIMIT 1;

      IF NOT FOUND THEN
        result_status := 'EXHAUSTED';
        EXIT;
      END IF;

      DELETE FROM championship_bracket_preview_private.assignments
      WHERE job_id = _job_id
        AND match_id =
          parent_frame.chosen_match_id
        AND slot_id =
          parent_frame.slot_id;

      UPDATE championship_bracket_preview_private.matches
      SET
        assigned = false,
        applied_rest_gap = 3,
        relaxed_rest_gap_applied = false
      WHERE job_id = _job_id
        AND id =
          parent_frame.chosen_match_id;

      UPDATE championship_bracket_preview_private.manifest_daily_probe_frames
      SET
        chosen_match_id = NULL,
        updated_at = now()
      WHERE job_id = _job_id
        AND event_date = _event_date
        AND rest_gap = _rest_gap
        AND depth =
          parent_frame.depth;

      backtracks :=
        backtracks + 1;
    END IF;
  END LOOP;

  elapsed_ms :=
    (
      extract(
        epoch FROM (
          clock_timestamp()
            - started_clock
        )
      ) * 1000
    )::integer;

  result :=
    jsonb_build_object(
      'feasible',
      result_status = 'FEASIBLE',
      'status',
      result_status,
      'date',
      _event_date,
      'rest_gap',
      _rest_gap,
      'day_total',
      day_total,
      'max_assigned',
      max_assigned,
      'decisions',
      decisions,
      'backtracks',
      backtracks,
      'elapsed_ms',
      elapsed_ms
    );

  PERFORM championship_bracket_preview_private.cleanup_manifest_daily_probe(
    _job_id,
    _event_date,
    _rest_gap
  );

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.process_batch(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  job_record RECORD;
  preflight_diagnostics JSONB;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id
  FOR UPDATE;

  IF job_record.algorithm_version <> 'async-exact-v8'
    OR jsonb_typeof(
      job_record.payload -> 'structural_schedule_slots'
    ) IS DISTINCT FROM 'array'
  THEN
    RETURN championship_bracket_preview_private.process_batch_legacy_structural_v8(
      _job_id
    );
  END IF;

  IF job_record.status IN (
    'QUEUED',
    'INITIALIZING'
  ) THEN
    PERFORM championship_bracket_preview_private.initialize_job(
      _job_id
    );

    PERFORM championship_bracket_preview_private.rebuild_job_round_robin_matches(
      _job_id
    );

    PERFORM championship_bracket_preview_private.rebuild_job_slots(
      _job_id
    );

    SELECT
      championship_bracket_preview_private.resolve_v8_target_preflight(
        _job_id
      )
    INTO preflight_diagnostics;

    IF jsonb_array_length(
      preflight_diagnostics
    ) > 0 THEN
      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Validação estrutural',
        diagnostics = preflight_diagnostics,
        error_message =
          preflight_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'SCHEDULING',
      stage = 'SCHEDULING_GROUPS',
      progress_percentage = 5,
      updated_at = now()
    WHERE id = _job_id;
  END IF;

  RETURN championship_bracket_preview_private.process_manifest_group_batch(
    _job_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.process_batch_legacy_structural_v8(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  job_record RECORD;
  preflight_diagnostics JSONB;
  result JSONB;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id
  FOR UPDATE;

  IF job_record.status IN (
    'QUEUED',
    'INITIALIZING'
  ) THEN
    PERFORM
      championship_bracket_preview_private.initialize_job(
        _job_id
      );

    PERFORM
      championship_bracket_preview_private.rebuild_job_round_robin_matches(
        _job_id
      );

    PERFORM
      championship_bracket_preview_private.rebuild_job_slots(
        _job_id
      );

    SELECT
      championship_bracket_preview_private.resolve_v8_target_preflight(
        _job_id
      )
    INTO preflight_diagnostics;

    IF jsonb_array_length(
      preflight_diagnostics
    ) > 0 THEN
      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Validação estrutural',
        diagnostics = preflight_diagnostics,
        error_message =
          preflight_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    UPDATE championship_bracket_preview_private.jobs
    SET
      stage = 'SCHEDULING_GROUPS',
      updated_at = now()
    WHERE id = _job_id;
  END IF;

  result :=
    championship_bracket_preview_private.process_batch_v7(
      _job_id
    );

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.process_batch_v7(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '20s'
AS $function$
DECLARE
  started_clock TIMESTAMPTZ := clock_timestamp();
  job_record RECORD;
  slot_record RECORD;
  candidate RECORD;
  batch_slots INTEGER := 0;
  candidates INTEGER := 0;
  slot_candidates INTEGER := 0;
  produced INTEGER := 0;
  pending_count INTEGER;
  processed_count INTEGER;
  remaining_relocation_candidates INTEGER;
  relocation_result JSONB;
BEGIN
  IF NOT pg_try_advisory_xact_lock(
    hashtextextended(
      'championship-bracket-preview-global',
      0
    )
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      2
    );
  END IF;

  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id
  FOR UPDATE;

  IF job_record.status IN (
    'COMPLETED',
    'FAILED',
    'CANCELLED',
    'CONSUMED'
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      false
    );
  END IF;

  IF job_record.status IN (
    'QUEUED',
    'INITIALIZING'
  ) THEN
    PERFORM championship_bracket_preview_private.initialize_job(
      _job_id
    );

    PERFORM championship_bracket_preview_private.rebuild_job_round_robin_matches(
      _job_id
    );

    SELECT *
    INTO job_record
    FROM championship_bracket_preview_private.jobs
    WHERE id = _job_id;
  END IF;

  IF job_record.algorithm_version IN (
    'async-exact-v4',
    'async-exact-v5',
    'async-exact-v6',
    'async-exact-v7'
  )
    AND job_record.processed_slots = 0
    AND NOT EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.assignments
      WHERE job_id = _job_id
    )
  THEN
    PERFORM championship_bracket_preview_private.rebuild_job_slots(
      _job_id
    );

    SELECT *
    INTO job_record
    FROM championship_bracket_preview_private.jobs
    WHERE id = _job_id;
  END IF;

  FOR slot_record IN
    SELECT
      slots_table.*,
      slot_target.has_sport_targets,
      slot_target.planned_match_count,
      GREATEST(
        slot_target.planned_match_count
          - COALESCE(
            target_usage.assigned_match_count,
            0
          ),
        0
      ) AS remaining_target_count
    FROM championship_bracket_preview_private.slots AS slots_table

    CROSS JOIN LATERAL
      championship_bracket_preview_private.resolve_slot_sport_target(
        job_record.payload,
        slots_table.event_date,
        slots_table.court_key,
        slots_table.sport_id
      ) AS slot_target

    LEFT JOIN LATERAL (
      SELECT
        count(*)::integer AS assigned_match_count
      FROM championship_bracket_preview_private.assignments
        AS target_assignments
      JOIN championship_bracket_preview_private.slots
        AS assigned_slots
        ON assigned_slots.id =
          target_assignments.slot_id
      WHERE target_assignments.job_id = _job_id
        AND assigned_slots.event_date =
          slots_table.event_date
        AND assigned_slots.court_key =
          slots_table.court_key
        AND assigned_slots.sport_id =
          slots_table.sport_id
    ) AS target_usage
      ON true

    WHERE slots_table.job_id = _job_id
      AND slots_table.processed = false

      AND slots_table.event_date = (
        SELECT min(next_slot.event_date)
        FROM championship_bracket_preview_private.slots
          AS next_slot
        WHERE next_slot.job_id = _job_id
          AND next_slot.processed = false
      )

    ORDER BY
      slots_table.event_date,
      slots_table.start_at,
      slots_table.location_position,
      slots_table.court_position,

      CASE
        WHEN NOT slot_target.has_sport_targets
          OR slot_target.planned_match_count >
            COALESCE(
              target_usage.assigned_match_count,
              0
            )
        THEN 0
        ELSE 1
      END,

      GREATEST(
        slot_target.planned_match_count
          - COALESCE(
            target_usage.assigned_match_count,
            0
          ),
        0
      ) DESC,

      CASE
        WHEN slots_table.preferred_sport
          THEN 0
        ELSE 1
      END,

      slots_table.sport_id,
      slots_table.cursor_position

    LIMIT 20
    FOR UPDATE OF slots_table SKIP LOCKED

  LOOP
    EXIT WHEN
      clock_timestamp() - started_clock
        >= interval '5 seconds';

    batch_slots := batch_slots + 1;

    SELECT count(*)
    INTO slot_candidates
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
      AND matches_table.assigned = false
      AND competitions_table.sport_id =
        slot_record.sport_id;

    candidates :=
      candidates + slot_candidates;

    SELECT
      matches_table.*,
      competitions_table.naipe,
      competitions_table.division,
      competitions_table.competition_key,
      competitions_table.position AS competition_position,
      groups_table.group_number
    INTO candidate
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    JOIN championship_bracket_preview_private.groups
      AS groups_table
      ON groups_table.job_id = matches_table.job_id
      AND groups_table.id = matches_table.group_id
    WHERE matches_table.job_id = _job_id
      AND matches_table.assigned = false
      AND competitions_table.sport_id =
        slot_record.sport_id

      AND (
        NOT slot_record.has_sport_targets
        OR slot_record.planned_match_count > (
          SELECT count(*)
          FROM championship_bracket_preview_private.assignments
            AS target_assignments
          JOIN championship_bracket_preview_private.slots
            AS assigned_slots
            ON assigned_slots.id =
              target_assignments.slot_id
          WHERE target_assignments.job_id = _job_id
            AND assigned_slots.event_date =
              slot_record.event_date
            AND assigned_slots.court_key =
              slot_record.court_key
            AND assigned_slots.sport_id =
              slot_record.sport_id
        )
      )

      AND (
        slot_record.sequence_mode <> 'GROUP_NAIPE'
        OR slot_record.preferred_naipe IS NULL
        OR competitions_table.naipe =
          slot_record.preferred_naipe
      )

      AND public.is_championship_bracket_competition_slot_playable(
        job_record.payload,
        competitions_table.competition_key,
        slot_record.event_date,
        slot_record.start_at,
        slot_record.end_at
      )

      AND public.is_championship_bracket_team_slot_playable(
        job_record.payload,
        matches_table.home_team_id,
        competitions_table.competition_key,
        slot_record.event_date,
        slot_record.start_at,
        slot_record.end_at
      )

      AND public.is_championship_bracket_team_slot_playable(
        job_record.payload,
        matches_table.away_team_id,
        competitions_table.competition_key,
        slot_record.event_date,
        slot_record.start_at,
        slot_record.end_at
      )

      AND NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.assignments
          AS occupied_assignment
        JOIN championship_bracket_preview_private.slots
          AS occupied_slot
          ON occupied_slot.id =
            occupied_assignment.slot_id
        WHERE occupied_assignment.job_id = _job_id
          AND occupied_slot.court_key =
            slot_record.court_key
          AND occupied_slot.start_at <
            slot_record.end_at
          AND occupied_slot.end_at >
            slot_record.start_at
      )

      AND championship_bracket_preview_private.is_job_slot_within_day_bounds(
        _job_id,
        slot_record.id
      )

      AND championship_bracket_preview_private.is_match_round_order_eligible(
        _job_id,
        matches_table.id,
        slot_record.id
      )

      AND NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.assignments
          AS previous_assignment
        WHERE previous_assignment.job_id = _job_id
          AND championship_bracket_preview_private.is_match_rest_conflict(
            _job_id,
            matches_table.id,
            slot_record.id,
            previous_assignment.match_id
          )
      )

    ORDER BY
      CASE
        WHEN slot_record.preferred_naipe IS NOT NULL
          AND competitions_table.naipe
            IS DISTINCT FROM
              slot_record.preferred_naipe
        THEN 1
        ELSE 0
      END,

      CASE
        WHEN slot_record.preferred_division IS NOT NULL
          AND competitions_table.division
            IS DISTINCT FROM
              slot_record.preferred_division
        THEN 1
        ELSE 0
      END,

      matches_table.priority_weight DESC,
      competitions_table.position,
      groups_table.group_number,
      matches_table.round_number,
      matches_table.slot_number,
      least(
        matches_table.home_team_id::text,
        matches_table.away_team_id::text
      ),
      greatest(
        matches_table.home_team_id::text,
        matches_table.away_team_id::text
      )

    LIMIT 1;

    IF candidate.id IS NOT NULL THEN
      INSERT INTO championship_bracket_preview_private.assignments (
        job_id,
        match_id,
        slot_id
      )
      VALUES (
        _job_id,
        candidate.id,
        slot_record.id
      )
      ON CONFLICT DO NOTHING;

      UPDATE championship_bracket_preview_private.matches
      SET
        assigned = true,
        relocation_attempt_count = 0,
        relocation_candidate_cursor = 0,
        relocation_search_exhausted = false
      WHERE job_id = _job_id
        AND id = candidate.id;

      produced := produced + 1;
    END IF;

    UPDATE championship_bracket_preview_private.slots
    SET processed = true
    WHERE id = slot_record.id;
  END LOOP;

  SELECT count(*)
  INTO pending_count
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND assigned = false;

  SELECT count(*)
  INTO processed_count
  FROM championship_bracket_preview_private.slots
  WHERE job_id = _job_id
    AND processed;

  UPDATE championship_bracket_preview_private.jobs
  SET
    processed_slots = processed_count,

    current_processing_date = (
      SELECT max(event_date)
      FROM championship_bracket_preview_private.slots
      WHERE job_id = _job_id
        AND processed
    ),

    progress_percentage = LEAST(
      90,
      5 + (
        85
        * processed_count::numeric
        / GREATEST(total_slots, 1)
      )
    ),

    heartbeat_at = now(),
    updated_at = now()

  WHERE id = _job_id;

  INSERT INTO championship_bracket_preview_private.stage_metrics (
    job_id,
    stage,
    batch_number,
    duration_ms,
    processed_slots,
    candidates_examined,
    produced_rows
  )
  VALUES (
    _job_id,
    'SCHEDULING',
    job_record.attempt_count + 1,
    (
      EXTRACT(
        EPOCH FROM (
          clock_timestamp() - started_clock
        )
      ) * 1000
    )::integer,
    batch_slots,
    candidates,
    produced
  );

  IF pending_count = 0 THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FINALIZING',
      stage = 'Montando manifesto final',
      updated_at = now()
    WHERE id = _job_id;

    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.slots
    WHERE job_id = _job_id
      AND processed = false
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  SELECT
    pending_match.*,
    competitions_table.position AS competition_position,
    groups_table.group_number
  INTO candidate
  FROM championship_bracket_preview_private.matches
    AS pending_match
  JOIN championship_bracket_preview_private.competitions
    AS competitions_table
    ON competitions_table.id =
      pending_match.competition_id
  JOIN championship_bracket_preview_private.groups
    AS groups_table
    ON groups_table.job_id =
      pending_match.job_id
    AND groups_table.id =
      pending_match.group_id
  WHERE pending_match.job_id = _job_id
    AND pending_match.assigned = false
    AND pending_match.relocation_search_exhausted = false
  ORDER BY
    pending_match.relocation_attempt_count,
    pending_match.priority_weight DESC,
    competitions_table.position,
    groups_table.group_number,
    pending_match.round_number,
    pending_match.slot_number,
    least(
      pending_match.home_team_id::text,
      pending_match.away_team_id::text
    ),
    greatest(
      pending_match.home_team_id::text,
      pending_match.away_team_id::text
    )
  LIMIT 1;

  IF FOUND THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      stage = format(
        'Reorganizando grade: %s jogo(s) pendente(s), busca a partir do candidato %s',
        pending_count,
        candidate.relocation_candidate_cursor + 1
      ),
      progress_percentage = 90,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    relocation_result :=
      championship_bracket_preview_private.try_relocate_for_match_search(
        _job_id,
        candidate.id,
        100
      );

    IF COALESCE(
      (relocation_result ->> 'assigned')::boolean,
      false
    ) THEN
      produced := produced + 1;

      SELECT count(*)
      INTO pending_count
      FROM championship_bracket_preview_private.matches
      WHERE job_id = _job_id
        AND assigned = false;

      IF pending_count = 0 THEN
        UPDATE championship_bracket_preview_private.jobs
        SET
          status = 'FINALIZING',
          stage = 'Montando manifesto final após reorganização',
          progress_percentage = 90,
          heartbeat_at = now(),
          updated_at = now()
        WHERE id = _job_id;

        RETURN jsonb_build_object(
          'continue',
          true,
          'delay',
          0
        );
      END IF;

      UPDATE championship_bracket_preview_private.jobs
      SET
        stage = format(
          'Reorganizando grade: %s jogo(s) pendente(s)',
          pending_count
        ),
        progress_percentage = 90,
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        true,
        'delay',
        0
      );
    END IF;

    IF COALESCE(
      (relocation_result ->> 'progressed')::boolean,
      false
    )
      AND NOT COALESCE(
        (relocation_result ->> 'exhausted')::boolean,
        false
      )
    THEN
      UPDATE championship_bracket_preview_private.jobs
      SET
        stage = format(
          'Reorganizando grade: %s jogo(s) pendente(s), busca avançou até o candidato %s',
          pending_count,
          COALESCE(
            relocation_result ->> 'candidate_cursor',
            candidate.relocation_candidate_cursor::text
          )
        ),
        progress_percentage = 90,
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        true,
        'delay',
        0
      );
    END IF;
  END IF;

  SELECT count(*)
  INTO remaining_relocation_candidates
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND assigned = false
    AND relocation_search_exhausted = false;

  SELECT count(*)
  INTO pending_count
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND assigned = false;

  IF pending_count = 0 THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FINALIZING',
      stage = 'Montando manifesto final após reorganização',
      progress_percentage = 90,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  IF remaining_relocation_candidates > 0 THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      stage = format(
        'Reorganizando grade: %s jogo(s) pendente(s)',
        pending_count
      ),
      progress_percentage = 90,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  UPDATE championship_bracket_preview_private.jobs
  SET
    status = 'FAILED',
    stage = 'Falha',
    progress_percentage = 100,

    error_message = format(
      'Não foi possível encaixar %s jogo(s) após esgotar os destinos estruturais disponíveis e as cadeias de reorganização analisadas.',
      pending_count
    ),

    diagnostics =
      championship_bracket_preview_private.build_unassigned_match_diagnostics(
        _job_id
      ),

    completed_at = now(),
    expires_at = now() + interval '24 hours',
    heartbeat_at = now(),
    updated_at = now()

  WHERE id = _job_id;

  RETURN jsonb_build_object(
    'continue',
    false
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.process_job(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '20s'
AS $function$
DECLARE
  job_record RECORD;
  result JSONB;
  structural_diagnostics JSONB;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id;

  IF job_record.id IS NULL THEN
    RETURN jsonb_build_object(
      'continue',
      false
    );
  END IF;

  IF job_record.algorithm_version <> 'async-exact-v8'
    OR jsonb_typeof(
      job_record.payload -> 'structural_schedule_slots'
    ) IS DISTINCT FROM 'array'
  THEN
    RETURN championship_bracket_preview_private.process_job_legacy_structural_v8(
      _job_id
    );
  END IF;

  IF job_record.status IN (
    'COMPLETED',
    'FAILED',
    'CANCELLED',
    'CONSUMED'
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      false
    );
  END IF;

  IF job_record.status = 'FINALIZING' THEN
    PERFORM championship_bracket_preview_private.assign_job_match_numbers(
      _job_id
    );

    structural_diagnostics :=
      championship_bracket_preview_private.apply_v8_structural_knockout_schedule(
        _job_id
      );

    IF jsonb_array_length(
      structural_diagnostics
    ) > 0 THEN
      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Validação do manifesto eliminatório',
        diagnostics = structural_diagnostics,
        error_message =
          structural_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FINALIZING',
      stage = 'FINALIZING',
      progress_percentage = 98,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    PERFORM championship_bracket_preview_private.finalize_job(
      _job_id
    );

    RETURN jsonb_build_object(
      'continue',
      false
    );
  END IF;

  result :=
    championship_bracket_preview_private.process_batch(
      _job_id
    );

  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id;

  IF job_record.status = 'FINALIZING' THEN
    PERFORM championship_bracket_preview_private.assign_job_match_numbers(
      _job_id
    );

    structural_diagnostics :=
      championship_bracket_preview_private.apply_v8_structural_knockout_schedule(
        _job_id
      );

    IF jsonb_array_length(
      structural_diagnostics
    ) > 0 THEN
      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Validação do manifesto eliminatório',
        diagnostics = structural_diagnostics,
        error_message =
          structural_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FINALIZING',
      stage = 'FINALIZING',
      progress_percentage = 98,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    PERFORM championship_bracket_preview_private.finalize_job(
      _job_id
    );

    RETURN jsonb_build_object(
      'continue',
      false
    );
  END IF;

  RETURN result;

EXCEPTION
  WHEN OTHERS THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      attempt_count = attempt_count + 1,
      heartbeat_at = now(),
      updated_at = now(),
      error_message = SQLERRM,
      status =
        CASE
          WHEN attempt_count + 1 >= 5
            THEN 'FAILED'
          ELSE status
        END,
      stage =
        CASE
          WHEN attempt_count + 1 >= 5
            THEN 'Falha após cinco tentativas'
          ELSE stage
        END,
      completed_at =
        CASE
          WHEN attempt_count + 1 >= 5
            THEN COALESCE(
              completed_at,
              now()
            )
          ELSE completed_at
        END,
      expires_at =
        CASE
          WHEN attempt_count + 1 >= 5
            THEN now() + interval '24 hours'
          ELSE expires_at
        END
    WHERE id = _job_id;

    RETURN jsonb_build_object(
      'continue',
      (
        SELECT jobs_table.attempt_count < 5
        FROM championship_bracket_preview_private.jobs
          AS jobs_table
        WHERE jobs_table.id = _job_id
      ),
      'delay',
      LEAST(
        60,
        power(
          2,
          (
            SELECT jobs_table.attempt_count
            FROM championship_bracket_preview_private.jobs
              AS jobs_table
            WHERE jobs_table.id = _job_id
          )
        )::integer
      )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.process_job_legacy_structural_v8(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '20s'
AS $function$
DECLARE
  job_record RECORD;
  result JSONB;
  job_diagnostics JSONB;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id;

  IF job_record.id IS NULL THEN
    RETURN jsonb_build_object(
      'continue',
      false
    );
  END IF;

  IF job_record.algorithm_version
    <> 'async-exact-v8'
  THEN
    IF job_record.status = 'FINALIZING' THEN
      PERFORM
        championship_bracket_preview_private.finalize_job_v7(
          _job_id
        );

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    RETURN
      championship_bracket_preview_private.process_batch_v7(
        _job_id
      );
  END IF;

  IF job_record.status IN (
    'COMPLETED',
    'FAILED',
    'CANCELLED',
    'CONSUMED'
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      false
    );
  END IF;

  IF job_record.stage = 'COMPACTING_GROUPS' THEN
    result :=
      championship_bracket_preview_private.compact_v8_schedule_batch(
        _job_id
      );

    IF COALESCE(
      (result ->> 'done')::boolean,
      false
    ) THEN
      SELECT
        championship_bracket_preview_private.resolve_v8_target_completion_diagnostics(
          _job_id
        )
      INTO job_diagnostics;

      IF jsonb_array_length(
        job_diagnostics
      ) > 0 THEN
        UPDATE championship_bracket_preview_private.jobs
        SET
          status = 'FAILED',
          stage = 'Validação da grade',
          diagnostics = job_diagnostics,
          error_message =
            job_diagnostics -> 0 ->> 'message',
          completed_at = now(),
          updated_at = now()
        WHERE id = _job_id;

        RETURN jsonb_build_object(
          'continue',
          false
        );
      END IF;

      PERFORM
        championship_bracket_preview_private.assign_job_match_numbers(
          _job_id
        );

      PERFORM
        championship_bracket_preview_private.create_v8_knockout_matches(
          _job_id
        );

      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'SCHEDULING',
        stage = 'SCHEDULING_KNOCKOUT',
        updated_at = now()
      WHERE id = _job_id;
    END IF;

    RETURN jsonb_build_object(
      'continue',
      true
    );
  END IF;

  IF job_record.stage = 'SCHEDULING_KNOCKOUT' THEN
    result :=
      championship_bracket_preview_private.schedule_v8_knockout_batch(
        _job_id
      );

    job_diagnostics :=
      COALESCE(
        result -> 'diagnostics',
        '[]'::jsonb
      );

    IF jsonb_array_length(
      job_diagnostics
    ) > 0 THEN
      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Programação eliminatória',
        diagnostics = job_diagnostics,
        error_message =
          job_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    IF COALESCE(
      (result ->> 'done')::boolean,
      false
    ) THEN
      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FINALIZING',
        stage = 'FINALIZING',
        updated_at = now()
      WHERE id = _job_id;
    END IF;

    RETURN jsonb_build_object(
      'continue',
      true
    );
  END IF;

  IF job_record.status = 'FINALIZING'
    OR job_record.stage = 'FINALIZING'
  THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FINALIZING',
      stage = 'FINALIZING',
      updated_at = now()
    WHERE id = _job_id;

    PERFORM
      championship_bracket_preview_private.finalize_job(
        _job_id
      );

    RETURN jsonb_build_object(
      'continue',
      false
    );
  END IF;

  result :=
    championship_bracket_preview_private.process_batch(
      _job_id
    );

  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id;

  IF job_record.status = 'FINALIZING' THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'SCHEDULING',
      stage = 'COMPACTING_GROUPS',
      updated_at = now()
    WHERE id = _job_id;

    INSERT INTO championship_bracket_preview_private.job_events (
      job_id,
      event_type,
      stage,
      details,
      occurred_at
    )
    VALUES (
      _job_id,
      'STAGE_CHANGED',
      'COMPACTING_GROUPS',
      jsonb_build_object(
        'pending_matches', (
          SELECT count(*)
          FROM championship_bracket_preview_private.matches matches_table
          WHERE matches_table.job_id = _job_id
            AND NOT matches_table.assigned
        )
      ),
      clock_timestamp()
    )
    ON CONFLICT (job_id, event_type, group_match_id, knockout_match_id)
    DO NOTHING;

    RETURN jsonb_build_object(
      'continue',
      true
    );
  END IF;

  RETURN result;

EXCEPTION
  WHEN OTHERS THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      attempt_count = attempt_count + 1,
      heartbeat_at = now(),
      updated_at = now(),
      error_message = SQLERRM,
      status =
        CASE
          WHEN attempt_count + 1 >= 5
            THEN 'FAILED'
          ELSE status
        END,
      stage =
        CASE
          WHEN attempt_count + 1 >= 5
            THEN 'Falha após cinco tentativas'
          ELSE stage
        END,
      expires_at =
        CASE
          WHEN attempt_count + 1 >= 5
            THEN now() + interval '24 hours'
          ELSE expires_at
        END
    WHERE id = _job_id;

    RETURN jsonb_build_object(
      'continue',
      (
        SELECT jobs_table.attempt_count < 5
        FROM championship_bracket_preview_private.jobs
          AS jobs_table
        WHERE jobs_table.id = _job_id
      ),
      'delay',
      LEAST(
        60,
        power(
          2,
          (
            SELECT jobs_table.attempt_count
            FROM championship_bracket_preview_private.jobs
              AS jobs_table
            WHERE jobs_table.id = _job_id
          )
        )::integer
      )
    );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.process_manifest_group_batch(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '20s'
AS $function$
DECLARE
  started_clock TIMESTAMPTZ :=
    clock_timestamp();
  state_record RECORD;
  open_frame RECORD;
  parent_frame RECORD;
  candidate_record RECORD;
  next_date DATE;
  next_slot_id BIGINT;
  next_depth INTEGER;
  current_day_total INTEGER;
  current_day_assigned INTEGER;
  total_matches INTEGER;
  assigned_matches INTEGER;
  pending_matches INTEGER;
  operations_count INTEGER := 0;
  zero_candidate_diagnostics JSONB;
  forward_diagnostics JSONB;
  failure_diagnostics JSONB;
  should_backtrack BOOLEAN;
  strict_budget_exhausted BOOLEAN;
  relaxed_budget_exhausted BOOLEAN;
BEGIN
  IF NOT pg_try_advisory_xact_lock(
    hashtextextended(
      'championship-bracket-preview-global',
      0
    )
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      2
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.manifest_daily_solver_state
    WHERE job_id = _job_id
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.assignments
      WHERE job_id = _job_id
    ) THEN
      RAISE EXCEPTION
        'O scheduler diário não pode iniciar sobre atribuições preexistentes.';
    END IF;

    PERFORM championship_bracket_preview_private.prepare_manifest_csp_candidates(
      _job_id
    );

    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'code',
          'STRUCTURAL_MATCH_WITHOUT_STATIC_CANDIDATE',
          'message',
          format(
            'O confronto %s não possui nenhum slot GROUP_STAGE estruturalmente elegível.',
            matches_table.logical_key
          ),
          'logical_key',
          matches_table.logical_key,
          'match_id',
          matches_table.id,
          'competition_key',
          competitions_table.competition_key
        )
        ORDER BY
          matches_table.logical_key
      ),
      '[]'::jsonb
    )
    INTO zero_candidate_diagnostics
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
      AND NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.manifest_solver_candidates
          AS candidate
        WHERE candidate.job_id = _job_id
          AND candidate.match_id =
            matches_table.id
      );

    IF jsonb_array_length(
      zero_candidate_diagnostics
    ) > 0 THEN
      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Validação dos candidatos estruturais',
        progress_percentage = 100,
        diagnostics =
          zero_candidate_diagnostics,
        error_message =
          zero_candidate_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        expires_at =
          now() + interval '24 hours',
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    SELECT min(slots_table.event_date)
    INTO next_date
    FROM championship_bracket_preview_private.slots
      AS slots_table
    WHERE slots_table.job_id = _job_id
      AND slots_table.structural_phase =
        'GROUP_STAGE';

    INSERT INTO championship_bracket_preview_private.manifest_daily_solver_state (
      job_id,
      processing_date,
      rest_gap,
      phase,
      completed_days,
      decisions_count,
      total_backtracks,
      day_backtracks,
      day_started_at,
      last_forward_diagnostics
    )
    VALUES (
      _job_id,
      next_date,
      3,
      'SEARCHING_DAY',
      0,
      0,
      0,
      0,
      now(),
      '[]'::jsonb
    );
  END IF;

  LOOP
    EXIT WHEN
      clock_timestamp() - started_clock >=
        interval '5 seconds';

    EXIT WHEN operations_count >= 100;

    SELECT *
    INTO state_record
    FROM championship_bracket_preview_private.manifest_daily_solver_state
    WHERE job_id = _job_id
    FOR UPDATE;

    IF state_record.processing_date IS NULL THEN
      EXIT;
    END IF;

    strict_budget_exhausted :=
      state_record.rest_gap = 3
      AND (
        state_record.day_backtracks >= 120
        OR clock_timestamp()
          - state_record.day_started_at >=
            interval '30 seconds'
      );

    relaxed_budget_exhausted :=
      state_record.rest_gap = 2
      AND (
        state_record.day_backtracks >= 1200
        OR clock_timestamp()
          - state_record.day_started_at >=
            interval '90 seconds'
      );

    IF strict_budget_exhausted THEN
      PERFORM championship_bracket_preview_private.reset_manifest_daily_day_search(
        _job_id,
        state_record.processing_date,
        2
      );

      UPDATE championship_bracket_preview_private.jobs
      SET
        stage = format(
          'Programando %s — descanso adaptativo 2',
          to_char(
            state_record.processing_date,
            'DD/MM/YYYY'
          )
        ),
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      operations_count :=
        operations_count + 1;

      CONTINUE;
    END IF;

    IF relaxed_budget_exhausted THEN
      failure_diagnostics :=
        CASE
          WHEN jsonb_array_length(
            state_record.last_forward_diagnostics
          ) > 0
          THEN
            jsonb_build_array(
              jsonb_build_object(
                'code',
                'DAILY_STRUCTURAL_SEARCH_LIMIT_REACHED',
                'message',
                format(
                  'O scheduler diário atingiu o limite de busca em %s com descanso adaptativo 2.',
                  to_char(
                    state_record.processing_date,
                    'DD/MM/YYYY'
                  )
                ),
                'date',
                state_record.processing_date,
                'rest_gap',
                state_record.rest_gap,
                'day_backtracks',
                state_record.day_backtracks
              )
            )
            || state_record.last_forward_diagnostics
          ELSE
            jsonb_build_array(
              jsonb_build_object(
                'code',
                'DAILY_STRUCTURAL_SEARCH_LIMIT_REACHED',
                'message',
                format(
                  'O scheduler diário atingiu o limite de busca em %s com descanso adaptativo 2.',
                  to_char(
                    state_record.processing_date,
                    'DD/MM/YYYY'
                  )
                ),
                'date',
                state_record.processing_date,
                'rest_gap',
                state_record.rest_gap,
                'day_backtracks',
                state_record.day_backtracks
              )
            )
        END;

      UPDATE championship_bracket_preview_private.manifest_daily_solver_state
      SET
        phase = 'FAILED',
        updated_at = now()
      WHERE job_id = _job_id;

      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Falha na programação diária',
        progress_percentage = 100,
        diagnostics =
          failure_diagnostics,
        error_message =
          failure_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        expires_at =
          now() + interval '24 hours',
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    SELECT count(*)::integer
    INTO current_day_total
    FROM championship_bracket_preview_private.slots
      AS slots_table
    WHERE slots_table.job_id = _job_id
      AND slots_table.event_date =
        state_record.processing_date
      AND slots_table.structural_phase =
        'GROUP_STAGE';

    SELECT count(*)::integer
    INTO current_day_assigned
    FROM championship_bracket_preview_private.assignments
      AS assignments_table
    JOIN championship_bracket_preview_private.slots
      AS slots_table
      ON slots_table.id =
        assignments_table.slot_id
    WHERE assignments_table.job_id = _job_id
      AND slots_table.event_date =
        state_record.processing_date
      AND slots_table.structural_phase =
        'GROUP_STAGE';

    should_backtrack := false;

    IF current_day_assigned =
      current_day_total
    THEN
      SELECT championship_bracket_preview_private.resolve_manifest_daily_future_diagnostics(
        _job_id,
        state_record.processing_date
      )
      INTO forward_diagnostics;

      IF jsonb_array_length(
        forward_diagnostics
      ) = 0 THEN
        UPDATE championship_bracket_preview_private.slots
        SET processed = true
        WHERE job_id = _job_id
          AND event_date =
            state_record.processing_date
          AND structural_phase =
            'GROUP_STAGE';

        DELETE FROM championship_bracket_preview_private.manifest_daily_solver_tried_matches
        WHERE job_id = _job_id
          AND event_date =
            state_record.processing_date;

        DELETE FROM championship_bracket_preview_private.manifest_daily_solver_frames
        WHERE job_id = _job_id
          AND event_date =
            state_record.processing_date;

        SELECT min(slots_table.event_date)
        INTO next_date
        FROM championship_bracket_preview_private.slots
          AS slots_table
        WHERE slots_table.job_id = _job_id
          AND slots_table.structural_phase =
            'GROUP_STAGE'
          AND NOT slots_table.processed
          AND slots_table.event_date >
            state_record.processing_date;

        IF next_date IS NULL THEN
          UPDATE championship_bracket_preview_private.manifest_daily_solver_state
          SET
            processing_date = NULL,
            phase = 'COMPLETE',
            completed_days =
              completed_days + 1,
            last_forward_diagnostics =
              '[]'::jsonb,
            updated_at = now()
          WHERE job_id = _job_id;

          UPDATE championship_bracket_preview_private.jobs
          SET
            status = 'FINALIZING',
            stage = 'Materializando mata-mata estrutural',
            processed_slots = total_slots,
            progress_percentage = 95,
            heartbeat_at = now(),
            updated_at = now()
          WHERE id = _job_id;

          RETURN jsonb_build_object(
            'continue',
            true,
            'delay',
            0
          );
        END IF;

        UPDATE championship_bracket_preview_private.manifest_daily_solver_state
        SET
          processing_date = next_date,
          rest_gap = 3,
          phase = 'SEARCHING_DAY',
          completed_days =
            completed_days + 1,
          day_backtracks = 0,
          day_started_at = now(),
          last_forward_diagnostics =
            '[]'::jsonb,
          updated_at = now()
        WHERE job_id = _job_id;

        UPDATE championship_bracket_preview_private.jobs
        SET
          stage = format(
            'Programando %s — descanso 3',
            to_char(
              next_date,
              'DD/MM/YYYY'
            )
          ),
          current_processing_date =
            next_date,
          heartbeat_at = now(),
          updated_at = now()
        WHERE id = _job_id;

        operations_count :=
          operations_count + 1;

        CONTINUE;
      END IF;

      UPDATE championship_bracket_preview_private.manifest_daily_solver_state
      SET
        last_forward_diagnostics =
          forward_diagnostics,
        updated_at = now()
      WHERE job_id = _job_id;

      should_backtrack := true;
    END IF;

    IF NOT should_backtrack THEN
      SELECT *
      INTO open_frame
      FROM championship_bracket_preview_private.manifest_daily_solver_frames
      WHERE job_id = _job_id
        AND event_date =
          state_record.processing_date
        AND rest_gap =
          state_record.rest_gap
        AND chosen_match_id IS NULL
      ORDER BY depth DESC
      LIMIT 1
      FOR UPDATE;

      IF NOT FOUND THEN
        SELECT slots_table.id
        INTO next_slot_id
        FROM championship_bracket_preview_private.slots
          AS slots_table
        WHERE slots_table.job_id = _job_id
          AND slots_table.event_date =
            state_record.processing_date
          AND slots_table.structural_phase =
            'GROUP_STAGE'
          AND NOT EXISTS (
            SELECT 1
            FROM championship_bracket_preview_private.assignments
              AS occupied_assignment
            WHERE occupied_assignment.job_id =
              _job_id
              AND occupied_assignment.slot_id =
                slots_table.id
          )
        ORDER BY
          slots_table.start_at,
          slots_table.location_position,
          slots_table.court_position,
          slots_table.cursor_position,
          slots_table.id
        LIMIT 1;

        IF next_slot_id IS NOT NULL THEN
          SELECT COALESCE(
            max(frames_table.depth),
            0
          ) + 1
          INTO next_depth
          FROM championship_bracket_preview_private.manifest_daily_solver_frames
            AS frames_table
          WHERE frames_table.job_id = _job_id
            AND frames_table.event_date =
              state_record.processing_date
            AND frames_table.rest_gap =
              state_record.rest_gap;

          INSERT INTO championship_bracket_preview_private.manifest_daily_solver_frames (
            job_id,
            event_date,
            rest_gap,
            depth,
            slot_id,
            chosen_match_id
          )
          VALUES (
            _job_id,
            state_record.processing_date,
            state_record.rest_gap,
            next_depth,
            next_slot_id,
            NULL
          );

          operations_count :=
            operations_count + 1;

          CONTINUE;
        END IF;

        should_backtrack := true;
      ELSE
        SELECT candidate.*
        INTO candidate_record
        FROM championship_bracket_preview_private.resolve_manifest_daily_slot_candidate(
          _job_id,
          state_record.processing_date,
          open_frame.slot_id,
          state_record.rest_gap
        ) AS candidate
        WHERE NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.manifest_daily_solver_tried_matches
            AS tried_match
          WHERE tried_match.job_id =
              _job_id
            AND tried_match.event_date =
              state_record.processing_date
            AND tried_match.rest_gap =
              state_record.rest_gap
            AND tried_match.depth =
              open_frame.depth
            AND tried_match.slot_id =
              open_frame.slot_id
            AND tried_match.match_id =
              candidate.match_id
        )
        ORDER BY
          candidate.round_number,
          candidate.round_group_usage,
          candidate.group_day_usage,
          candidate.future_candidate_count,
          candidate.group_number,
          candidate.slot_number,
          candidate.match_id
        LIMIT 1;

        IF FOUND THEN
          INSERT INTO championship_bracket_preview_private.manifest_daily_solver_tried_matches (
            job_id,
            event_date,
            rest_gap,
            depth,
            slot_id,
            match_id
          )
          VALUES (
            _job_id,
            state_record.processing_date,
            state_record.rest_gap,
            open_frame.depth,
            open_frame.slot_id,
            candidate_record.match_id
          )
          ON CONFLICT DO NOTHING;

          INSERT INTO championship_bracket_preview_private.assignments (
            job_id,
            match_id,
            slot_id
          )
          VALUES (
            _job_id,
            candidate_record.match_id,
            open_frame.slot_id
          );

          UPDATE championship_bracket_preview_private.matches
          SET
            assigned = true,
            applied_rest_gap =
              state_record.rest_gap,
            relaxed_rest_gap_applied =
              state_record.rest_gap = 2
          WHERE job_id = _job_id
            AND id =
              candidate_record.match_id;

          UPDATE championship_bracket_preview_private.manifest_daily_solver_frames
          SET
            chosen_match_id =
              candidate_record.match_id,
            updated_at = now()
          WHERE job_id = _job_id
            AND event_date =
              state_record.processing_date
            AND rest_gap =
              state_record.rest_gap
            AND depth =
              open_frame.depth;

          UPDATE championship_bracket_preview_private.manifest_daily_solver_state
          SET
            decisions_count =
              decisions_count + 1,
            last_forward_diagnostics =
              '[]'::jsonb,
            updated_at = now()
          WHERE job_id = _job_id;

          operations_count :=
            operations_count + 1;

          CONTINUE;
        END IF;

        DELETE FROM championship_bracket_preview_private.manifest_daily_solver_tried_matches
        WHERE job_id = _job_id
          AND event_date =
            state_record.processing_date
          AND rest_gap =
            state_record.rest_gap
          AND depth =
            open_frame.depth;

        DELETE FROM championship_bracket_preview_private.manifest_daily_solver_frames
        WHERE job_id = _job_id
          AND event_date =
            state_record.processing_date
          AND rest_gap =
            state_record.rest_gap
          AND depth =
            open_frame.depth;

        should_backtrack := true;
      END IF;
    END IF;

    IF should_backtrack THEN
      SELECT *
      INTO parent_frame
      FROM championship_bracket_preview_private.manifest_daily_solver_frames
      WHERE job_id = _job_id
        AND event_date =
          state_record.processing_date
        AND rest_gap =
          state_record.rest_gap
        AND chosen_match_id IS NOT NULL
      ORDER BY depth DESC
      LIMIT 1
      FOR UPDATE;

      IF FOUND THEN
        DELETE FROM championship_bracket_preview_private.assignments
        WHERE job_id = _job_id
          AND match_id =
            parent_frame.chosen_match_id;

        UPDATE championship_bracket_preview_private.matches
        SET
          assigned = false,
          applied_rest_gap = 3,
          relaxed_rest_gap_applied = false
        WHERE job_id = _job_id
          AND id =
            parent_frame.chosen_match_id;

        UPDATE championship_bracket_preview_private.manifest_daily_solver_frames
        SET
          chosen_match_id = NULL,
          updated_at = now()
        WHERE job_id = _job_id
          AND event_date =
            state_record.processing_date
          AND rest_gap =
            state_record.rest_gap
          AND depth =
            parent_frame.depth;

        UPDATE championship_bracket_preview_private.manifest_daily_solver_state
        SET
          total_backtracks =
            total_backtracks + 1,
          day_backtracks =
            day_backtracks + 1,
          updated_at = now()
        WHERE job_id = _job_id;

        operations_count :=
          operations_count + 1;

        CONTINUE;
      END IF;

      IF state_record.rest_gap = 3 THEN
        PERFORM championship_bracket_preview_private.reset_manifest_daily_day_search(
          _job_id,
          state_record.processing_date,
          2
        );

        UPDATE championship_bracket_preview_private.jobs
        SET
          stage = format(
            'Programando %s — descanso adaptativo 2',
            to_char(
              state_record.processing_date,
              'DD/MM/YYYY'
            )
          ),
          heartbeat_at = now(),
          updated_at = now()
        WHERE id = _job_id;

        operations_count :=
          operations_count + 1;

        CONTINUE;
      END IF;

      failure_diagnostics :=
        CASE
          WHEN jsonb_array_length(
            state_record.last_forward_diagnostics
          ) > 0
          THEN
            jsonb_build_array(
              jsonb_build_object(
                'code',
                'DAILY_STRUCTURAL_NO_SOLUTION',
                'message',
                format(
                  'Não foi encontrada distribuição válida para %s mesmo com descanso adaptativo 2.',
                  to_char(
                    state_record.processing_date,
                    'DD/MM/YYYY'
                  )
                ),
                'date',
                state_record.processing_date,
                'rest_gap',
                state_record.rest_gap
              )
            )
            || state_record.last_forward_diagnostics
          ELSE
            jsonb_build_array(
              jsonb_build_object(
                'code',
                'DAILY_STRUCTURAL_NO_SOLUTION',
                'message',
                format(
                  'Não foi encontrada distribuição válida para %s mesmo com descanso adaptativo 2.',
                  to_char(
                    state_record.processing_date,
                    'DD/MM/YYYY'
                  )
                ),
                'date',
                state_record.processing_date,
                'rest_gap',
                state_record.rest_gap
              )
            )
        END;

      UPDATE championship_bracket_preview_private.manifest_daily_solver_state
      SET
        phase = 'FAILED',
        updated_at = now()
      WHERE job_id = _job_id;

      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Falha na programação diária',
        progress_percentage = 100,
        diagnostics =
          failure_diagnostics,
        error_message =
          failure_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        expires_at =
          now() + interval '24 hours',
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;
  END LOOP;

  SELECT count(*)::integer
  INTO total_matches
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id;

  SELECT count(*)::integer
  INTO assigned_matches
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND assigned;

  pending_matches :=
    total_matches - assigned_matches;

  SELECT *
  INTO state_record
  FROM championship_bracket_preview_private.manifest_daily_solver_state
  WHERE job_id = _job_id;

  SELECT count(*)::integer
  INTO current_day_total
  FROM championship_bracket_preview_private.slots
  WHERE job_id = _job_id
    AND event_date =
      state_record.processing_date
    AND structural_phase =
      'GROUP_STAGE';

  SELECT count(*)::integer
  INTO current_day_assigned
  FROM championship_bracket_preview_private.assignments
    AS assignments_table
  JOIN championship_bracket_preview_private.slots
    AS slots_table
    ON slots_table.id =
      assignments_table.slot_id
  WHERE assignments_table.job_id = _job_id
    AND slots_table.event_date =
      state_record.processing_date
    AND slots_table.structural_phase =
      'GROUP_STAGE';

  UPDATE championship_bracket_preview_private.jobs
  SET
    processed_slots =
      assigned_matches,
    current_processing_date =
      state_record.processing_date,
    progress_percentage =
      CASE
        WHEN pending_matches = 0
          THEN 95
        ELSE LEAST(
          90,
          5 + (
            85
            * assigned_matches::numeric
            / GREATEST(
              total_matches,
              1
            )
          )
        )
      END,
    stage =
      CASE
        WHEN pending_matches = 0
          THEN 'Materializando mata-mata estrutural'
        ELSE format(
          'Programando %s — %s de %s jogos do dia, %s de %s grupos no total, descanso %s',
          to_char(
            state_record.processing_date,
            'DD/MM/YYYY'
          ),
          current_day_assigned,
          current_day_total,
          assigned_matches,
          total_matches,
          state_record.rest_gap
        )
      END,
    heartbeat_at = now(),
    updated_at = now()
  WHERE id = _job_id;

  RETURN jsonb_build_object(
    'continue',
    true,
    'delay',
    0,
    'date',
    state_record.processing_date,
    'day_assigned',
    current_day_assigned,
    'day_total',
    current_day_total,
    'assigned',
    assigned_matches,
    'pending',
    pending_matches,
    'rest_gap',
    state_record.rest_gap,
    'day_backtracks',
    state_record.day_backtracks,
    'completed_days',
    state_record.completed_days
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.process_manifest_group_batch_cached_csp_v8(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '20s'
AS $function$
DECLARE
  started_clock TIMESTAMPTZ :=
    clock_timestamp();
  state_record RECORD;
  open_frame RECORD;
  parent_frame RECORD;
  candidate_record RECORD;
  next_match_record RECORD;
  next_naipe public.match_naipe;
  next_depth INTEGER;
  pending_count INTEGER;
  assigned_count INTEGER;
  total_count INTEGER;
  candidate_count INTEGER;
  operations_count INTEGER := 0;
  zero_candidate_diagnostics JSONB;
  failure_diagnostics JSONB;
  should_backtrack BOOLEAN;
  strict_budget_exhausted BOOLEAN;
  relaxed_budget_exhausted BOOLEAN;
BEGIN
  IF NOT pg_try_advisory_xact_lock(
    hashtextextended(
      'championship-bracket-preview-global',
      0
    )
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      2
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.manifest_solver_state
    WHERE job_id = _job_id
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.assignments
      WHERE job_id = _job_id
    ) THEN
      RAISE EXCEPTION
        'O CSP estrutural não pode iniciar sobre atribuições preexistentes.';
    END IF;

    PERFORM championship_bracket_preview_private.prepare_manifest_csp_candidates(
      _job_id
    );

    SELECT COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'code',
          'STRUCTURAL_MATCH_WITHOUT_STATIC_CANDIDATE',
          'message',
          format(
            'O confronto %s não possui nenhum slot GROUP_STAGE estruturalmente elegível.',
            matches_table.logical_key
          ),
          'logical_key',
          matches_table.logical_key,
          'match_id',
          matches_table.id,
          'competition_key',
          competitions_table.competition_key
        )
        ORDER BY matches_table.logical_key
      ),
      '[]'::jsonb
    )
    INTO zero_candidate_diagnostics
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
      AND NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.manifest_solver_candidates
          AS candidate
        WHERE candidate.job_id = _job_id
          AND candidate.match_id =
            matches_table.id
      );

    IF jsonb_array_length(
      zero_candidate_diagnostics
    ) > 0 THEN
      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Validação dos candidatos estruturais',
        progress_percentage = 100,
        diagnostics = zero_candidate_diagnostics,
        error_message =
          zero_candidate_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        expires_at =
          now() + interval '24 hours',
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    SELECT competitions_table.naipe
    INTO next_naipe
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
    ORDER BY
      CASE competitions_table.naipe
        WHEN 'FEMININO'::public.match_naipe THEN 1
        WHEN 'MASCULINO'::public.match_naipe THEN 2
        ELSE 3
      END,
      competitions_table.naipe::text
    LIMIT 1;

    INSERT INTO championship_bracket_preview_private.manifest_solver_state (
      job_id,
      current_naipe,
      rest_gap,
      decisions_count,
      backtracks_count,
      phase,
      phase_started_at,
      phase_backtracks
    )
    VALUES (
      _job_id,
      next_naipe,
      3,
      0,
      0,
      'SEARCHING',
      now(),
      0
    );
  END IF;

  LOOP
    EXIT WHEN
      clock_timestamp() - started_clock >=
        interval '5 seconds';

    EXIT WHEN operations_count >= 80;

    SELECT *
    INTO state_record
    FROM championship_bracket_preview_private.manifest_solver_state
    WHERE job_id = _job_id
    FOR UPDATE;

    IF state_record.current_naipe IS NULL THEN
      EXIT;
    END IF;

    strict_budget_exhausted :=
      state_record.rest_gap = 3
      AND (
        state_record.phase_backtracks >= 200
        OR clock_timestamp()
          - state_record.phase_started_at
          >= interval '60 seconds'
      );

    relaxed_budget_exhausted :=
      state_record.rest_gap = 2
      AND (
        state_record.phase_backtracks >= 5000
        OR clock_timestamp()
          - state_record.phase_started_at
          >= interval '5 minutes'
      );

    IF strict_budget_exhausted THEN
      PERFORM championship_bracket_preview_private.reset_manifest_csp_naipe_search(
        _job_id,
        state_record.current_naipe,
        2
      );

      UPDATE championship_bracket_preview_private.jobs
      SET
        stage = format(
          'Otimizando grade estrutural: %s — descanso adaptativo 2',
          state_record.current_naipe
        ),
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      operations_count :=
        operations_count + 1;

      CONTINUE;
    END IF;

    IF relaxed_budget_exhausted THEN
      failure_diagnostics :=
        jsonb_build_array(
          jsonb_build_object(
            'code',
            'STRUCTURAL_CSP_SEARCH_LIMIT_REACHED',
            'message',
            format(
              'O solver atingiu o limite de busca para o naipe %s mesmo com descanso adaptativo 2 entre modalidades diferentes.',
              state_record.current_naipe
            ),
            'naipe',
            state_record.current_naipe,
            'rest_gap',
            state_record.rest_gap,
            'phase_backtracks',
            state_record.phase_backtracks,
            'elapsed_seconds',
            extract(
              epoch FROM (
                clock_timestamp()
                  - state_record.phase_started_at
              )
            )::integer
          )
        );

      UPDATE championship_bracket_preview_private.manifest_solver_state
      SET
        phase = 'FAILED',
        updated_at = now()
      WHERE job_id = _job_id;

      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Limite da otimização estrutural',
        progress_percentage = 100,
        diagnostics = failure_diagnostics,
        error_message =
          failure_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        expires_at =
          now() + interval '24 hours',
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    SELECT count(*)
    INTO pending_count
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
      AND NOT matches_table.assigned
      AND competitions_table.naipe =
        state_record.current_naipe;

    IF pending_count = 0 THEN
      DELETE FROM championship_bracket_preview_private.manifest_solver_tried_slots
      WHERE job_id = _job_id
        AND naipe =
          state_record.current_naipe;

      DELETE FROM championship_bracket_preview_private.manifest_solver_frames
      WHERE job_id = _job_id
        AND naipe =
          state_record.current_naipe;

      SELECT competitions_table.naipe
      INTO next_naipe
      FROM championship_bracket_preview_private.matches
        AS matches_table
      JOIN championship_bracket_preview_private.competitions
        AS competitions_table
        ON competitions_table.id =
          matches_table.competition_id
      WHERE matches_table.job_id = _job_id
        AND NOT matches_table.assigned
      ORDER BY
        CASE competitions_table.naipe
          WHEN 'FEMININO'::public.match_naipe THEN 1
          WHEN 'MASCULINO'::public.match_naipe THEN 2
          ELSE 3
        END,
        competitions_table.naipe::text
      LIMIT 1;

      IF next_naipe IS NULL THEN
        UPDATE championship_bracket_preview_private.manifest_solver_state
        SET
          current_naipe = NULL,
          phase = 'COMPLETE',
          updated_at = now()
        WHERE job_id = _job_id;

        EXIT;
      END IF;

      UPDATE championship_bracket_preview_private.manifest_solver_state
      SET
        current_naipe = next_naipe,
        rest_gap = 3,
        phase = 'SEARCHING',
        phase_started_at = now(),
        phase_backtracks = 0,
        updated_at = now()
      WHERE job_id = _job_id;

      UPDATE championship_bracket_preview_private.jobs
      SET
        stage = format(
          'Otimizando grade estrutural: %s — descanso 3',
          next_naipe
        ),
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      operations_count :=
        operations_count + 1;

      CONTINUE;
    END IF;

    should_backtrack := false;

    SELECT *
    INTO open_frame
    FROM championship_bracket_preview_private.manifest_solver_frames
    WHERE job_id = _job_id
      AND naipe =
        state_record.current_naipe
      AND rest_gap =
        state_record.rest_gap
      AND chosen_slot_id IS NULL
    ORDER BY depth DESC
    LIMIT 1
    FOR UPDATE;

    IF NOT FOUND THEN
      SELECT *
      INTO next_match_record
      FROM championship_bracket_preview_private.resolve_manifest_csp_cached_next_match(
        _job_id,
        state_record.current_naipe,
        state_record.rest_gap
      );

      IF FOUND THEN
        SELECT COALESCE(
          max(depth),
          0
        ) + 1
        INTO next_depth
        FROM championship_bracket_preview_private.manifest_solver_frames
        WHERE job_id = _job_id
          AND naipe =
            state_record.current_naipe
          AND rest_gap =
            state_record.rest_gap;

        INSERT INTO championship_bracket_preview_private.manifest_solver_frames (
          job_id,
          naipe,
          rest_gap,
          depth,
          match_id,
          chosen_slot_id
        )
        VALUES (
          _job_id,
          state_record.current_naipe,
          state_record.rest_gap,
          next_depth,
          next_match_record.match_id,
          NULL
        );

        operations_count :=
          operations_count + 1;

        CONTINUE;
      END IF;

      should_backtrack := true;
    ELSE
      SELECT
        candidate.slot_id,
        candidate.base_rank
      INTO candidate_record
      FROM championship_bracket_preview_private.manifest_solver_candidates
        AS candidate
      WHERE candidate.job_id = _job_id
        AND candidate.match_id =
          open_frame.match_id
        AND NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.manifest_solver_tried_slots
            AS tried
          WHERE tried.job_id = _job_id
            AND tried.naipe =
              state_record.current_naipe
            AND tried.rest_gap =
              state_record.rest_gap
            AND tried.depth =
              open_frame.depth
            AND tried.match_id =
              open_frame.match_id
            AND tried.slot_id =
              candidate.slot_id
        )
        AND championship_bracket_preview_private.is_manifest_csp_dynamic_candidate_eligible(
          _job_id,
          open_frame.match_id,
          candidate.slot_id,
          state_record.rest_gap
        )
      ORDER BY
        candidate.base_rank,
        candidate.slot_id
      LIMIT 1;

      IF FOUND THEN
        INSERT INTO championship_bracket_preview_private.manifest_solver_tried_slots (
          job_id,
          naipe,
          rest_gap,
          depth,
          match_id,
          slot_id
        )
        VALUES (
          _job_id,
          state_record.current_naipe,
          state_record.rest_gap,
          open_frame.depth,
          open_frame.match_id,
          candidate_record.slot_id
        )
        ON CONFLICT DO NOTHING;

        INSERT INTO championship_bracket_preview_private.assignments (
          job_id,
          match_id,
          slot_id
        )
        VALUES (
          _job_id,
          open_frame.match_id,
          candidate_record.slot_id
        );

        UPDATE championship_bracket_preview_private.matches
        SET assigned = true
        WHERE job_id = _job_id
          AND id =
            open_frame.match_id;

        UPDATE championship_bracket_preview_private.manifest_solver_frames
        SET
          chosen_slot_id =
            candidate_record.slot_id,
          updated_at = now()
        WHERE job_id = _job_id
          AND naipe =
            state_record.current_naipe
          AND rest_gap =
            state_record.rest_gap
          AND depth =
            open_frame.depth;

        UPDATE championship_bracket_preview_private.manifest_solver_state
        SET
          decisions_count =
            decisions_count + 1,
          updated_at = now()
        WHERE job_id = _job_id;

        operations_count :=
          operations_count + 1;

        CONTINUE;
      END IF;

      should_backtrack := true;

      DELETE FROM championship_bracket_preview_private.manifest_solver_tried_slots
      WHERE job_id = _job_id
        AND naipe =
          state_record.current_naipe
        AND rest_gap =
          state_record.rest_gap
        AND depth =
          open_frame.depth;

      DELETE FROM championship_bracket_preview_private.manifest_solver_frames
      WHERE job_id = _job_id
        AND naipe =
          state_record.current_naipe
        AND rest_gap =
          state_record.rest_gap
        AND depth =
          open_frame.depth;
    END IF;

    IF should_backtrack THEN
      SELECT *
      INTO parent_frame
      FROM championship_bracket_preview_private.manifest_solver_frames
      WHERE job_id = _job_id
        AND naipe =
          state_record.current_naipe
        AND rest_gap =
          state_record.rest_gap
        AND chosen_slot_id IS NOT NULL
      ORDER BY depth DESC
      LIMIT 1
      FOR UPDATE;

      IF FOUND THEN
        DELETE FROM championship_bracket_preview_private.assignments
        WHERE job_id = _job_id
          AND match_id =
            parent_frame.match_id;

        UPDATE championship_bracket_preview_private.matches
        SET assigned = false
        WHERE job_id = _job_id
          AND id =
            parent_frame.match_id;

        UPDATE championship_bracket_preview_private.manifest_solver_frames
        SET
          chosen_slot_id = NULL,
          updated_at = now()
        WHERE job_id = _job_id
          AND naipe =
            state_record.current_naipe
          AND rest_gap =
            state_record.rest_gap
          AND depth =
            parent_frame.depth;

        UPDATE championship_bracket_preview_private.manifest_solver_state
        SET
          backtracks_count =
            backtracks_count + 1,
          phase_backtracks =
            phase_backtracks + 1,
          updated_at = now()
        WHERE job_id = _job_id;

        operations_count :=
          operations_count + 1;

        CONTINUE;
      END IF;

      IF state_record.rest_gap = 3 THEN
        PERFORM championship_bracket_preview_private.reset_manifest_csp_naipe_search(
          _job_id,
          state_record.current_naipe,
          2
        );

        UPDATE championship_bracket_preview_private.jobs
        SET
          stage = format(
            'Otimizando grade estrutural: %s — descanso adaptativo 2',
            state_record.current_naipe
          ),
          heartbeat_at = now(),
          updated_at = now()
        WHERE id = _job_id;

        operations_count :=
          operations_count + 1;

        CONTINUE;
      END IF;

      failure_diagnostics :=
        jsonb_build_array(
          jsonb_build_object(
            'code',
            'STRUCTURAL_CSP_NO_BRANCH_AVAILABLE',
            'message',
            format(
              'O solver esgotou os ramos disponíveis para o naipe %s com descanso adaptativo 2.',
              state_record.current_naipe
            ),
            'naipe',
            state_record.current_naipe,
            'rest_gap',
            state_record.rest_gap
          )
        );

      UPDATE championship_bracket_preview_private.manifest_solver_state
      SET
        phase = 'FAILED',
        updated_at = now()
      WHERE job_id = _job_id;

      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Falha na otimização estrutural',
        progress_percentage = 100,
        diagnostics = failure_diagnostics,
        error_message =
          failure_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        expires_at =
          now() + interval '24 hours',
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;
  END LOOP;

  SELECT count(*)
  INTO assigned_count
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND assigned;

  SELECT count(*)
  INTO total_count
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id;

  pending_count :=
    total_count - assigned_count;

  SELECT *
  INTO state_record
  FROM championship_bracket_preview_private.manifest_solver_state
  WHERE job_id = _job_id;

  UPDATE championship_bracket_preview_private.jobs
  SET
    processed_slots = assigned_count,
    progress_percentage =
      CASE
        WHEN pending_count = 0
          THEN 95
        ELSE LEAST(
          90,
          5 + (
            85
            * assigned_count::numeric
            / GREATEST(
              total_count,
              1
            )
          )
        )
      END,
    stage =
      CASE
        WHEN pending_count = 0
          THEN 'Materializando mata-mata estrutural'
        ELSE format(
          'Otimizando grade estrutural: %s — %s de %s jogos, descanso %s',
          state_record.current_naipe,
          assigned_count,
          total_count,
          state_record.rest_gap
        )
      END,
    heartbeat_at = now(),
    updated_at = now()
  WHERE id = _job_id;

  IF pending_count = 0 THEN
    UPDATE championship_bracket_preview_private.slots
    SET processed = true
    WHERE job_id = _job_id
      AND structural_phase =
        'GROUP_STAGE';

    UPDATE championship_bracket_preview_private.manifest_solver_state
    SET
      current_naipe = NULL,
      phase = 'COMPLETE',
      updated_at = now()
    WHERE job_id = _job_id;

    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FINALIZING',
      stage = 'Materializando mata-mata estrutural',
      processed_slots = total_slots,
      progress_percentage = 95,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  SELECT count(*)
  INTO candidate_count
  FROM championship_bracket_preview_private.manifest_solver_candidates
  WHERE job_id = _job_id;

  RETURN jsonb_build_object(
    'continue',
    true,
    'delay',
    0,
    'assigned',
    assigned_count,
    'pending',
    pending_count,
    'cached_candidates',
    candidate_count,
    'rest_gap',
    state_record.rest_gap,
    'phase_backtracks',
    state_record.phase_backtracks
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.process_manifest_group_batch_greedy_v8(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '20s'
AS $function$
DECLARE
  started_clock TIMESTAMPTZ := clock_timestamp();
  job_record RECORD;
  slot_record RECORD;
  candidate RECORD;
  pending_count INTEGER;
  processed_count INTEGER;
  remaining_relocation_candidates INTEGER;
  relocation_result JSONB;
BEGIN
  IF NOT pg_try_advisory_xact_lock(
    hashtextextended(
      'championship-bracket-preview-global',
      0
    )
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      2
    );
  END IF;

  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id
  FOR UPDATE;

  IF job_record.status IN (
    'COMPLETED',
    'FAILED',
    'CANCELLED',
    'CONSUMED'
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      false
    );
  END IF;

  FOR slot_record IN
    SELECT slots_table.*
    FROM championship_bracket_preview_private.slots
      AS slots_table
    WHERE slots_table.job_id = _job_id
      AND slots_table.structural_phase =
        'GROUP_STAGE'
      AND NOT slots_table.processed
      AND slots_table.event_date = (
        SELECT min(next_slot.event_date)
        FROM championship_bracket_preview_private.slots
          AS next_slot
        WHERE next_slot.job_id = _job_id
          AND next_slot.structural_phase =
            'GROUP_STAGE'
          AND NOT next_slot.processed
      )
    ORDER BY
      slots_table.event_date,
      slots_table.start_at,
      slots_table.location_position,
      slots_table.court_position,
      slots_table.cursor_position
    LIMIT 20
    FOR UPDATE OF slots_table SKIP LOCKED
  LOOP
    EXIT WHEN
      clock_timestamp() - started_clock
        >= interval '5 seconds';

    SELECT
      matches_table.*,
      competitions_table.position
        AS competition_position,
      groups_table.group_number
    INTO candidate
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    JOIN championship_bracket_preview_private.groups
      AS groups_table
      ON groups_table.job_id =
        matches_table.job_id
      AND groups_table.id =
        matches_table.group_id
    WHERE matches_table.job_id = _job_id
      AND NOT matches_table.assigned
      AND matches_table.competition_id =
        slot_record.structural_competition_id
      AND championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
        _job_id,
        matches_table.id,
        slot_record.id,
        3
      )
    ORDER BY
      matches_table.priority_weight DESC,
      groups_table.group_number,
      matches_table.round_number,
      matches_table.slot_number,
      least(
        matches_table.home_team_id::text,
        matches_table.away_team_id::text
      ),
      greatest(
        matches_table.home_team_id::text,
        matches_table.away_team_id::text
      )
    LIMIT 1;

    IF candidate.id IS NOT NULL THEN
      INSERT INTO championship_bracket_preview_private.assignments (
        job_id,
        match_id,
        slot_id
      )
      VALUES (
        _job_id,
        candidate.id,
        slot_record.id
      )
      ON CONFLICT DO NOTHING;

      IF EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.assignments
        WHERE job_id = _job_id
          AND match_id = candidate.id
          AND slot_id = slot_record.id
      ) THEN
        UPDATE championship_bracket_preview_private.matches
        SET
          assigned = true,
          relocation_attempt_count = 0,
          relocation_candidate_cursor = 0,
          relocation_search_exhausted = false
        WHERE job_id = _job_id
          AND id = candidate.id;
      END IF;
    END IF;

    UPDATE championship_bracket_preview_private.slots
    SET processed = true
    WHERE id = slot_record.id;
  END LOOP;

  SELECT count(*)
  INTO pending_count
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND NOT assigned;

  SELECT count(*)
  INTO processed_count
  FROM championship_bracket_preview_private.slots
  WHERE job_id = _job_id
    AND structural_phase = 'GROUP_STAGE'
    AND processed;

  UPDATE championship_bracket_preview_private.jobs
  SET
    processed_slots = processed_count,
    current_processing_date = (
      SELECT max(event_date)
      FROM championship_bracket_preview_private.slots
      WHERE job_id = _job_id
        AND structural_phase = 'GROUP_STAGE'
        AND processed
    ),
    progress_percentage = LEAST(
      90,
      5 + (
        85
        * processed_count::numeric
        / GREATEST(total_slots, 1)
      )
    ),
    heartbeat_at = now(),
    updated_at = now()
  WHERE id = _job_id;

  IF pending_count = 0 THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FINALIZING',
      stage = 'Materializando mata-mata estrutural',
      progress_percentage = 95,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.slots
    WHERE job_id = _job_id
      AND structural_phase = 'GROUP_STAGE'
      AND NOT processed
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  SELECT
    pending_match.*,
    competitions_table.position
      AS competition_position,
    groups_table.group_number
  INTO candidate
  FROM championship_bracket_preview_private.matches
    AS pending_match
  JOIN championship_bracket_preview_private.competitions
    AS competitions_table
    ON competitions_table.id =
      pending_match.competition_id
  JOIN championship_bracket_preview_private.groups
    AS groups_table
    ON groups_table.job_id =
      pending_match.job_id
    AND groups_table.id =
      pending_match.group_id
  WHERE pending_match.job_id = _job_id
    AND NOT pending_match.assigned
    AND NOT pending_match.relocation_search_exhausted
  ORDER BY
    pending_match.relocation_attempt_count,
    pending_match.priority_weight DESC,
    competitions_table.position,
    groups_table.group_number,
    pending_match.round_number,
    pending_match.slot_number
  LIMIT 1;

  IF FOUND THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      stage = format(
        'Reorganizando slots estruturais: %s jogo(s) pendente(s)',
        pending_count
      ),
      progress_percentage = 90,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    relocation_result :=
      championship_bracket_preview_private.try_relocate_for_match_search(
        _job_id,
        candidate.id,
        100
      );

    IF COALESCE(
      (relocation_result ->> 'assigned')::boolean,
      false
    ) THEN
      SELECT count(*)
      INTO pending_count
      FROM championship_bracket_preview_private.matches
      WHERE job_id = _job_id
        AND NOT assigned;

      IF pending_count = 0 THEN
        UPDATE championship_bracket_preview_private.jobs
        SET
          status = 'FINALIZING',
          stage = 'Materializando mata-mata estrutural',
          progress_percentage = 95,
          heartbeat_at = now(),
          updated_at = now()
        WHERE id = _job_id;

        RETURN jsonb_build_object(
          'continue',
          true,
          'delay',
          0
        );
      END IF;

      RETURN jsonb_build_object(
        'continue',
        true,
        'delay',
        0
      );
    END IF;

    IF COALESCE(
      (relocation_result ->> 'progressed')::boolean,
      false
    )
      AND NOT COALESCE(
        (relocation_result ->> 'exhausted')::boolean,
        false
      )
    THEN
      RETURN jsonb_build_object(
        'continue',
        true,
        'delay',
        0
      );
    END IF;
  END IF;

  SELECT count(*)
  INTO remaining_relocation_candidates
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND NOT assigned
    AND NOT relocation_search_exhausted;

  SELECT count(*)
  INTO pending_count
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND NOT assigned;

  IF pending_count = 0 THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FINALIZING',
      stage = 'Materializando mata-mata estrutural',
      progress_percentage = 95,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  IF remaining_relocation_candidates > 0 THEN
    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  UPDATE championship_bracket_preview_private.jobs
  SET
    status = 'FAILED',
    stage = 'Falha',
    progress_percentage = 100,
    error_message = format(
      'Não foi possível distribuir %s jogo(s) dentro dos slots GROUP_STAGE autoritativos do manifesto estrutural.',
      pending_count
    ),
    diagnostics =
      championship_bracket_preview_private.build_unassigned_match_diagnostics(
        _job_id
      ),
    completed_at = now(),
    expires_at = now() + interval '24 hours',
    heartbeat_at = now(),
    updated_at = now()
  WHERE id = _job_id;

  RETURN jsonb_build_object(
    'continue',
    false
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.process_manifest_group_batch_unbounded_csp_v8(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '20s'
AS $function$
DECLARE
  started_clock TIMESTAMPTZ :=
    clock_timestamp();
  state_record RECORD;
  next_match_record RECORD;
  candidate_record RECORD;
  decision_record RECORD;
  next_naipe public.match_naipe;
  current_depth INTEGER;
  assigned_count INTEGER;
  total_count INTEGER;
  pending_count INTEGER;
  operations_count INTEGER := 0;
  did_backtrack BOOLEAN;
  search_exhausted BOOLEAN;
  failure_diagnostics JSONB;
BEGIN
  IF NOT pg_try_advisory_xact_lock(
    hashtextextended(
      'championship-bracket-preview-global',
      0
    )
  ) THEN
    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      2
    );
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.manifest_solver_state
    WHERE job_id = _job_id
  ) THEN
    IF EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.assignments
      WHERE job_id = _job_id
    ) THEN
      RAISE EXCEPTION
        'O solver estrutural CSP não pode ser inicializado sobre atribuições preexistentes.';
    END IF;

    SELECT competitions_table.naipe
    INTO next_naipe
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
    ORDER BY
      competitions_table.naipe::text
    LIMIT 1;

    INSERT INTO championship_bracket_preview_private.manifest_solver_state (
      job_id,
      current_naipe,
      rest_gap,
      decisions_count,
      backtracks_count,
      phase
    )
    VALUES (
      _job_id,
      next_naipe,
      3,
      0,
      0,
      'SEARCHING'
    );
  END IF;

  LOOP
    EXIT WHEN
      clock_timestamp() - started_clock >=
        interval '5 seconds';

    EXIT WHEN operations_count >= 100;

    SELECT *
    INTO state_record
    FROM championship_bracket_preview_private.manifest_solver_state
    WHERE job_id = _job_id
    FOR UPDATE;

    IF state_record.current_naipe IS NULL THEN
      EXIT;
    END IF;

    SELECT count(*)
    INTO pending_count
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
      AND NOT matches_table.assigned
      AND competitions_table.naipe =
        state_record.current_naipe;

    IF pending_count = 0 THEN
      SELECT competitions_table.naipe
      INTO next_naipe
      FROM championship_bracket_preview_private.matches
        AS matches_table
      JOIN championship_bracket_preview_private.competitions
        AS competitions_table
        ON competitions_table.id =
          matches_table.competition_id
      WHERE matches_table.job_id = _job_id
        AND NOT matches_table.assigned
      ORDER BY
        competitions_table.naipe::text
      LIMIT 1;

      IF next_naipe IS NULL THEN
        UPDATE championship_bracket_preview_private.manifest_solver_state
        SET
          current_naipe = NULL,
          phase = 'COMPLETE',
          updated_at = now()
        WHERE job_id = _job_id;

        EXIT;
      END IF;

      UPDATE championship_bracket_preview_private.manifest_solver_state
      SET
        current_naipe = next_naipe,
        rest_gap = 3,
        phase = 'SEARCHING',
        updated_at = now()
      WHERE job_id = _job_id;

      UPDATE championship_bracket_preview_private.jobs
      SET
        stage = format(
          'Otimizando grade estrutural: %s, descanso 3',
          next_naipe
        ),
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      operations_count :=
        operations_count + 1;

      CONTINUE;
    END IF;

    SELECT *
    INTO next_match_record
    FROM championship_bracket_preview_private.resolve_manifest_csp_next_match(
      _job_id,
      state_record.current_naipe,
      state_record.rest_gap
    );

    IF FOUND
      AND next_match_record.option_count > 0
    THEN
      SELECT *
      INTO candidate_record
      FROM championship_bracket_preview_private.resolve_manifest_csp_candidate_slots(
        _job_id,
        next_match_record.match_id,
        state_record.rest_gap
      )
      ORDER BY candidate_rank
      LIMIT 1;

      IF candidate_record.slot_id IS NOT NULL THEN
        SELECT COALESCE(
          max(decisions_table.depth),
          0
        ) + 1
        INTO current_depth
        FROM championship_bracket_preview_private.manifest_solver_decisions
          AS decisions_table
        WHERE decisions_table.job_id = _job_id
          AND decisions_table.naipe =
            state_record.current_naipe
          AND decisions_table.rest_gap =
            state_record.rest_gap;

        INSERT INTO championship_bracket_preview_private.assignments (
          job_id,
          match_id,
          slot_id
        )
        VALUES (
          _job_id,
          next_match_record.match_id,
          candidate_record.slot_id
        );

        UPDATE championship_bracket_preview_private.matches
        SET
          assigned = true
        WHERE job_id = _job_id
          AND id =
            next_match_record.match_id;

        INSERT INTO championship_bracket_preview_private.manifest_solver_decisions (
          job_id,
          naipe,
          rest_gap,
          depth,
          match_id,
          slot_id,
          candidate_rank,
          pressure
        )
        VALUES (
          _job_id,
          state_record.current_naipe,
          state_record.rest_gap,
          current_depth,
          next_match_record.match_id,
          candidate_record.slot_id,
          candidate_record.candidate_rank,
          candidate_record.pressure
        );

        UPDATE championship_bracket_preview_private.manifest_solver_state
        SET
          decisions_count =
            decisions_count + 1,
          updated_at = now()
        WHERE job_id = _job_id;

        operations_count :=
          operations_count + 1;

        CONTINUE;
      END IF;
    END IF;

    did_backtrack := false;
    search_exhausted := false;

    LOOP
      SELECT *
      INTO decision_record
      FROM championship_bracket_preview_private.manifest_solver_decisions
      WHERE job_id = _job_id
        AND naipe =
          state_record.current_naipe
        AND rest_gap =
          state_record.rest_gap
      ORDER BY depth DESC
      LIMIT 1
      FOR UPDATE;

      IF NOT FOUND THEN
        search_exhausted := true;
        EXIT;
      END IF;

      DELETE FROM championship_bracket_preview_private.assignments
      WHERE job_id = _job_id
        AND match_id =
          decision_record.match_id;

      UPDATE championship_bracket_preview_private.matches
      SET
        assigned = false
      WHERE job_id = _job_id
        AND id =
          decision_record.match_id;

      DELETE FROM championship_bracket_preview_private.manifest_solver_decisions
      WHERE job_id = _job_id
        AND naipe =
          decision_record.naipe
        AND depth =
          decision_record.depth;

      UPDATE championship_bracket_preview_private.manifest_solver_state
      SET
        backtracks_count =
          backtracks_count + 1,
        updated_at = now()
      WHERE job_id = _job_id;

      SELECT *
      INTO candidate_record
      FROM championship_bracket_preview_private.resolve_manifest_csp_candidate_slots(
        _job_id,
        decision_record.match_id,
        state_record.rest_gap
      )
      WHERE candidate_rank >
        decision_record.candidate_rank
      ORDER BY candidate_rank
      LIMIT 1;

      IF FOUND THEN
        INSERT INTO championship_bracket_preview_private.assignments (
          job_id,
          match_id,
          slot_id
        )
        VALUES (
          _job_id,
          decision_record.match_id,
          candidate_record.slot_id
        );

        UPDATE championship_bracket_preview_private.matches
        SET
          assigned = true
        WHERE job_id = _job_id
          AND id =
            decision_record.match_id;

        INSERT INTO championship_bracket_preview_private.manifest_solver_decisions (
          job_id,
          naipe,
          rest_gap,
          depth,
          match_id,
          slot_id,
          candidate_rank,
          pressure
        )
        VALUES (
          _job_id,
          state_record.current_naipe,
          state_record.rest_gap,
          decision_record.depth,
          decision_record.match_id,
          candidate_record.slot_id,
          candidate_record.candidate_rank,
          candidate_record.pressure
        );

        UPDATE championship_bracket_preview_private.manifest_solver_state
        SET
          decisions_count =
            decisions_count + 1,
          updated_at = now()
        WHERE job_id = _job_id;

        did_backtrack := true;
        operations_count :=
          operations_count + 1;

        EXIT;
      END IF;

      operations_count :=
        operations_count + 1;

      EXIT WHEN
        clock_timestamp() - started_clock >=
          interval '5 seconds';

      EXIT WHEN operations_count >= 100;
    END LOOP;

    IF did_backtrack THEN
      CONTINUE;
    END IF;

    IF search_exhausted THEN
      IF state_record.rest_gap = 3 THEN
        DELETE FROM championship_bracket_preview_private.assignments
          AS assignments_table
        USING championship_bracket_preview_private.matches
          AS matches_table,
          championship_bracket_preview_private.competitions
          AS competitions_table
        WHERE assignments_table.job_id = _job_id
          AND matches_table.id =
            assignments_table.match_id
          AND competitions_table.id =
            matches_table.competition_id
          AND competitions_table.naipe =
            state_record.current_naipe;

        UPDATE championship_bracket_preview_private.matches
          AS matches_table
        SET
          assigned = false
        FROM championship_bracket_preview_private.competitions
          AS competitions_table
        WHERE matches_table.job_id = _job_id
          AND competitions_table.id =
            matches_table.competition_id
          AND competitions_table.naipe =
            state_record.current_naipe;

        DELETE FROM championship_bracket_preview_private.manifest_solver_decisions
        WHERE job_id = _job_id
          AND naipe =
            state_record.current_naipe;

        UPDATE championship_bracket_preview_private.manifest_solver_state
        SET
          rest_gap = 2,
          phase = 'SEARCHING_RELAXED',
          updated_at = now()
        WHERE job_id = _job_id;

        UPDATE championship_bracket_preview_private.jobs
        SET
          stage = format(
            'Otimizando grade estrutural: %s, descanso adaptativo 2',
            state_record.current_naipe
          ),
          heartbeat_at = now(),
          updated_at = now()
        WHERE id = _job_id;

        operations_count :=
          operations_count + 1;

        CONTINUE;
      END IF;

      failure_diagnostics :=
        jsonb_build_array(
          jsonb_build_object(
            'code',
            'STRUCTURAL_CSP_NO_SOLUTION',
            'message',
            format(
              'Não existe distribuição válida dos slots estruturais para o naipe %s nem com descanso adaptativo 2 entre modalidades diferentes.',
              state_record.current_naipe
            ),
            'naipe',
            state_record.current_naipe,
            'rest_gap',
            state_record.rest_gap
          )
        )
        || championship_bracket_preview_private.build_unassigned_match_diagnostics(
          _job_id
        );

      UPDATE championship_bracket_preview_private.manifest_solver_state
      SET
        phase = 'FAILED',
        updated_at = now()
      WHERE job_id = _job_id;

      UPDATE championship_bracket_preview_private.jobs
      SET
        status = 'FAILED',
        stage = 'Falha na otimização estrutural',
        progress_percentage = 100,
        diagnostics = failure_diagnostics,
        error_message =
          failure_diagnostics -> 0 ->> 'message',
        completed_at = now(),
        expires_at =
          now() + interval '24 hours',
        heartbeat_at = now(),
        updated_at = now()
      WHERE id = _job_id;

      RETURN jsonb_build_object(
        'continue',
        false
      );
    END IF;

    EXIT;
  END LOOP;

  SELECT count(*)
  INTO assigned_count
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND assigned;

  SELECT count(*)
  INTO total_count
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id;

  SELECT count(*)
  INTO pending_count
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id
    AND NOT assigned;

  SELECT *
  INTO state_record
  FROM championship_bracket_preview_private.manifest_solver_state
  WHERE job_id = _job_id;

  UPDATE championship_bracket_preview_private.jobs
  SET
    processed_slots = assigned_count,
    progress_percentage =
      CASE
        WHEN pending_count = 0
          THEN 95
        ELSE LEAST(
          90,
          5 + (
            85
            * assigned_count::numeric
            / GREATEST(
              total_count,
              1
            )
          )
        )
      END,
    stage =
      CASE
        WHEN pending_count = 0
          THEN 'Materializando mata-mata estrutural'
        ELSE format(
          'Otimizando grade estrutural: %s — %s de %s jogos, descanso %s',
          state_record.current_naipe,
          assigned_count,
          total_count,
          state_record.rest_gap
        )
      END,
    heartbeat_at = now(),
    updated_at = now()
  WHERE id = _job_id;

  IF pending_count = 0 THEN
    UPDATE championship_bracket_preview_private.slots
    SET processed = true
    WHERE job_id = _job_id
      AND structural_phase =
        'GROUP_STAGE';

    UPDATE championship_bracket_preview_private.manifest_solver_state
    SET
      current_naipe = NULL,
      phase = 'COMPLETE',
      updated_at = now()
    WHERE job_id = _job_id;

    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FINALIZING',
      stage = 'Materializando mata-mata estrutural',
      processed_slots = total_slots,
      progress_percentage = 95,
      heartbeat_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    RETURN jsonb_build_object(
      'continue',
      true,
      'delay',
      0
    );
  END IF;

  RETURN jsonb_build_object(
    'continue',
    true,
    'delay',
    0
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.rebuild_job_round_robin_matches(_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  competition_record RECORD;
  group_record RECORD;
  group_team_ids UUID[];
  group_team_count INTEGER;
  group_even_size INTEGER;
  round_index INTEGER;
  match_index INTEGER;
  home_index INTEGER;
  away_index INTEGER;
  home_position INTEGER;
  away_position INTEGER;
  home_team_id UUID;
  away_team_id UUID;
  competition_slot_number INTEGER;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.assignments
    WHERE job_id = _job_id
  ) THEN
    RAISE EXCEPTION
      'Os confrontos não podem ser reconstruídos depois do início das atribuições.';
  END IF;

  DELETE FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id;

  FOR competition_record IN
    SELECT competitions_table.id
    FROM championship_bracket_preview_private.competitions AS competitions_table
    WHERE competitions_table.job_id = _job_id
    ORDER BY competitions_table.position, competitions_table.id
  LOOP
    competition_slot_number := 1;

    FOR group_record IN
      SELECT groups_table.id, groups_table.group_number
      FROM championship_bracket_preview_private.groups AS groups_table
      WHERE groups_table.job_id = _job_id
        AND groups_table.competition_id = competition_record.id
      ORDER BY groups_table.group_number, groups_table.id
    LOOP
      SELECT array_agg(group_teams_table.team_id ORDER BY group_teams_table.position)
      INTO group_team_ids
      FROM championship_bracket_preview_private.group_teams AS group_teams_table
      WHERE group_teams_table.job_id = _job_id
        AND group_teams_table.group_id = group_record.id;

      group_team_count := COALESCE(cardinality(group_team_ids), 0);

      IF group_team_count < 2 THEN
        RAISE EXCEPTION
          'Grupo % inválido: é necessário no mínimo duas atléticas.',
          group_record.group_number;
      END IF;

      group_even_size := group_team_count;
      IF group_even_size % 2 <> 0 THEN
        group_even_size := group_even_size + 1;
      END IF;

      FOR round_index IN 0 .. group_even_size - 2 LOOP
        FOR match_index IN 0 .. (group_even_size / 2) - 1 LOOP
          IF match_index = 0 THEN
            home_index := 0;
          ELSE
            home_index :=
              (round_index + match_index - 1) % (group_even_size - 1) + 1;
          END IF;

          away_index :=
            (group_even_size - 1 - match_index + round_index - 1)
              % (group_even_size - 1) + 1;
          home_position := home_index + 1;
          away_position := away_index + 1;

          IF home_position <= group_team_count
            AND away_position <= group_team_count
          THEN
            home_team_id := group_team_ids[home_position];
            away_team_id := group_team_ids[away_position];

            IF match_index = 0 AND round_index % 2 <> 0 THEN
              home_team_id := group_team_ids[away_position];
              away_team_id := group_team_ids[home_position];
            END IF;

            IF home_team_id IS NOT NULL
              AND away_team_id IS NOT NULL
              AND home_team_id <> away_team_id
            THEN
              INSERT INTO championship_bracket_preview_private.matches (
                id,
                job_id,
                competition_id,
                group_id,
                logical_key,
                round_number,
                slot_number,
                home_team_id,
                away_team_id,
                priority_weight
              ) VALUES (
                gen_random_uuid(),
                _job_id,
                competition_record.id,
                group_record.id,
                format(
                  '%s:%s:%s',
                  group_record.id,
                  least(home_position, away_position),
                  greatest(home_position, away_position)
                ),
                round_index + 1,
                competition_slot_number,
                home_team_id,
                away_team_id,
                (group_team_count * 100)
                  - least(home_position, away_position)
                  - greatest(home_position, away_position)
              );

              competition_slot_number := competition_slot_number + 1;
            END IF;
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.rebuild_job_slots(_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  job_record RECORD;
  inserted_count INTEGER;
  manifest_count INTEGER;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id
  FOR UPDATE;

  IF job_record.id IS NULL THEN
    RAISE EXCEPTION
      'Job de prévia não encontrado para reconstruir os horários.';
  END IF;

  IF job_record.algorithm_version <> 'async-exact-v8'
    OR jsonb_typeof(
      job_record.payload -> 'structural_schedule_slots'
    ) IS DISTINCT FROM 'array'
  THEN
    PERFORM championship_bracket_preview_private.rebuild_job_slots_legacy_structural_v8(
      _job_id
    );
    RETURN;
  END IF;

  manifest_count := jsonb_array_length(
    COALESCE(
      job_record.payload -> 'structural_schedule_slots',
      '[]'::jsonb
    )
  );

  IF manifest_count = 0 THEN
    RAISE EXCEPTION
      'O payload v8 não possui structural_schedule_slots.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      job_record.payload -> 'structural_schedule_slots'
    ) AS slot_item(value)
    GROUP BY slot_item.value ->> 'slot_key'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION
      'O manifesto estrutural possui slot_key duplicado.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      job_record.payload -> 'structural_schedule_slots'
    ) AS slot_item(value)
    WHERE NULLIF(
      slot_item.value ->> 'slot_key',
      ''
    ) IS NULL
      OR NULLIF(
        slot_item.value ->> 'competition_key',
        ''
      ) IS NULL
      OR NULLIF(
        slot_item.value ->> 'phase',
        ''
      ) IS NULL
      OR NULLIF(
        slot_item.value ->> 'date',
        ''
      ) IS NULL
      OR NULLIF(
        slot_item.value ->> 'start_time',
        ''
      ) IS NULL
      OR NULLIF(
        slot_item.value ->> 'end_time',
        ''
      ) IS NULL
      OR COALESCE(
        (slot_item.value ->> 'phase_slot_number')::integer,
        0
      ) < 1
  ) THEN
    RAISE EXCEPTION
      'O manifesto estrutural possui slots incompletos.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(
      job_record.payload -> 'structural_schedule_slots'
    ) AS slot_item(value)
    WHERE slot_item.value ->> 'phase' NOT IN (
      'GROUP_STAGE',
      'ROUND_OF_32',
      'ROUND_OF_16',
      'QUARTERFINAL',
      'SEMIFINAL',
      'FINAL'
    )
  ) THEN
    RAISE EXCEPTION
      'O manifesto estrutural possui uma fase não suportada.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.assignments
    WHERE job_id = _job_id
  ) THEN
    RAISE EXCEPTION
      'Os horários não podem ser reconstruídos depois do início das atribuições.';
  END IF;

  DELETE FROM championship_bracket_preview_private.slots
  WHERE job_id = _job_id;

  WITH raw_slots AS (
    SELECT
      slot_item.value ->> 'slot_key'
        AS structural_slot_key,
      (slot_item.value ->> 'date')::date
        AS event_date,
      (slot_item.value ->> 'location_key')::uuid
        AS location_key,
      slot_item.value ->> 'location_name'
        AS location_name,
      (slot_item.value ->> 'court_key')::uuid
        AS court_key,
      slot_item.value ->> 'court_name'
        AS court_name,
      slot_item.value ->> 'competition_key'
        AS competition_key,
      (slot_item.value ->> 'sport_id')::uuid
        AS sport_id,
      NULLIF(
        slot_item.value ->> 'naipe',
        ''
      )::public.match_naipe
        AS naipe,
      NULLIF(
        slot_item.value ->> 'division',
        ''
      )::public.team_division
        AS division,
      slot_item.value ->> 'phase'
        AS phase,
      (slot_item.value ->> 'phase_slot_number')::integer
        AS phase_slot_number,
      slot_item.value ->> 'match_kind'
        AS match_kind,
      COALESCE(
        (slot_item.value ->> 'manual_final')::boolean,
        false
      ) AS manual_final,
      public.combine_bracket_schedule_timestamp(
        (slot_item.value ->> 'date')::date,
        (slot_item.value ->> 'start_time')::time
      ) AS start_at,
      public.combine_bracket_schedule_timestamp(
        (slot_item.value ->> 'date')::date,
        (slot_item.value ->> 'end_time')::time
      ) AS end_at,
      COALESCE(
        (slot_item.value ->> 'duration_minutes')::integer,
        0
      ) AS duration_minutes
    FROM jsonb_array_elements(
      job_record.payload -> 'structural_schedule_slots'
    ) AS slot_item(value)
  ),
  enriched_slots AS (
    SELECT
      raw_slots.*,
      competitions_table.id
        AS competition_id,
      COALESCE(
        location_metadata.location_position,
        1
      ) AS location_position,
      COALESCE(
        location_metadata.court_position,
        1
      ) AS court_position
    FROM raw_slots
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.job_id = _job_id
      AND competitions_table.competition_key =
        raw_slots.competition_key
      AND competitions_table.sport_id =
        raw_slots.sport_id
      AND competitions_table.naipe
        IS NOT DISTINCT FROM raw_slots.naipe
      AND competitions_table.division
        IS NOT DISTINCT FROM raw_slots.division
    LEFT JOIN LATERAL (
      SELECT
        COALESCE(
          (location_item.value ->> 'position')::integer,
          location_item.ordinality::integer
        ) AS location_position,
        COALESCE(
          (court_item.value ->> 'position')::integer,
          court_item.ordinality::integer
        ) AS court_position
      FROM jsonb_array_elements(
        COALESCE(
          job_record.payload -> 'schedule_days',
          '[]'::jsonb
        )
      ) AS day_item(value)
      CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(
          day_item.value -> 'locations',
          '[]'::jsonb
        )
      ) WITH ORDINALITY
        AS location_item(value, ordinality)
      CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(
          location_item.value -> 'courts',
          '[]'::jsonb
        )
      ) WITH ORDINALITY
        AS court_item(value, ordinality)
      WHERE day_item.value ->> 'date' =
        raw_slots.event_date::text
        AND location_item.value ->> 'location_key' =
          raw_slots.location_key::text
        AND court_item.value ->> 'court_key' =
          raw_slots.court_key::text
      LIMIT 1
    ) AS location_metadata
      ON true
  ),
  numbered_slots AS (
    SELECT
      enriched_slots.*,
      row_number() OVER (
        PARTITION BY
          enriched_slots.event_date,
          enriched_slots.court_key
        ORDER BY
          enriched_slots.start_at,
          enriched_slots.end_at,
          enriched_slots.structural_slot_key
      )::integer AS sequence_index,
      row_number() OVER (
        ORDER BY
          enriched_slots.event_date,
          enriched_slots.start_at,
          enriched_slots.location_position,
          enriched_slots.court_position,
          enriched_slots.structural_slot_key
      )::bigint AS cursor_position
    FROM enriched_slots
  )
  INSERT INTO championship_bracket_preview_private.slots (
    job_id,
    event_date,
    location_key,
    location_name,
    location_position,
    court_key,
    court_name,
    court_position,
    sport_id,
    start_at,
    end_at,
    sequence_index,
    preferred_sport,
    preferred_naipe,
    preferred_division,
    sequence_mode,
    cursor_position,
    processed,
    structural_slot_key,
    structural_competition_id,
    structural_competition_key,
    structural_phase,
    structural_phase_slot_number,
    structural_match_kind,
    structural_manual_final
  )
  SELECT
    _job_id,
    numbered_slots.event_date,
    numbered_slots.location_key,
    numbered_slots.location_name,
    numbered_slots.location_position,
    numbered_slots.court_key,
    numbered_slots.court_name,
    numbered_slots.court_position,
    numbered_slots.sport_id,
    numbered_slots.start_at,
    numbered_slots.end_at,
    numbered_slots.sequence_index,
    true,
    numbered_slots.naipe,
    numbered_slots.division,
    'FLEXIBLE',
    numbered_slots.cursor_position,
    numbered_slots.phase <> 'GROUP_STAGE',
    numbered_slots.structural_slot_key,
    numbered_slots.competition_id,
    numbered_slots.competition_key,
    numbered_slots.phase,
    numbered_slots.phase_slot_number,
    numbered_slots.match_kind,
    numbered_slots.manual_final
  FROM numbered_slots;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;

  IF inserted_count <> manifest_count THEN
    RAISE EXCEPTION
      'O manifesto possui % slots, mas somente % foram materializados.',
      manifest_count,
      inserted_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.slots
    WHERE job_id = _job_id
      AND (
        end_at <= start_at
        OR structural_competition_id IS NULL
      )
  ) THEN
    RAISE EXCEPTION
      'Um ou mais slots estruturais possuem horário ou competição inválidos.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.slots
      AS slots_table
    JOIN LATERAL (
      SELECT
        COALESCE(
          (slot_item.value ->> 'duration_minutes')::integer,
          0
        ) AS duration_minutes
      FROM jsonb_array_elements(
        job_record.payload -> 'structural_schedule_slots'
      ) AS slot_item(value)
      WHERE slot_item.value ->> 'slot_key' =
        slots_table.structural_slot_key
      LIMIT 1
    ) AS payload_slot
      ON true
    WHERE slots_table.job_id = _job_id
      AND (
        extract(
          epoch FROM (
            slots_table.end_at - slots_table.start_at
          )
        ) / 60
      )::integer
        <> payload_slot.duration_minutes
  ) THEN
    RAISE EXCEPTION
      'A duração materializada diverge do structural_schedule_slots.';
  END IF;

  UPDATE championship_bracket_preview_private.jobs
  SET
    total_slots = (
      SELECT count(*)
      FROM championship_bracket_preview_private.slots
      WHERE job_id = _job_id
        AND structural_phase = 'GROUP_STAGE'
    ),
    processed_slots = 0,
    updated_at = now()
  WHERE id = _job_id;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.rebuild_job_slots_legacy_structural_v8(_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  job_record RECORD;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id
  FOR UPDATE;

  IF job_record.id IS NULL THEN
    RAISE EXCEPTION 'Job de prévia não encontrado para reconstruir os horários.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.assignments
    WHERE job_id = _job_id
  ) THEN
    RAISE EXCEPTION 'Os horários não podem ser reconstruídos depois do início das atribuições.';
  END IF;

  DELETE FROM championship_bracket_preview_private.slots
  WHERE job_id = _job_id;

  INSERT INTO championship_bracket_preview_private.slots (
    job_id,
    event_date,
    location_key,
    location_name,
    location_position,
    court_key,
    court_name,
    court_position,
    sport_id,
    start_at,
    end_at,
    sequence_index,
    preferred_sport,
    preferred_naipe,
    preferred_division,
    sequence_mode,
    cursor_position
  )
  WITH court_sports AS (
    SELECT
      (day_item.value ->> 'date')::date AS event_date,
      (location_item.value ->> 'location_key')::uuid AS location_key,
      location_item.value ->> 'name' AS location_name,
      COALESCE(
        (location_item.value ->> 'position')::integer,
        location_item.ordinality::integer
      ) AS location_position,
      (court_item.value ->> 'court_key')::uuid AS court_key,
      court_item.value ->> 'name' AS court_name,
      COALESCE(
        (court_item.value ->> 'position')::integer,
        court_item.ordinality::integer
      ) AS court_position,
      CASE
        WHEN jsonb_array_length(COALESCE(court_item.value -> 'sport_match_targets', '[]'::jsonb)) > 0
        THEN sport_item.value ->> 'sport_id'
        ELSE trim(both '"' from sport_item.value::text)
      END::uuid AS sport_id,
      CASE
        WHEN jsonb_array_length(COALESCE(court_item.value -> 'sport_match_targets', '[]'::jsonb)) > 0
        THEN GREATEST(COALESCE((sport_item.value ->> 'planned_match_count')::integer, 0), 0)
        ELSE NULL
      END AS planned_match_count,
      NULLIF(court_item.value -> 'sport_preference' ->> 'preferred_sport_id', '')::uuid AS preferred_sport_id,
      NULLIF(court_item.value -> 'sport_preference' ->> 'preferred_naipe', '')::public.match_naipe AS configured_preferred_naipe,
      NULLIF(court_item.value -> 'sport_preference' ->> 'preferred_division', '')::public.team_division AS preferred_division,
      COALESCE(court_item.value -> 'sport_preference' ->> 'sequence_mode', 'FLEXIBLE') AS sequence_mode
    FROM jsonb_array_elements(COALESCE(job_record.payload -> 'schedule_days', '[]'::jsonb)) WITH ORDINALITY day_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(day_item.value -> 'locations', '[]'::jsonb)) WITH ORDINALITY location_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(location_item.value -> 'courts', '[]'::jsonb)) WITH ORDINALITY court_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(
      CASE
        WHEN jsonb_array_length(COALESCE(court_item.value -> 'sport_match_targets', '[]'::jsonb)) > 0
        THEN court_item.value -> 'sport_match_targets'
        ELSE COALESCE(court_item.value -> 'sport_ids', '[]'::jsonb)
      END
    ) sport_item(value)
  ), generated_slots AS (
    SELECT
      court_sports.*,
      free_interval.start_at,
      slot_start,
      duration.duration_minutes,
      row_number() OVER (
        PARTITION BY court_sports.event_date, court_sports.court_key, court_sports.sport_id
        ORDER BY slot_start
      )::integer AS sequence_index
    FROM court_sports
    JOIN LATERAL (
      SELECT GREATEST(COALESCE(championship_sports.default_match_duration_minutes, 35), 1)::integer AS duration_minutes
      FROM public.championship_sports AS championship_sports
      WHERE championship_sports.championship_id = job_record.championship_id
        AND championship_sports.sport_id = court_sports.sport_id
      LIMIT 1
    ) duration ON true
    CROSS JOIN LATERAL championship_bracket_preview_private.resolve_court_free_intervals(
      job_record.payload,
      court_sports.event_date,
      court_sports.location_key,
      court_sports.court_key
    ) free_interval
    CROSS JOIN LATERAL generate_series(
      free_interval.start_at,
      free_interval.end_at - make_interval(mins => duration.duration_minutes),
      make_interval(mins => duration.duration_minutes)
    ) slot_start
  )
  SELECT
    _job_id,
    generated_slots.event_date,
    generated_slots.location_key,
    generated_slots.location_name,
    generated_slots.location_position,
    generated_slots.court_key,
    generated_slots.court_name,
    generated_slots.court_position,
    generated_slots.sport_id,
    generated_slots.slot_start,
    generated_slots.slot_start + make_interval(mins => generated_slots.duration_minutes),
    generated_slots.sequence_index,
    COALESCE(
      generated_slots.preferred_sport_id = generated_slots.sport_id,
      false
    ),
    CASE
      WHEN generated_slots.sequence_mode = 'GROUP_NAIPE'
        AND generated_slots.configured_preferred_naipe IS NOT NULL
        AND generated_slots.planned_match_count IS NOT NULL
        AND generated_slots.sequence_index > ceil(generated_slots.planned_match_count::numeric / 2)::integer
        AND generated_slots.sequence_index <= generated_slots.planned_match_count
      THEN CASE generated_slots.configured_preferred_naipe
        WHEN 'FEMININO'::public.match_naipe THEN 'MASCULINO'::public.match_naipe
        ELSE 'FEMININO'::public.match_naipe
      END
      ELSE generated_slots.configured_preferred_naipe
    END,
    generated_slots.preferred_division,
    generated_slots.sequence_mode,
    row_number() OVER (
      ORDER BY
        generated_slots.event_date,
        generated_slots.slot_start,
        generated_slots.location_position,
        generated_slots.court_position,
        CASE WHEN generated_slots.preferred_sport_id = generated_slots.sport_id THEN 0 ELSE 1 END,
        generated_slots.sport_id
    )
  FROM generated_slots
  WHERE generated_slots.planned_match_count IS NULL
    OR generated_slots.sequence_index <= generated_slots.planned_match_count
  ON CONFLICT DO NOTHING;

  UPDATE championship_bracket_preview_private.jobs
  SET
    total_slots = (
      SELECT count(*)
      FROM championship_bracket_preview_private.slots
      WHERE job_id = _job_id
    ),
    processed_slots = 0,
    updated_at = now()
  WHERE id = _job_id;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.record_group_match_scheduled_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  event_details JSONB;
  current_stage TEXT;
  pending_matches_after INTEGER;
BEGIN
  IF NOT NEW.assigned OR OLD.assigned THEN
    RETURN NEW;
  END IF;

  SELECT
    jobs_table.stage,
    jsonb_build_object(
      'logical_key', NEW.logical_key,
      'sport_name', competitions_table.sport_name,
      'naipe', competitions_table.naipe,
      'division', competitions_table.division,
      'group_number', groups_table.group_number,
      'round_number', NEW.round_number,
      'phase', 'GROUP_STAGE',
      'date', slots_table.event_date,
      'start_at', to_char(slots_table.start_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'end_at', to_char(slots_table.end_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'location_name', slots_table.location_name,
      'court_name', slots_table.court_name
    )
  INTO current_stage, event_details
  FROM championship_bracket_preview_private.assignments assignments_table
  JOIN championship_bracket_preview_private.slots slots_table
    ON slots_table.id = assignments_table.slot_id
  JOIN championship_bracket_preview_private.competitions competitions_table
    ON competitions_table.id = NEW.competition_id
  JOIN championship_bracket_preview_private.groups groups_table
    ON groups_table.id = NEW.group_id
  JOIN championship_bracket_preview_private.jobs jobs_table
    ON jobs_table.id = NEW.job_id
  WHERE assignments_table.job_id = NEW.job_id
    AND assignments_table.match_id = NEW.id;

  INSERT INTO championship_bracket_preview_private.job_events (
    job_id,
    event_type,
    group_match_id,
    stage,
    details,
    occurred_at
  )
  VALUES (
    NEW.job_id,
    'GROUP_MATCH_SCHEDULED',
    NEW.id,
    current_stage,
    event_details,
    clock_timestamp()
  )
  ON CONFLICT (job_id, event_type, group_match_id, knockout_match_id)
  DO NOTHING;

  IF current_stage = 'COMPACTING_GROUPS'
    OR current_stage LIKE 'Reorganizando grade:%'
    OR current_stage LIKE 'Reorganizando slots estruturais:%'
  THEN
    SELECT count(*)
    INTO pending_matches_after
    FROM championship_bracket_preview_private.matches matches_table
    WHERE matches_table.job_id = NEW.job_id
      AND NOT matches_table.assigned;

    INSERT INTO championship_bracket_preview_private.job_events (
      job_id,
      event_type,
      group_match_id,
      stage,
      details,
      occurred_at
    )
    VALUES (
      NEW.job_id,
      'PENDING_MATCH_COUNT_DECREASED',
      NEW.id,
      CASE
        WHEN current_stage LIKE 'Reorganizando slots estruturais:%'
          THEN current_stage
        ELSE 'COMPACTING_GROUPS'
      END,
      jsonb_build_object(
        'pending_matches_before', pending_matches_after + 1,
        'pending_matches_after', pending_matches_after
      ),
      clock_timestamp()
    )
    ON CONFLICT (job_id, event_type, group_match_id, knockout_match_id)
    DO NOTHING;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.record_knockout_match_scheduled_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  event_details JSONB;
  current_stage TEXT;
BEGIN
  IF NEW.is_bye
    OR OLD.scheduled_date IS NOT NULL
    OR NEW.scheduled_date IS NULL
  THEN
    RETURN NEW;
  END IF;

  SELECT
    jobs_table.stage,
    jsonb_build_object(
      'logical_key', NEW.logical_key,
      'sport_name', competitions_table.sport_name,
      'naipe', competitions_table.naipe,
      'division', competitions_table.division,
      'round_number', NEW.round_number,
      'phase', NEW.phase,
      'date', NEW.scheduled_date,
      'start_at', to_char(NEW.start_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'end_at', to_char(NEW.end_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
      'location_name', NEW.location_name,
      'court_name', NEW.court_name
    )
  INTO current_stage, event_details
  FROM championship_bracket_preview_private.competitions competitions_table
  JOIN championship_bracket_preview_private.jobs jobs_table
    ON jobs_table.id = NEW.job_id
  WHERE competitions_table.id = NEW.competition_id;

  INSERT INTO championship_bracket_preview_private.job_events (
    job_id,
    event_type,
    knockout_match_id,
    stage,
    details,
    occurred_at
  )
  VALUES (
    NEW.job_id,
    'KNOCKOUT_MATCH_SCHEDULED',
    NEW.id,
    current_stage,
    event_details,
    clock_timestamp()
  )
  ON CONFLICT (job_id, event_type, group_match_id, knockout_match_id)
  DO NOTHING;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.record_reorganization_stage_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  pending_matches INTEGER;
BEGIN
  IF (
    NEW.stage NOT LIKE 'Reorganizando grade:%'
    AND NEW.stage NOT LIKE 'Reorganizando slots estruturais:%'
  ) OR (
    COALESCE(OLD.stage, '') LIKE 'Reorganizando grade:%'
    OR COALESCE(OLD.stage, '') LIKE 'Reorganizando slots estruturais:%'
  ) THEN
    RETURN NEW;
  END IF;

  SELECT count(*)
  INTO pending_matches
  FROM championship_bracket_preview_private.matches matches_table
  WHERE matches_table.job_id = NEW.id
    AND NOT matches_table.assigned;

  INSERT INTO championship_bracket_preview_private.job_events (
    job_id,
    event_type,
    stage,
    details,
    occurred_at
  )
  VALUES (
    NEW.id,
    'STAGE_CHANGED',
    CASE
      WHEN NEW.stage LIKE 'Reorganizando slots estruturais:%' THEN NEW.stage
      ELSE 'COMPACTING_GROUPS'
    END,
    jsonb_build_object('pending_matches', pending_matches),
    clock_timestamp()
  )
  ON CONFLICT (job_id, event_type, group_match_id, knockout_match_id)
  DO NOTHING;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.reset_manifest_csp_naipe_search(_job_id uuid, _naipe match_naipe, _rest_gap integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
BEGIN
  DELETE FROM championship_bracket_preview_private.assignments
    AS assignments_table
  USING championship_bracket_preview_private.matches
    AS matches_table,
    championship_bracket_preview_private.competitions
    AS competitions_table
  WHERE assignments_table.job_id = _job_id
    AND matches_table.id =
      assignments_table.match_id
    AND competitions_table.id =
      matches_table.competition_id
    AND competitions_table.naipe =
      _naipe;

  UPDATE championship_bracket_preview_private.matches
    AS matches_table
  SET assigned = false
  FROM championship_bracket_preview_private.competitions
    AS competitions_table
  WHERE matches_table.job_id = _job_id
    AND competitions_table.id =
      matches_table.competition_id
    AND competitions_table.naipe =
      _naipe;

  DELETE FROM championship_bracket_preview_private.manifest_solver_tried_slots
  WHERE job_id = _job_id
    AND naipe = _naipe;

  DELETE FROM championship_bracket_preview_private.manifest_solver_frames
  WHERE job_id = _job_id
    AND naipe = _naipe;

  UPDATE championship_bracket_preview_private.manifest_solver_state
  SET
    rest_gap = _rest_gap,
    phase =
      CASE
        WHEN _rest_gap = 3
          THEN 'SEARCHING'
        ELSE 'SEARCHING_RELAXED'
      END,
    phase_started_at = now(),
    phase_backtracks = 0,
    updated_at = now()
  WHERE job_id = _job_id;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.reset_manifest_daily_day_search(_job_id uuid, _event_date date, _rest_gap integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
BEGIN
  UPDATE championship_bracket_preview_private.matches
    AS matches_table
  SET
    assigned = false,
    applied_rest_gap = 3,
    relaxed_rest_gap_applied = false
  WHERE matches_table.job_id = _job_id
    AND matches_table.id IN (
      SELECT assignments_table.match_id
      FROM championship_bracket_preview_private.assignments
        AS assignments_table
      JOIN championship_bracket_preview_private.slots
        AS slots_table
        ON slots_table.id =
          assignments_table.slot_id
      WHERE assignments_table.job_id = _job_id
        AND slots_table.event_date =
          _event_date
        AND slots_table.structural_phase =
          'GROUP_STAGE'
    );

  DELETE FROM championship_bracket_preview_private.assignments
  WHERE job_id = _job_id
    AND slot_id IN (
      SELECT slots_table.id
      FROM championship_bracket_preview_private.slots
        AS slots_table
      WHERE slots_table.job_id = _job_id
        AND slots_table.event_date =
          _event_date
        AND slots_table.structural_phase =
          'GROUP_STAGE'
    );

  DELETE FROM championship_bracket_preview_private.manifest_daily_solver_tried_matches
  WHERE job_id = _job_id
    AND event_date =
      _event_date;

  DELETE FROM championship_bracket_preview_private.manifest_daily_solver_frames
  WHERE job_id = _job_id
    AND event_date =
      _event_date;

  UPDATE championship_bracket_preview_private.slots
  SET processed = false
  WHERE job_id = _job_id
    AND event_date =
      _event_date
    AND structural_phase =
      'GROUP_STAGE';

  UPDATE championship_bracket_preview_private.manifest_daily_solver_state
  SET
    rest_gap = _rest_gap,
    phase =
      CASE
        WHEN _rest_gap = 3
          THEN 'SEARCHING_DAY'
        ELSE 'SEARCHING_DAY_RELAXED'
      END,
    day_backtracks = 0,
    day_started_at = now(),
    last_forward_diagnostics =
      '[]'::jsonb,
    updated_at = now()
  WHERE job_id = _job_id;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_court_free_intervals(_payload jsonb, _event_date date, _location_key uuid, _court_key uuid)
 RETURNS TABLE(start_at timestamp with time zone, end_at timestamp with time zone)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH selected_day AS (
    SELECT day_item.value AS day
    FROM jsonb_array_elements(COALESCE(_payload -> 'schedule_days', '[]'::jsonb)) day_item(value)
    WHERE day_item.value ->> 'date' = _event_date::text
    LIMIT 1
  ), day_bounds AS (
    SELECT
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (selected_day.day ->> 'start_time')::time
      ) AS day_start,
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (selected_day.day ->> 'end_time')::time
      ) AS day_end,
      selected_day.day
    FROM selected_day
  ), blocked_raw AS (
    SELECT
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (day_bounds.day ->> 'break_start_time')::time
      ) AS blocked_start,
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (day_bounds.day ->> 'break_end_time')::time
      ) AS blocked_end
    FROM day_bounds
    WHERE NULLIF(day_bounds.day ->> 'break_start_time', '') IS NOT NULL
      AND NULLIF(day_bounds.day ->> 'break_end_time', '') IS NOT NULL

    UNION ALL

    SELECT
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (lock_item.value ->> 'start_time')::time
      ),
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (lock_item.value ->> 'end_time')::time
      )
    FROM jsonb_array_elements(COALESCE(_payload -> 'resource_locks', '[]'::jsonb)) lock_item(value)
    WHERE lock_item.value ->> 'date' = _event_date::text
      AND lock_item.value ->> 'location_key' = _location_key::text
      AND lock_item.value ->> 'court_key' = _court_key::text
      AND NULLIF(lock_item.value ->> 'start_time', '') IS NOT NULL
      AND NULLIF(lock_item.value ->> 'end_time', '') IS NOT NULL

    UNION ALL

    SELECT
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (session_item.value ->> 'start_time')::time
      ),
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (session_item.value ->> 'end_time')::time
      )
    FROM jsonb_array_elements(COALESCE(_payload -> 'individual_session_configs', '[]'::jsonb)) session_item(value)
    WHERE session_item.value ->> 'scheduled_date' = _event_date::text
      AND session_item.value ->> 'location_key' = _location_key::text
      AND session_item.value ->> 'court_key' = _court_key::text
      AND NULLIF(session_item.value ->> 'start_time', '') IS NOT NULL
      AND NULLIF(session_item.value ->> 'end_time', '') IS NOT NULL

    UNION ALL

    SELECT
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (block_item.value ->> 'start_time')::time
      ),
      public.combine_bracket_schedule_timestamp(
        _event_date,
        (block_item.value ->> 'end_time')::time
      )
    FROM jsonb_array_elements(COALESCE(_payload -> 'knockout_program_blocks', '[]'::jsonb)) block_item(value)
    WHERE block_item.value ->> 'date' = _event_date::text
      AND block_item.value ->> 'location_key' = _location_key::text
      AND block_item.value ->> 'court_key' = _court_key::text
      AND NULLIF(block_item.value ->> 'start_time', '') IS NOT NULL
      AND NULLIF(block_item.value ->> 'end_time', '') IS NOT NULL
  ), clamped_blocks AS (
    SELECT
      GREATEST(blocked_raw.blocked_start, day_bounds.day_start) AS blocked_start,
      LEAST(blocked_raw.blocked_end, day_bounds.day_end) AS blocked_end,
      day_bounds.day_start,
      day_bounds.day_end
    FROM blocked_raw
    CROSS JOIN day_bounds
    WHERE blocked_raw.blocked_end > day_bounds.day_start
      AND blocked_raw.blocked_start < day_bounds.day_end
      AND blocked_raw.blocked_end > blocked_raw.blocked_start
  ), ordered_blocks AS (
    SELECT
      clamped_blocks.*,
      max(clamped_blocks.blocked_end) OVER (
        ORDER BY clamped_blocks.blocked_start, clamped_blocks.blocked_end
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ) AS previous_max_end
    FROM clamped_blocks
  ), grouped_blocks AS (
    SELECT
      ordered_blocks.*,
      sum(
        CASE
          WHEN ordered_blocks.previous_max_end IS NULL
            OR ordered_blocks.blocked_start > ordered_blocks.previous_max_end
          THEN 1
          ELSE 0
        END
      ) OVER (ORDER BY ordered_blocks.blocked_start, ordered_blocks.blocked_end) AS block_group
    FROM ordered_blocks
  ), merged_blocks AS (
    SELECT
      min(grouped_blocks.blocked_start) AS blocked_start,
      max(grouped_blocks.blocked_end) AS blocked_end,
      min(grouped_blocks.day_start) AS day_start,
      max(grouped_blocks.day_end) AS day_end
    FROM grouped_blocks
    GROUP BY grouped_blocks.block_group
  ), free_intervals AS (
    SELECT
      day_bounds.day_start AS free_start,
      COALESCE(
        (SELECT min(merged_blocks.blocked_start) FROM merged_blocks),
        day_bounds.day_end
      ) AS free_end
    FROM day_bounds

    UNION ALL

    SELECT
      merged_blocks.blocked_end,
      lead(
        merged_blocks.blocked_start,
        1,
        merged_blocks.day_end
      ) OVER (ORDER BY merged_blocks.blocked_start, merged_blocks.blocked_end)
    FROM merged_blocks
  )
  SELECT free_intervals.free_start, free_intervals.free_end
  FROM free_intervals
  WHERE free_intervals.free_end > free_intervals.free_start
  ORDER BY free_intervals.free_start;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_dependency_signature(_championship_id uuid, _payload jsonb)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  SELECT encode(extensions.digest(convert_to(jsonb_build_object(
    'championship', (SELECT to_jsonb(c.*) - 'created_at' - 'updated_at' FROM public.championships c WHERE c.id = _championship_id),
    'sports', COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'sport_id', cs.sport_id, 'duration', cs.default_match_duration_minutes,
      'result_rule', cs.result_rule, 'points_win', cs.points_win,
      'points_draw', cs.points_draw, 'points_loss', cs.points_loss,
      'tie_break', cs.tie_breaker_rule
    ) ORDER BY cs.sport_id) FROM public.championship_sports cs WHERE cs.championship_id = _championship_id), '[]'::jsonb),
    'teams', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'active', t.is_active) ORDER BY t.id)
      FROM public.teams t WHERE t.id IN (
        SELECT NULLIF(participant.value ->> 'team_id', '')::uuid
        FROM jsonb_array_elements(COALESCE(_payload -> 'participants', '[]'::jsonb)) participant(value)
      )), '[]'::jsonb)
  )::text, 'UTF8'), 'sha256'), 'hex');
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_manifest_csp_cached_next_match(_job_id uuid, _naipe match_naipe, _rest_gap integer)
 RETURNS TABLE(match_id uuid, option_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH ready_matches AS (
    SELECT
      matches_table.id,
      matches_table.priority_weight,
      matches_table.round_number,
      matches_table.slot_number,
      competitions_table.position
        AS competition_position,
      groups_table.group_number
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
    WHERE matches_table.job_id = _job_id
      AND NOT matches_table.assigned
      AND competitions_table.naipe = _naipe
      AND NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.matches
          AS earlier_match
        WHERE earlier_match.job_id = _job_id
          AND earlier_match.competition_id =
            matches_table.competition_id
          AND earlier_match.group_id =
            matches_table.group_id
          AND earlier_match.round_number <
            matches_table.round_number
          AND NOT earlier_match.assigned
      )
  ),
  evaluated_matches AS (
    SELECT
      ready_matches.*,
      (
        SELECT count(*)::integer
        FROM championship_bracket_preview_private.manifest_solver_candidates
          AS candidate
        WHERE candidate.job_id = _job_id
          AND candidate.match_id =
            ready_matches.id
          AND championship_bracket_preview_private.is_manifest_csp_dynamic_candidate_eligible(
            _job_id,
            ready_matches.id,
            candidate.slot_id,
            _rest_gap
          )
      ) AS option_count
    FROM ready_matches
  )
  SELECT
    evaluated_matches.id,
    evaluated_matches.option_count
  FROM evaluated_matches
  ORDER BY
    evaluated_matches.option_count,
    evaluated_matches.priority_weight DESC,
    evaluated_matches.round_number,
    evaluated_matches.competition_position,
    evaluated_matches.group_number,
    evaluated_matches.slot_number,
    evaluated_matches.id
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_manifest_csp_candidate_slots(_job_id uuid, _match_id uuid, _rest_gap integer)
 RETURNS TABLE(slot_id bigint, candidate_rank integer, pressure bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH match_context AS (
    SELECT
      matches_table.id AS match_id,
      matches_table.competition_id,
      matches_table.home_team_id,
      matches_table.away_team_id,
      competitions_table.naipe
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
      AND matches_table.id = _match_id
  ),
  eligible_slots AS (
    SELECT
      slots_table.id AS slot_id,
      slots_table.event_date,
      slots_table.start_at,
      slots_table.end_at,
      slots_table.location_position,
      slots_table.court_position,
      slots_table.cursor_position
    FROM match_context
    JOIN championship_bracket_preview_private.slots
      AS slots_table
      ON slots_table.job_id = _job_id
      AND slots_table.structural_phase =
        'GROUP_STAGE'
      AND slots_table.structural_competition_id =
        match_context.competition_id
    WHERE NOT EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.assignments
        AS occupied_assignment
      WHERE occupied_assignment.job_id = _job_id
        AND occupied_assignment.slot_id =
          slots_table.id
    )
      AND championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
        _job_id,
        _match_id,
        slots_table.id,
        _rest_gap
      )
  ),
  scored_slots AS (
    SELECT
      eligible_slots.*,
      (
        SELECT count(*)::bigint
        FROM match_context
        JOIN championship_bracket_preview_private.matches
          AS other_match
          ON other_match.job_id = _job_id
          AND other_match.id <> _match_id
          AND NOT other_match.assigned
        JOIN championship_bracket_preview_private.competitions
          AS other_competition
          ON other_competition.id =
            other_match.competition_id
          AND other_competition.naipe =
            match_context.naipe
        JOIN championship_bracket_preview_private.slots
          AS other_slot
          ON other_slot.job_id = _job_id
          AND other_slot.structural_phase =
            'GROUP_STAGE'
          AND other_slot.structural_competition_id =
            other_match.competition_id
        WHERE (
          other_match.home_team_id IN (
            match_context.home_team_id,
            match_context.away_team_id
          )
          OR other_match.away_team_id IN (
            match_context.home_team_id,
            match_context.away_team_id
          )
          OR other_slot.id =
            eligible_slots.slot_id
        )
          AND NOT EXISTS (
            SELECT 1
            FROM championship_bracket_preview_private.assignments
              AS other_occupied
            WHERE other_occupied.job_id = _job_id
              AND other_occupied.slot_id =
                other_slot.id
          )
          AND championship_bracket_preview_private.is_match_slot_static_eligible(
            _job_id,
            other_match.id,
            other_slot.id
          )
          AND (
            other_slot.id =
              eligible_slots.slot_id
            OR championship_bracket_preview_private.is_match_pair_rest_conflict(
              _job_id,
              _match_id,
              eligible_slots.slot_id,
              other_match.id,
              other_slot.id,
              _rest_gap
            )
          )
      ) AS pressure
    FROM eligible_slots
  ),
  ranked_slots AS (
    SELECT
      scored_slots.slot_id,
      row_number() OVER (
        ORDER BY
          scored_slots.pressure,
          scored_slots.event_date,
          scored_slots.start_at,
          scored_slots.location_position,
          scored_slots.court_position,
          scored_slots.cursor_position,
          scored_slots.slot_id
      )::integer AS candidate_rank,
      scored_slots.pressure
    FROM scored_slots
  )
  SELECT
    ranked_slots.slot_id,
    ranked_slots.candidate_rank,
    ranked_slots.pressure
  FROM ranked_slots
  ORDER BY ranked_slots.candidate_rank;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_manifest_csp_next_match(_job_id uuid, _naipe match_naipe, _rest_gap integer)
 RETURNS TABLE(match_id uuid, option_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH ready_matches AS (
    SELECT
      matches_table.id,
      matches_table.competition_id,
      matches_table.group_id,
      matches_table.round_number,
      matches_table.slot_number,
      matches_table.priority_weight,
      competitions_table.position
        AS competition_position,
      groups_table.group_number
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
    WHERE matches_table.job_id = _job_id
      AND NOT matches_table.assigned
      AND competitions_table.naipe = _naipe
      AND NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.matches
          AS earlier_match
        WHERE earlier_match.job_id = _job_id
          AND earlier_match.competition_id =
            matches_table.competition_id
          AND earlier_match.group_id =
            matches_table.group_id
          AND earlier_match.round_number <
            matches_table.round_number
          AND NOT earlier_match.assigned
      )
  ),
  evaluated_matches AS (
    SELECT
      ready_matches.*,
      (
        SELECT count(*)::integer
        FROM championship_bracket_preview_private.slots
          AS candidate_slot
        WHERE candidate_slot.job_id = _job_id
          AND candidate_slot.structural_phase =
            'GROUP_STAGE'
          AND candidate_slot.structural_competition_id =
            ready_matches.competition_id
          AND NOT EXISTS (
            SELECT 1
            FROM championship_bracket_preview_private.assignments
              AS occupied_assignment
            WHERE occupied_assignment.job_id = _job_id
              AND occupied_assignment.slot_id =
                candidate_slot.id
          )
          AND championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
            _job_id,
            ready_matches.id,
            candidate_slot.id,
            _rest_gap
          )
      ) AS option_count
    FROM ready_matches
  )
  SELECT
    evaluated_matches.id,
    evaluated_matches.option_count
  FROM evaluated_matches
  ORDER BY
    evaluated_matches.option_count,
    evaluated_matches.priority_weight DESC,
    evaluated_matches.round_number DESC,
    evaluated_matches.competition_position,
    evaluated_matches.group_number,
    evaluated_matches.slot_number,
    evaluated_matches.id
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_manifest_daily_future_diagnostics(_job_id uuid, _closed_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  diagnostics JSONB;
  future_group_day_count INTEGER;
  final_group_date DATE;
  probe_result JSONB;
  repair_result JSONB;
  repair_round INTEGER := 0;
  successful_repairs INTEGER := 0;
BEGIN
  diagnostics :=
    championship_bracket_preview_private.resolve_manifest_daily_future_diagnostics_capacity_only_v8(
      _job_id,
      _closed_date
    );

  IF jsonb_array_length(
    diagnostics
  ) > 0 THEN
    RETURN diagnostics;
  END IF;

  SELECT
    count(
      DISTINCT slots_table.event_date
    )::integer,
    min(slots_table.event_date)
  INTO
    future_group_day_count,
    final_group_date
  FROM championship_bracket_preview_private.slots
    AS slots_table
  WHERE slots_table.job_id =
      _job_id
    AND slots_table.structural_phase =
      'GROUP_STAGE'
    AND slots_table.event_date >
      _closed_date;

  IF future_group_day_count <> 1
    OR final_group_date IS NULL
  THEN
    RETURN '[]'::jsonb;
  END IF;

  probe_result :=
    championship_bracket_preview_private.probe_manifest_daily_date_feasibility(
      _job_id,
      final_group_date,
      2,
      500,
      3500
    );

  IF COALESCE(
    (
      probe_result ->> 'feasible'
    )::boolean,
    false
  ) THEN
    RETURN '[]'::jsonb;
  END IF;

  WHILE repair_round < 2
  LOOP
    repair_round :=
      repair_round + 1;

    repair_result :=
      championship_bracket_preview_private.try_manifest_daily_interday_repair(
        _job_id,
        _closed_date,
        final_group_date
      );

    IF NOT COALESCE(
      (
        repair_result ->> 'repaired'
      )::boolean,
      false
    ) THEN
      EXIT;
    END IF;

    successful_repairs :=
      successful_repairs + 1;

    probe_result :=
      championship_bracket_preview_private.probe_manifest_daily_date_feasibility(
        _job_id,
        final_group_date,
        2,
        500,
        3500
      );

    IF COALESCE(
      (
        probe_result ->> 'feasible'
      )::boolean,
      false
    ) THEN
      RETURN '[]'::jsonb;
    END IF;
  END LOOP;

  IF probe_result ->> 'status' =
      'EXHAUSTED'
  THEN
    RETURN jsonb_build_array(
      jsonb_build_object(
        'code',
        'DAILY_FINAL_DAY_INFEASIBLE',
        'message',
        format(
          'A composição atual até %s deixa o último dia de grupos (%s) comprovadamente sem distribuição válida.',
          to_char(
            _closed_date,
            'DD/MM/YYYY'
          ),
          to_char(
            final_group_date,
            'DD/MM/YYYY'
          )
        ),
        'closed_date',
        _closed_date,
        'final_group_date',
        final_group_date,
        'probe_status',
        probe_result ->> 'status',
        'probe_rest_gap',
        probe_result -> 'rest_gap',
        'probe_day_total',
        probe_result -> 'day_total',
        'probe_max_assigned',
        probe_result -> 'max_assigned',
        'probe_decisions',
        probe_result -> 'decisions',
        'probe_backtracks',
        probe_result -> 'backtracks',
        'probe_elapsed_ms',
        probe_result -> 'elapsed_ms',
        'successful_interday_repairs',
        successful_repairs,
        'last_interday_repair',
        repair_result
      )
    );
  END IF;

  RETURN jsonb_build_array(
    jsonb_build_object(
      'code',
      'DAILY_FINAL_DAY_UNRESOLVED',
      'message',
      format(
        'A composição atual até %s ainda não permitiu confirmar uma solução conjunta para o último dia de grupos (%s); o probe atingiu o limite de busca e o scheduler deve tentar outra composição.',
        to_char(
          _closed_date,
          'DD/MM/YYYY'
        ),
        to_char(
          final_group_date,
          'DD/MM/YYYY'
        )
      ),
      'closed_date',
      _closed_date,
      'final_group_date',
      final_group_date,
      'probe_status',
      probe_result ->> 'status',
      'probe_rest_gap',
      probe_result -> 'rest_gap',
      'probe_day_total',
      probe_result -> 'day_total',
      'probe_max_assigned',
      probe_result -> 'max_assigned',
      'probe_decisions',
      probe_result -> 'decisions',
      'probe_backtracks',
      probe_result -> 'backtracks',
      'probe_elapsed_ms',
      probe_result -> 'elapsed_ms',
      'successful_interday_repairs',
      successful_repairs,
      'last_interday_repair',
      repair_result
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_manifest_daily_future_diagnostics_capacity_only_v8(_job_id uuid, _closed_date date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH remaining_matches AS (
    SELECT
      matches_table.id,
      matches_table.logical_key,
      matches_table.competition_id,
      competitions_table.competition_key,
      competitions_table.sport_name,
      competitions_table.naipe,
      competitions_table.division
    FROM championship_bracket_preview_private.matches
      AS matches_table
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    WHERE matches_table.job_id = _job_id
      AND NOT matches_table.assigned
  ),
  remaining_by_competition AS (
    SELECT
      remaining_matches.competition_id,
      max(remaining_matches.competition_key)
        AS competition_key,
      count(*)::integer
        AS remaining_matches
    FROM remaining_matches
    GROUP BY
      remaining_matches.competition_id
  ),
  future_slots_by_competition AS (
    SELECT
      slots_table.structural_competition_id
        AS competition_id,
      count(*)::integer
        AS future_slots
    FROM championship_bracket_preview_private.slots
      AS slots_table
    WHERE slots_table.job_id = _job_id
      AND slots_table.structural_phase =
        'GROUP_STAGE'
      AND slots_table.event_date >
        _closed_date
      AND NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.assignments
          AS assignments_table
        WHERE assignments_table.job_id = _job_id
          AND assignments_table.slot_id =
            slots_table.id
      )
    GROUP BY
      slots_table.structural_competition_id
  ),
  diagnostics AS (
    SELECT jsonb_build_object(
      'code',
      'DAILY_FUTURE_MATCH_WITHOUT_SLOT',
      'message',
      format(
        'O confronto %s não possui slot estrutural futuro elegível após %s.',
        remaining_matches.logical_key,
        _closed_date
      ),
      'match_id',
      remaining_matches.id,
      'logical_key',
      remaining_matches.logical_key,
      'competition_key',
      remaining_matches.competition_key,
      'after_date',
      _closed_date
    ) AS diagnostic
    FROM remaining_matches
    WHERE NOT EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.manifest_solver_candidates
        AS candidate
      JOIN championship_bracket_preview_private.slots
        AS candidate_slot
        ON candidate_slot.id =
          candidate.slot_id
      WHERE candidate.job_id = _job_id
        AND candidate.match_id =
          remaining_matches.id
        AND candidate_slot.event_date >
          _closed_date
        AND candidate_slot.structural_phase =
          'GROUP_STAGE'
        AND NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.assignments
            AS occupied_assignment
          WHERE occupied_assignment.job_id =
            _job_id
            AND occupied_assignment.slot_id =
              candidate_slot.id
        )
    )

    UNION ALL

    SELECT jsonb_build_object(
      'code',
      'DAILY_FUTURE_COMPETITION_CAPACITY',
      'message',
      format(
        '%s possui %s jogos restantes, mas somente %s slots estruturais futuros após %s.',
        remaining_by_competition.competition_key,
        remaining_by_competition.remaining_matches,
        COALESCE(
          future_slots_by_competition.future_slots,
          0
        ),
        _closed_date
      ),
      'competition_key',
      remaining_by_competition.competition_key,
      'remaining_matches',
      remaining_by_competition.remaining_matches,
      'future_slots',
      COALESCE(
        future_slots_by_competition.future_slots,
        0
      ),
      'after_date',
      _closed_date
    )
    FROM remaining_by_competition
    LEFT JOIN future_slots_by_competition
      ON future_slots_by_competition.competition_id =
        remaining_by_competition.competition_id
    WHERE remaining_by_competition.remaining_matches >
      COALESCE(
        future_slots_by_competition.future_slots,
        0
      )
  )
  SELECT COALESCE(
    jsonb_agg(
      diagnostics.diagnostic
      ORDER BY
        diagnostics.diagnostic ->> 'code',
        diagnostics.diagnostic ->> 'competition_key',
        diagnostics.diagnostic ->> 'logical_key'
    ),
    '[]'::jsonb
  )
  FROM diagnostics;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_manifest_daily_future_diagnostics_final_probe_v8(_job_id uuid, _closed_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  diagnostics JSONB;
  future_group_day_count INTEGER;
  final_group_date DATE;
  probe_result JSONB;
BEGIN
  diagnostics :=
    championship_bracket_preview_private.resolve_manifest_daily_future_diagnostics_capacity_only_v8(
      _job_id,
      _closed_date
    );

  IF jsonb_array_length(
    diagnostics
  ) > 0 THEN
    RETURN diagnostics;
  END IF;

  SELECT
    count(
      DISTINCT slots_table.event_date
    )::integer,
    min(slots_table.event_date)
  INTO
    future_group_day_count,
    final_group_date
  FROM championship_bracket_preview_private.slots
    AS slots_table
  WHERE slots_table.job_id = _job_id
    AND slots_table.structural_phase =
      'GROUP_STAGE'
    AND slots_table.event_date >
      _closed_date;

  IF future_group_day_count = 1
    AND final_group_date IS NOT NULL
  THEN
    probe_result :=
      championship_bracket_preview_private.probe_manifest_daily_date_feasibility(
        _job_id,
        final_group_date,
        2,
        800,
        6000
      );

    IF NOT COALESCE(
      (
        probe_result ->> 'feasible'
      )::boolean,
      false
    ) THEN
      RETURN jsonb_build_array(
        jsonb_build_object(
          'code',
          'DAILY_FINAL_DAY_INFEASIBLE',
          'message',
          format(
            'A distribuição atual até %s deixa o último dia de grupos (%s) sem uma solução conjunta válida.',
            to_char(
              _closed_date,
              'DD/MM/YYYY'
            ),
            to_char(
              final_group_date,
              'DD/MM/YYYY'
            )
          ),
          'closed_date',
          _closed_date,
          'final_group_date',
          final_group_date,
          'probe_status',
          probe_result ->> 'status',
          'probe_rest_gap',
          probe_result -> 'rest_gap',
          'probe_day_total',
          probe_result -> 'day_total',
          'probe_max_assigned',
          probe_result -> 'max_assigned',
          'probe_decisions',
          probe_result -> 'decisions',
          'probe_backtracks',
          probe_result -> 'backtracks',
          'probe_elapsed_ms',
          probe_result -> 'elapsed_ms'
        )
      );
    END IF;
  END IF;

  RETURN '[]'::jsonb;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_manifest_daily_slot_candidate(_job_id uuid, _event_date date, _slot_id bigint, _rest_gap integer)
 RETURNS TABLE(match_id uuid, round_number integer, group_number integer, slot_number integer, round_group_usage integer, group_day_usage integer, future_candidate_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH slot_context AS (
    SELECT
      slots_table.id,
      slots_table.structural_competition_id
        AS competition_id
    FROM championship_bracket_preview_private.slots
      AS slots_table
    WHERE slots_table.job_id = _job_id
      AND slots_table.id = _slot_id
      AND slots_table.event_date =
        _event_date
      AND slots_table.structural_phase =
        'GROUP_STAGE'
  ),
  candidate_matches AS (
    SELECT
      matches_table.id AS match_id,
      matches_table.round_number,
      matches_table.slot_number,
      matches_table.group_id,
      groups_table.group_number,
      matches_table.priority_weight
    FROM slot_context
    JOIN championship_bracket_preview_private.manifest_solver_candidates
      AS cached_candidate
      ON cached_candidate.job_id = _job_id
      AND cached_candidate.slot_id =
        slot_context.id
    JOIN championship_bracket_preview_private.matches
      AS matches_table
      ON matches_table.id =
        cached_candidate.match_id
      AND matches_table.job_id = _job_id
      AND matches_table.competition_id =
        slot_context.competition_id
      AND NOT matches_table.assigned
    JOIN championship_bracket_preview_private.groups
      AS groups_table
      ON groups_table.id =
        matches_table.group_id
    WHERE championship_bracket_preview_private.is_manifest_csp_dynamic_candidate_eligible(
      _job_id,
      matches_table.id,
      _slot_id,
      _rest_gap
    )
  ),
  scored_matches AS (
    SELECT
      candidate_matches.*,
      (
        SELECT count(*)::integer
        FROM championship_bracket_preview_private.assignments
          AS assignments_table
        JOIN championship_bracket_preview_private.matches
          AS assigned_match
          ON assigned_match.id =
            assignments_table.match_id
        JOIN championship_bracket_preview_private.slots
          AS assigned_slot
          ON assigned_slot.id =
            assignments_table.slot_id
        WHERE assignments_table.job_id = _job_id
          AND assigned_slot.event_date =
            _event_date
          AND assigned_match.group_id =
            candidate_matches.group_id
          AND assigned_match.round_number =
            candidate_matches.round_number
      ) AS round_group_usage,
      (
        SELECT count(*)::integer
        FROM championship_bracket_preview_private.assignments
          AS assignments_table
        JOIN championship_bracket_preview_private.matches
          AS assigned_match
          ON assigned_match.id =
            assignments_table.match_id
        JOIN championship_bracket_preview_private.slots
          AS assigned_slot
          ON assigned_slot.id =
            assignments_table.slot_id
        WHERE assignments_table.job_id = _job_id
          AND assigned_slot.event_date =
            _event_date
          AND assigned_match.group_id =
            candidate_matches.group_id
      ) AS group_day_usage,
      (
        SELECT count(*)::integer
        FROM championship_bracket_preview_private.manifest_solver_candidates
          AS future_candidate
        JOIN championship_bracket_preview_private.slots
          AS future_slot
          ON future_slot.id =
            future_candidate.slot_id
        WHERE future_candidate.job_id = _job_id
          AND future_candidate.match_id =
            candidate_matches.match_id
          AND future_slot.event_date >=
            _event_date
          AND future_slot.structural_phase =
            'GROUP_STAGE'
          AND NOT EXISTS (
            SELECT 1
            FROM championship_bracket_preview_private.assignments
              AS occupied_assignment
            WHERE occupied_assignment.job_id =
              _job_id
              AND occupied_assignment.slot_id =
                future_slot.id
          )
      ) AS future_candidate_count
    FROM candidate_matches
  )
  SELECT
    scored_matches.match_id,
    scored_matches.round_number,
    scored_matches.group_number,
    scored_matches.slot_number,
    scored_matches.round_group_usage,
    scored_matches.group_day_usage,
    scored_matches.future_candidate_count
  FROM scored_matches
  ORDER BY
    scored_matches.round_number,
    scored_matches.round_group_usage,
    scored_matches.group_day_usage,
    scored_matches.future_candidate_count,
    scored_matches.priority_weight DESC,
    scored_matches.group_number,
    scored_matches.slot_number,
    scored_matches.match_id;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_match_relocation_candidate_slots(_job_id uuid, _match_id uuid, _origin_slot_id bigint DEFAULT NULL::bigint, _excluded_slot_ids bigint[] DEFAULT ARRAY[]::bigint[], _maximum_candidates integer DEFAULT 300)
 RETURNS TABLE(slot_id bigint, event_date date, start_at timestamp with time zone, end_at timestamp with time zone, location_key uuid, court_key uuid, sequence_index integer, day_distance integer, time_distance_seconds numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH origin_context AS (
    SELECT
      origin_slot.event_date,
      origin_slot.start_at
    FROM championship_bracket_preview_private.slots AS origin_slot
    WHERE origin_slot.job_id = _job_id
      AND origin_slot.id = _origin_slot_id
  ),

  candidate_slots AS (
    SELECT
      slots_table.id AS slot_id,
      slots_table.event_date,
      slots_table.start_at,
      slots_table.end_at,
      slots_table.location_key,
      slots_table.court_key,
      slots_table.sequence_index,

      CASE
        WHEN origin_context.event_date IS NULL THEN 0
        ELSE abs(
          slots_table.event_date - origin_context.event_date
        )
      END::integer AS day_distance,

      CASE
        WHEN origin_context.start_at IS NULL THEN 0::numeric
        ELSE abs(
          extract(
            epoch FROM (
              slots_table.start_at - origin_context.start_at
            )
          )
        )
      END AS time_distance_seconds

    FROM championship_bracket_preview_private.slots AS slots_table

    LEFT JOIN origin_context
      ON true

    WHERE slots_table.job_id = _job_id

      AND (
        _origin_slot_id IS NULL
        OR slots_table.id <> _origin_slot_id
      )

      
AND NOT (
  slots_table.id = ANY(
    COALESCE(
      _excluded_slot_ids,
      ARRAY[]::BIGINT[]
    )
  )
)

AND NOT EXISTS (
  SELECT 1

  FROM championship_bracket_preview_private.slots AS reserved_slot

  WHERE reserved_slot.job_id = _job_id

    AND reserved_slot.id = ANY(
      COALESCE(
        _excluded_slot_ids,
        ARRAY[]::BIGINT[]
      )
    )

    AND reserved_slot.court_key = slots_table.court_key

    AND reserved_slot.start_at < slots_table.end_at
    AND reserved_slot.end_at > slots_table.start_at
)

AND championship_bracket_preview_private.is_match_slot_static_eligible(
  _job_id,
  _match_id,
  slots_table.id
)
  )

SELECT candidate_slots.slot_id, candidate_slots.event_date, candidate_slots.start_at, candidate_slots.end_at, candidate_slots.location_key, candidate_slots.court_key, candidate_slots.sequence_index, candidate_slots.day_distance, candidate_slots.time_distance_seconds
FROM candidate_slots
ORDER BY

/*
 * Primeiro tentamos preservar o dia original.
 */
candidate_slots.day_distance,

/*
 * Dentro dele, tentamos horários próximos.
 *
 * Se isso não resolver, a consulta continua naturalmente
 * para horários mais distantes e posteriormente outros dias.
 */
candidate_slots.time_distance_seconds,
candidate_slots.event_date,
candidate_slots.start_at,
candidate_slots.location_key,
candidate_slots.court_key,
candidate_slots.sequence_index,
candidate_slots.slot_id
LIMIT greatest(
        COALESCE(_maximum_candidates, 300),
        1
    );

$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_match_relocation_candidate_slots_ranked(_job_id uuid, _match_id uuid, _origin_slot_id bigint DEFAULT NULL::bigint, _excluded_slot_ids bigint[] DEFAULT ARRAY[]::bigint[], _after_rank bigint DEFAULT 0, _maximum_candidates integer DEFAULT 300)
 RETURNS TABLE(candidate_rank bigint, slot_id bigint, event_date date, start_at timestamp with time zone, end_at timestamp with time zone, location_key uuid, court_key uuid, sequence_index integer, day_distance integer, time_distance_seconds numeric, direct_eligible boolean, total_blocker_count integer, hard_blocker_count integer, capacity_blocker_count integer, relocation_cost integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH candidate_base AS (
    SELECT candidate_slot.*
    FROM championship_bracket_preview_private.resolve_match_relocation_candidate_slots(
      _job_id,
      _match_id,
      _origin_slot_id,
      _excluded_slot_ids,
      1000000
    ) AS candidate_slot
  ),
  scored_raw AS (
    SELECT
      candidate_base.*,
      championship_bracket_preview_private.is_match_slot_eligible(
        _job_id,
        _match_id,
        candidate_base.slot_id,
        true
      ) AS direct_eligible,
      blocker_stats.total_blocker_count,
      blocker_stats.hard_blocker_count,
      blocker_stats.earlier_round_blocker_count,
      blocker_stats.occupation_blocker_count,
      blocker_stats.rest_blocker_count,
      blocker_stats.round_order_blocker_count,
      blocker_stats.capacity_blocker_count
    FROM candidate_base
    JOIN championship_bracket_preview_private.slots AS slot_context
      ON slot_context.job_id = _job_id
      AND slot_context.id = candidate_base.slot_id
    JOIN championship_bracket_preview_private.jobs AS job_context
      ON job_context.id = _job_id
    CROSS JOIN LATERAL
      championship_bracket_preview_private.resolve_slot_sport_target(
        job_context.payload,
        slot_context.event_date,
        slot_context.court_key,
        slot_context.sport_id
      ) AS target_state
    CROSS JOIN LATERAL (
      SELECT
        count(*)::integer AS total_blocker_count,
        count(*) FILTER (
          WHERE blockers.blocker_reasons && ARRAY[
            'EARLIER_ROUND_PENDING',
            'COURT_OCCUPATION',
            'TEAM_REST_CONSTRAINT',
            'ROUND_ORDER_CONSTRAINT'
          ]::TEXT[]
        )::integer AS hard_blocker_count,
        count(*) FILTER (
          WHERE 'EARLIER_ROUND_PENDING' = ANY(blockers.blocker_reasons)
        )::integer AS earlier_round_blocker_count,
        count(*) FILTER (
          WHERE 'COURT_OCCUPATION' = ANY(blockers.blocker_reasons)
        )::integer AS occupation_blocker_count,
        count(*) FILTER (
          WHERE 'TEAM_REST_CONSTRAINT' = ANY(blockers.blocker_reasons)
        )::integer AS rest_blocker_count,
        count(*) FILTER (
          WHERE 'ROUND_ORDER_CONSTRAINT' = ANY(blockers.blocker_reasons)
        )::integer AS round_order_blocker_count,
        count(*) FILTER (
          WHERE 'TARGET_CAPACITY' = ANY(blockers.blocker_reasons)
        )::integer AS capacity_blocker_count
      FROM championship_bracket_preview_private.resolve_match_slot_blockers(
        _job_id,
        _match_id,
        candidate_base.slot_id
      ) AS blockers
      WHERE blockers.blocker_match_id <> _match_id
    ) AS blocker_stats
    WHERE
      NOT target_state.has_sport_targets
      OR COALESCE(target_state.planned_match_count, 0) > 0
  ),
  scored AS (
    SELECT
      scored_raw.*,
      (
        scored_raw.hard_blocker_count * 100
        + scored_raw.earlier_round_blocker_count * 40
        + scored_raw.round_order_blocker_count * 30
        + scored_raw.rest_blocker_count * 20
        + scored_raw.occupation_blocker_count * 10
        + CASE
            WHEN scored_raw.capacity_blocker_count > 0
              THEN 15 + least(scored_raw.capacity_blocker_count, 5)
            ELSE 0
          END
      )::integer AS relocation_cost
    FROM scored_raw
  ),
  ranked AS (
    SELECT
      row_number() OVER (
        ORDER BY
          CASE
            WHEN scored.direct_eligible THEN 0
            ELSE 1
          END,
          scored.relocation_cost,
          scored.hard_blocker_count,
          CASE
            WHEN scored.capacity_blocker_count > 0 THEN 1
            ELSE 0
          END,
          scored.total_blocker_count,
          scored.day_distance,
          scored.time_distance_seconds,
          scored.event_date,
          scored.start_at,
          scored.location_key,
          scored.court_key,
          scored.sequence_index,
          scored.slot_id
      ) AS candidate_rank,
      scored.*
    FROM scored
  )
  SELECT
    ranked.candidate_rank,
    ranked.slot_id,
    ranked.event_date,
    ranked.start_at,
    ranked.end_at,
    ranked.location_key,
    ranked.court_key,
    ranked.sequence_index,
    ranked.day_distance,
    ranked.time_distance_seconds,
    ranked.direct_eligible,
    ranked.total_blocker_count,
    ranked.hard_blocker_count,
    ranked.capacity_blocker_count,
    ranked.relocation_cost
  FROM ranked
  WHERE ranked.candidate_rank >
    greatest(COALESCE(_after_rank, 0), 0)
  ORDER BY ranked.candidate_rank
  LIMIT greatest(
    COALESCE(_maximum_candidates, 300),
    1
  );
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_match_relocation_candidate_slots_ranked_v7(_job_id uuid, _match_id uuid, _origin_slot_id bigint DEFAULT NULL::bigint, _excluded_slot_ids bigint[] DEFAULT ARRAY[]::bigint[], _after_rank bigint DEFAULT 0, _maximum_candidates integer DEFAULT 300, _required_gap integer DEFAULT 4)
 RETURNS TABLE(candidate_rank bigint, slot_id bigint, event_date date, start_at timestamp with time zone, end_at timestamp with time zone, location_key uuid, court_key uuid, sequence_index integer, day_distance integer, time_distance_seconds numeric, direct_eligible boolean, total_blocker_count integer, hard_blocker_count integer, capacity_blocker_count integer, relocation_cost integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH candidate_base AS (
    SELECT candidate_slot.*
    FROM championship_bracket_preview_private.resolve_match_relocation_candidate_slots(
      _job_id,
      _match_id,
      _origin_slot_id,
      _excluded_slot_ids,
      1000000
    ) AS candidate_slot
  ),
  scored_raw AS (
    SELECT
      candidate_base.*,
      championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
        _job_id,
        _match_id,
        candidate_base.slot_id,
        GREATEST(
          COALESCE(_required_gap, 4),
          1
        )
      ) AS direct_eligible,
      blocker_stats.total_blocker_count,
      blocker_stats.hard_blocker_count,
      blocker_stats.earlier_round_blocker_count,
      blocker_stats.occupation_blocker_count,
      blocker_stats.rest_blocker_count,
      blocker_stats.round_order_blocker_count,
      blocker_stats.capacity_blocker_count
    FROM candidate_base
    JOIN championship_bracket_preview_private.slots
      AS slot_context
      ON slot_context.job_id = _job_id
      AND slot_context.id =
        candidate_base.slot_id
    JOIN championship_bracket_preview_private.jobs
      AS job_context
      ON job_context.id = _job_id
    CROSS JOIN LATERAL
      championship_bracket_preview_private.resolve_slot_sport_target(
        job_context.payload,
        slot_context.event_date,
        slot_context.court_key,
        slot_context.sport_id
      ) AS target_state
    CROSS JOIN LATERAL (
      SELECT
        count(*)::integer AS total_blocker_count,
        count(*) FILTER (
          WHERE blockers.blocker_reasons && ARRAY[
            'EARLIER_ROUND_PENDING',
            'COURT_OCCUPATION',
            'TEAM_REST_CONSTRAINT',
            'ROUND_ORDER_CONSTRAINT'
          ]::TEXT[]
        )::integer AS hard_blocker_count,
        count(*) FILTER (
          WHERE
            'EARLIER_ROUND_PENDING' =
              ANY(blockers.blocker_reasons)
        )::integer AS earlier_round_blocker_count,
        count(*) FILTER (
          WHERE
            'COURT_OCCUPATION' =
              ANY(blockers.blocker_reasons)
        )::integer AS occupation_blocker_count,
        count(*) FILTER (
          WHERE
            'TEAM_REST_CONSTRAINT' =
              ANY(blockers.blocker_reasons)
        )::integer AS rest_blocker_count,
        count(*) FILTER (
          WHERE
            'ROUND_ORDER_CONSTRAINT' =
              ANY(blockers.blocker_reasons)
        )::integer AS round_order_blocker_count,
        count(*) FILTER (
          WHERE
            'TARGET_CAPACITY' =
              ANY(blockers.blocker_reasons)
        )::integer AS capacity_blocker_count
      FROM championship_bracket_preview_private.resolve_match_slot_blockers_with_rest_gap(
        _job_id,
        _match_id,
        candidate_base.slot_id,
        GREATEST(
          COALESCE(_required_gap, 4),
          1
        )
      ) AS blockers
      WHERE blockers.blocker_match_id <> _match_id
    ) AS blocker_stats
    WHERE
      NOT target_state.has_sport_targets
      OR COALESCE(
        target_state.planned_match_count,
        0
      ) > 0
  ),
  scored AS (
    SELECT
      scored_raw.*,
      (
        scored_raw.hard_blocker_count * 100
        + scored_raw.earlier_round_blocker_count * 40
        + scored_raw.round_order_blocker_count * 30
        + scored_raw.rest_blocker_count * 20
        + scored_raw.occupation_blocker_count * 10
        + CASE
            WHEN scored_raw.capacity_blocker_count > 0
            THEN
              15
              + least(
                scored_raw.capacity_blocker_count,
                5
              )
            ELSE 0
          END
      )::integer AS relocation_cost
    FROM scored_raw
  ),
  ranked AS (
    SELECT
      row_number() OVER (
        ORDER BY
          CASE
            WHEN scored.direct_eligible
              THEN 0
            ELSE 1
          END,
          scored.relocation_cost,
          scored.hard_blocker_count,
          CASE
            WHEN scored.capacity_blocker_count > 0
              THEN 1
            ELSE 0
          END,
          scored.total_blocker_count,
          scored.day_distance,
          scored.time_distance_seconds,
          scored.event_date,
          scored.start_at,
          scored.location_key,
          scored.court_key,
          scored.sequence_index,
          scored.slot_id
      ) AS candidate_rank,
      scored.*
    FROM scored
  )
  SELECT
    ranked.candidate_rank,
    ranked.slot_id,
    ranked.event_date,
    ranked.start_at,
    ranked.end_at,
    ranked.location_key,
    ranked.court_key,
    ranked.sequence_index,
    ranked.day_distance,
    ranked.time_distance_seconds,
    ranked.direct_eligible,
    ranked.total_blocker_count,
    ranked.hard_blocker_count,
    ranked.capacity_blocker_count,
    ranked.relocation_cost
  FROM ranked
  WHERE ranked.candidate_rank >
    greatest(
      COALESCE(_after_rank, 0),
      0
    )
  ORDER BY ranked.candidate_rank
  LIMIT greatest(
    COALESCE(
      _maximum_candidates,
      300
    ),
    1
  );
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_match_slot_blockers(_job_id uuid, _match_id uuid, _slot_id bigint)
 RETURNS TABLE(blocker_match_id uuid, blocker_slot_id bigint, blocker_is_assigned boolean, blocker_reasons text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH context AS (
    SELECT
      jobs_table.payload,

      matches_table.id AS match_id,
      matches_table.competition_id,
      matches_table.group_id,
      matches_table.round_number,

      competitions_table.sport_id,

      slots_table.id AS slot_id,
      slots_table.event_date,
      slots_table.court_key,
      slots_table.start_at,
      slots_table.end_at,

      slot_target.has_sport_targets,
      slot_target.planned_match_count

    FROM championship_bracket_preview_private.jobs AS jobs_table

    JOIN championship_bracket_preview_private.matches AS matches_table
      ON matches_table.job_id = jobs_table.id
      AND matches_table.id = _match_id

    JOIN championship_bracket_preview_private.competitions AS competitions_table
      ON competitions_table.id = matches_table.competition_id

    JOIN championship_bracket_preview_private.slots AS slots_table
      ON slots_table.job_id = jobs_table.id
      AND slots_table.id = _slot_id
      AND slots_table.sport_id = competitions_table.sport_id

    CROSS JOIN LATERAL
      championship_bracket_preview_private.resolve_slot_sport_target(
        jobs_table.payload,
        slots_table.event_date,
        slots_table.court_key,
        slots_table.sport_id
      ) AS slot_target

    WHERE jobs_table.id = _job_id
  ),

/*
 * 1. Outro jogo já ocupa fisicamente a mesma quadra
 *    no mesmo intervalo.
 */


occupation_blockers AS (
    SELECT
      occupied_assignment.match_id AS blocker_match_id,
      occupied_assignment.slot_id AS blocker_slot_id,
      true AS blocker_is_assigned,
      'COURT_OCCUPATION'::text AS blocker_reason

    FROM context

    JOIN championship_bracket_preview_private.assignments
      AS occupied_assignment
      ON occupied_assignment.job_id = _job_id
      AND occupied_assignment.match_id <> _match_id

    JOIN championship_bracket_preview_private.slots
      AS occupied_slot
      ON occupied_slot.id = occupied_assignment.slot_id

    WHERE occupied_slot.court_key = context.court_key
      AND occupied_slot.start_at < context.end_at
      AND occupied_slot.end_at > context.start_at
  ),

/*
 * 2. Jogos que impedem o encaixe pela regra atual de
 *    descanso da atlética.
 *
 *    Importante:
 *    a regra de descanso NÃO é alterada aqui.
 */


rest_blockers AS (
    SELECT
      previous_assignment.match_id AS blocker_match_id,
      previous_assignment.slot_id AS blocker_slot_id,
      true AS blocker_is_assigned,
      'TEAM_REST_CONSTRAINT'::text AS blocker_reason

    FROM championship_bracket_preview_private.assignments
      AS previous_assignment

    WHERE previous_assignment.job_id = _job_id
      AND previous_assignment.match_id <> _match_id

      AND championship_bracket_preview_private.is_match_rest_conflict(
        _job_id,
        _match_id,
        _slot_id,
        previous_assignment.match_id
      )
  ),

/*
 * 3. Rodadas anteriores que ainda não foram encaixadas.
 *
 *    Esses jogos também são considerados dependências do
 *    candidato. O solver poderá tentar encaixá-los antes.
 */


pending_round_blockers AS (
    SELECT
      earlier_match.id AS blocker_match_id,
      NULL::bigint AS blocker_slot_id,
      false AS blocker_is_assigned,
      'EARLIER_ROUND_PENDING'::text AS blocker_reason

    FROM context

    JOIN championship_bracket_preview_private.matches
      AS earlier_match
      ON earlier_match.job_id = _job_id
      AND earlier_match.id <> _match_id
      AND earlier_match.competition_id = context.competition_id
      AND earlier_match.group_id = context.group_id
      AND earlier_match.round_number < context.round_number
      AND earlier_match.assigned = false
  ),

/*
 * 4. Jogos já programados cuja posição cronológica entra em
 *    conflito com a rodada do candidato.
 */


assigned_round_blockers AS (
    SELECT
      ordered_match.id AS blocker_match_id,
      ordered_assignment.slot_id AS blocker_slot_id,
      true AS blocker_is_assigned,
      'ROUND_ORDER_CONSTRAINT'::text AS blocker_reason

    FROM context

    JOIN championship_bracket_preview_private.matches
      AS ordered_match
      ON ordered_match.job_id = _job_id
      AND ordered_match.id <> _match_id
      AND ordered_match.competition_id = context.competition_id
      AND ordered_match.group_id = context.group_id

    JOIN championship_bracket_preview_private.assignments
      AS ordered_assignment
      ON ordered_assignment.job_id = _job_id
      AND ordered_assignment.match_id = ordered_match.id

    JOIN championship_bracket_preview_private.slots
      AS ordered_slot
      ON ordered_slot.id = ordered_assignment.slot_id

    WHERE (
      (
        ordered_match.round_number < context.round_number
        AND ordered_slot.end_at > context.start_at
      )
      OR
      (
        ordered_match.round_number > context.round_number
        AND context.end_at > ordered_slot.start_at
      )
    )
  ),

/*
 * 5. Verifica se a meta de jogos daquela combinação
 *    dia + quadra + modalidade já foi totalmente ocupada.
 */
target_capacity_state AS (
    SELECT context.*, (
            SELECT count(*)
            FROM
                championship_bracket_preview_private.assignments AS target_assignment
                JOIN championship_bracket_preview_private.slots AS target_slot ON target_slot.id = target_assignment.slot_id
            WHERE
                target_assignment.job_id = _job_id
                AND target_assignment.match_id <> _match_id
                AND target_slot.event_date = context.event_date
                AND target_slot.court_key = context.court_key
                AND target_slot.sport_id = context.sport_id
        ) AS assigned_target_count
    FROM context
),

/*
 * Se a meta já estiver cheia, qualquer um dos jogos atualmente
 * ocupando aquela meta pode ser candidato a realocação.
 */


target_capacity_blockers AS (
    SELECT
      target_assignment.match_id AS blocker_match_id,
      target_assignment.slot_id AS blocker_slot_id,
      true AS blocker_is_assigned,
      'TARGET_CAPACITY'::text AS blocker_reason

    FROM target_capacity_state AS target_state

    JOIN championship_bracket_preview_private.assignments
      AS target_assignment
      ON target_assignment.job_id = _job_id
      AND target_assignment.match_id <> _match_id

    JOIN championship_bracket_preview_private.slots
      AS target_slot
      ON target_slot.id = target_assignment.slot_id

    WHERE target_state.has_sport_targets
      AND COALESCE(target_state.planned_match_count, 0)
        <= target_state.assigned_target_count

      AND target_slot.event_date = target_state.event_date
      AND target_slot.court_key = target_state.court_key
      AND target_slot.sport_id = target_state.sport_id
  ),

  all_blockers AS (
    SELECT * FROM occupation_blockers

    UNION ALL

    SELECT * FROM rest_blockers

    UNION ALL

    SELECT * FROM pending_round_blockers

    UNION ALL

    SELECT * FROM assigned_round_blockers

    UNION ALL

    SELECT * FROM target_capacity_blockers
  )

SELECT
    all_blockers.blocker_match_id,
    all_blockers.blocker_slot_id,
    all_blockers.blocker_is_assigned,
    array_agg (
        DISTINCT all_blockers.blocker_reason
        ORDER BY all_blockers.blocker_reason
    ) AS blocker_reasons
FROM all_blockers
GROUP BY
    all_blockers.blocker_match_id,
    all_blockers.blocker_slot_id,
    all_blockers.blocker_is_assigned
ORDER BY all_blockers.blocker_is_assigned DESC, all_blockers.blocker_match_id;

$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_match_slot_blockers_with_rest_gap(_job_id uuid, _match_id uuid, _slot_id bigint, _required_gap integer DEFAULT 3)
 RETURNS TABLE(blocker_match_id uuid, blocker_slot_id bigint, blocker_is_assigned boolean, blocker_reasons text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH adjusted AS (
    SELECT
      blockers.blocker_match_id,
      blockers.blocker_slot_id,
      blockers.blocker_is_assigned,
      CASE
        WHEN
          'TEAM_REST_CONSTRAINT' =
            ANY(blockers.blocker_reasons)
          AND NOT championship_bracket_preview_private.is_match_rest_conflict_with_gap(
            _job_id,
            _match_id,
            _slot_id,
            blockers.blocker_match_id,
            GREATEST(
              COALESCE(_required_gap, 3),
              1
            )
          )
        THEN array_remove(
          blockers.blocker_reasons,
          'TEAM_REST_CONSTRAINT'
        )
        ELSE blockers.blocker_reasons
      END AS blocker_reasons
    FROM championship_bracket_preview_private.resolve_match_slot_blockers(
      _job_id,
      _match_id,
      _slot_id
    ) AS blockers
  )
  SELECT
    adjusted.blocker_match_id,
    adjusted.blocker_slot_id,
    adjusted.blocker_is_assigned,
    adjusted.blocker_reasons
  FROM adjusted
  WHERE cardinality(
    adjusted.blocker_reasons
  ) > 0;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_preview_display_match_numbers(_job_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH RECURSIVE scheduled_matches AS (
    SELECT
      matches_table.id AS match_id,
      assignments_table.match_number AS fixed_match_number,
      slots_table.start_at,
      slots_table.location_key,
      slots_table.court_key,
      competitions_table.sport_id,
      competitions_table.naipe,
      COALESCE(
        jobs_table.payload ->> 'match_numbering_mode',
        'COURT'
      ) AS match_numbering_mode
    FROM championship_bracket_preview_private.assignments AS assignments_table
    JOIN championship_bracket_preview_private.matches AS matches_table
      ON matches_table.id = assignments_table.match_id
    JOIN championship_bracket_preview_private.slots AS slots_table
      ON slots_table.id = assignments_table.slot_id
    JOIN championship_bracket_preview_private.competitions AS competitions_table
      ON competitions_table.id = matches_table.competition_id
    JOIN championship_bracket_preview_private.jobs AS jobs_table
      ON jobs_table.id = assignments_table.job_id
    WHERE assignments_table.job_id = _job_id

    UNION ALL

    SELECT
      knockout_matches.id AS match_id,
      NULL::INTEGER AS fixed_match_number,
      knockout_matches.start_at,
      knockout_matches.location_key,
      knockout_matches.court_key,
      competitions_table.sport_id,
      competitions_table.naipe,
      COALESCE(
        jobs_table.payload ->> 'match_numbering_mode',
        'COURT'
      ) AS match_numbering_mode
    FROM championship_bracket_preview_private.knockout_matches
    JOIN championship_bracket_preview_private.competitions AS competitions_table
      ON competitions_table.id = knockout_matches.competition_id
    JOIN championship_bracket_preview_private.jobs AS jobs_table
      ON jobs_table.id = knockout_matches.job_id
    WHERE knockout_matches.job_id = _job_id
      AND NOT knockout_matches.is_bye
      AND knockout_matches.scheduled_date IS NOT NULL
      AND knockout_matches.start_at IS NOT NULL
      AND knockout_matches.location_key IS NOT NULL
      AND knockout_matches.court_key IS NOT NULL
  ),
  ordered_matches AS (
    SELECT
      scheduled_matches.*,
      CASE scheduled_matches.match_numbering_mode
        WHEN 'SPORT_NAIPE' THEN format(
          '%s::%s',
          scheduled_matches.sport_id,
          scheduled_matches.naipe
        )
        WHEN 'SPORT' THEN scheduled_matches.sport_id::TEXT
        ELSE format(
          '%s::%s',
          scheduled_matches.location_key,
          scheduled_matches.court_key
        )
      END AS numbering_key,
      row_number() OVER (
        PARTITION BY CASE scheduled_matches.match_numbering_mode
          WHEN 'SPORT_NAIPE' THEN format(
            '%s::%s',
            scheduled_matches.sport_id,
            scheduled_matches.naipe
          )
          WHEN 'SPORT' THEN scheduled_matches.sport_id::TEXT
          ELSE format(
            '%s::%s',
            scheduled_matches.location_key,
            scheduled_matches.court_key
          )
        END
        ORDER BY
          scheduled_matches.start_at,
          scheduled_matches.location_key,
          scheduled_matches.court_key,
          scheduled_matches.match_id
      ) AS chronology_position
    FROM scheduled_matches
  ),
  numbered_matches AS (
    SELECT
      ordered_matches.*,
      COALESCE(ordered_matches.fixed_match_number, 1) AS display_match_number
    FROM ordered_matches
    WHERE ordered_matches.chronology_position = 1

    UNION ALL

    SELECT
      next_match.*,
      COALESCE(
        next_match.fixed_match_number,
        current_match.display_match_number + 1
      ) AS display_match_number
    FROM numbered_matches AS current_match
    JOIN ordered_matches AS next_match
      ON next_match.numbering_key = current_match.numbering_key
      AND next_match.chronology_position = current_match.chronology_position + 1
  )
  SELECT COALESCE(
    jsonb_object_agg(
      numbered_matches.match_id::TEXT,
      numbered_matches.display_match_number
    ),
    '{}'::JSONB
  )
  FROM numbered_matches;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_slot_sport_target(_payload jsonb, _event_date date, _court_key uuid, _sport_id uuid)
 RETURNS TABLE(has_sport_targets boolean, planned_match_count integer)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  WITH target_court AS (
    SELECT court_item.value AS court
    FROM jsonb_array_elements(COALESCE(_payload -> 'schedule_days', '[]'::jsonb)) day_item(value)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(day_item.value -> 'locations', '[]'::jsonb)) location_item(value)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(location_item.value -> 'courts', '[]'::jsonb)) court_item(value)
    WHERE day_item.value ->> 'date' = _event_date::text
      AND court_item.value ->> 'court_key' = _court_key::text
    LIMIT 1
  )
  SELECT
    COALESCE(
      (SELECT jsonb_array_length(COALESCE(target_court.court -> 'sport_match_targets', '[]'::jsonb)) > 0 FROM target_court),
      false
    ),
    COALESCE((
      SELECT GREATEST(COALESCE((target_item.value ->> 'planned_match_count')::integer, 0), 0)
      FROM target_court
      CROSS JOIN LATERAL jsonb_array_elements(
        COALESCE(target_court.court -> 'sport_match_targets', '[]'::jsonb)
      ) target_item(value)
      WHERE target_item.value ->> 'sport_id' = _sport_id::text
      LIMIT 1
    ), 0);
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_v8_internal_empty_diagnostics(_job_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH scheduled AS (
    SELECT
      assignments_table.match_id::text AS match_key,
      slots_table.event_date,
      slots_table.location_key,
      slots_table.court_key,
      slots_table.start_at,
      slots_table.end_at
    FROM championship_bracket_preview_private.assignments assignments_table
    JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id = assignments_table.slot_id
    WHERE assignments_table.job_id = _job_id
    UNION ALL
    SELECT
      knockout_matches.id::text AS match_key,
      knockout_matches.scheduled_date,
      knockout_matches.location_key,
      knockout_matches.court_key,
      knockout_matches.start_at,
      knockout_matches.end_at
    FROM championship_bracket_preview_private.knockout_matches knockout_matches
    WHERE knockout_matches.job_id = _job_id
      AND NOT knockout_matches.is_bye
      AND knockout_matches.scheduled_date IS NOT NULL
      AND knockout_matches.location_key IS NOT NULL
      AND knockout_matches.court_key IS NOT NULL
      AND knockout_matches.start_at IS NOT NULL
      AND knockout_matches.end_at IS NOT NULL
  ), assigned AS (
    SELECT
      scheduled.*,
      lead(scheduled.start_at) OVER (
        PARTITION BY scheduled.event_date, scheduled.location_key, scheduled.court_key
        ORDER BY scheduled.start_at, scheduled.end_at, scheduled.match_key
      ) AS next_start_at
    FROM scheduled
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'code', 'INTERNAL_EMPTY_WINDOW',
    'message', format('A quadra %s possui uma janela interna vazia entre %s e %s.', assigned.court_key, assigned.end_at, assigned.next_start_at),
    'date', assigned.event_date,
    'court_key', assigned.court_key,
    'start_at', assigned.end_at,
    'end_at', assigned.next_start_at
  ) ORDER BY assigned.event_date, assigned.court_key, assigned.end_at), '[]'::jsonb)
  FROM assigned
  WHERE assigned.next_start_at > assigned.end_at
    AND EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.jobs jobs_table
      CROSS JOIN LATERAL championship_bracket_preview_private.resolve_court_free_intervals(
        jobs_table.payload,
        assigned.event_date,
        assigned.location_key,
        assigned.court_key
      ) AS free_intervals
      WHERE jobs_table.id = _job_id
        AND free_intervals.start_at <= assigned.end_at
        AND free_intervals.end_at >= assigned.next_start_at
    )
    ;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_v8_knockout_court_windows(_job_id uuid, _sport_id uuid)
 RETURNS TABLE(event_date date, location_key uuid, location_name text, location_position integer, court_key uuid, court_name text, court_position integer, free_start_at timestamp with time zone, free_end_at timestamp with time zone)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  SELECT
    courts.event_date, courts.location_key, courts.location_name, courts.location_position,
    courts.court_key, courts.court_name, courts.court_position,
    free_intervals.start_at, free_intervals.end_at
  FROM championship_bracket_preview_private.jobs jobs_table
  CROSS JOIN LATERAL (
    SELECT DISTINCT
      (day_item.value ->> 'date')::date AS event_date,
      (location_item.value ->> 'location_key')::uuid AS location_key,
      location_item.value ->> 'name' AS location_name,
      COALESCE((location_item.value ->> 'position')::integer, location_item.ordinality::integer) AS location_position,
      (court_item.value ->> 'court_key')::uuid AS court_key,
      court_item.value ->> 'name' AS court_name,
      COALESCE((court_item.value ->> 'position')::integer, court_item.ordinality::integer) AS court_position
    FROM jsonb_array_elements(COALESCE(jobs_table.payload -> 'schedule_days', '[]'::jsonb)) WITH ORDINALITY day_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(day_item.value -> 'locations', '[]'::jsonb)) WITH ORDINALITY location_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(location_item.value -> 'courts', '[]'::jsonb)) WITH ORDINALITY court_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(court_item.value -> 'sport_ids', '[]'::jsonb)) sport_item(value)
    WHERE trim(both '"' from sport_item.value::text)::uuid = _sport_id
  ) courts
  CROSS JOIN LATERAL championship_bracket_preview_private.resolve_court_free_intervals(
    jobs_table.payload, courts.event_date, courts.location_key, courts.court_key
  ) free_intervals
  WHERE jobs_table.id = _job_id;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_v8_knockout_seed_source(_groups_count integer, _qualifiers_per_group integer, _include_best_second_pool boolean, _use_cross_groups_pairing boolean, _seed_number integer, _qualified_count integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  group_number_value INTEGER;
  position_value INTEGER;
BEGIN
  IF _seed_number > _qualified_count THEN
    RETURN jsonb_build_object(
      'type', 'BYE',
      'reference', format('BYE_SEED_%s', _seed_number)
    );
  END IF;

  IF _use_cross_groups_pairing THEN
    group_number_value := ((_seed_number - 1) / 2) + 1;
    position_value := ((_seed_number - 1) % 2) + 1;

    RETURN jsonb_build_object(
      'type', 'GROUP_POSITION',
      'reference', format(
        'GROUP_%s_POSITION_%s',
        group_number_value,
        position_value
      )
    );
  END IF;

  IF _qualifiers_per_group = 1 THEN
    IF _seed_number <= _groups_count THEN
      RETURN jsonb_build_object(
        'type', 'BEST_FIRST_POOL',
        'reference', format(
          'BEST_FIRST_POOL_POSITION_%s',
          _seed_number
        )
      );
    END IF;

    IF _include_best_second_pool THEN
      RETURN jsonb_build_object(
        'type', 'BEST_SECOND_POOL',
        'reference', format(
          'BEST_SECOND_POOL_POSITION_%s',
          _seed_number - _groups_count
        )
      );
    END IF;

    RETURN jsonb_build_object(
      'type', 'BYE',
      'reference', format('BYE_SEED_%s', _seed_number)
    );
  END IF;

  IF _seed_number <= _groups_count * _qualifiers_per_group THEN
    group_number_value :=
      ((_seed_number - 1) % _groups_count) + 1;

    position_value :=
      ((_seed_number - 1) / _groups_count) + 1;

    RETURN jsonb_build_object(
      'type', 'GROUP_POSITION',
      'reference', format(
        'GROUP_%s_POSITION_%s',
        group_number_value,
        position_value
      )
    );
  END IF;

  IF _qualifiers_per_group = 2 THEN
    RETURN jsonb_build_object(
      'type', 'BEST_THIRD_POOL',
      'reference', format(
        'BEST_THIRD_POOL_POSITION_%s',
        _seed_number - (_groups_count * 2)
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'type', 'BYE',
    'reference', format('BYE_SEED_%s', _seed_number)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_v8_sport_targets(_job_id uuid)
 RETURNS TABLE(event_date date, court_key uuid, court_name text, sport_id uuid, sport_name text, planned_match_count integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  SELECT
    court_dimensions.event_date,
    court_dimensions.court_key,
    court_dimensions.court_name,
    court_dimensions.sport_id,
    COALESCE(sports_table.name, court_dimensions.sport_id::text),
    target_resolution.planned_match_count
  FROM championship_bracket_preview_private.jobs jobs_table
  CROSS JOIN LATERAL (
    SELECT DISTINCT
      (day_item.value ->> 'date')::date AS event_date,
      (court_item.value ->> 'court_key')::uuid AS court_key,
      court_item.value ->> 'name' AS court_name,
      (target_item.value ->> 'sport_id')::uuid AS sport_id
    FROM jsonb_array_elements(COALESCE(jobs_table.payload -> 'schedule_days', '[]'::jsonb)) day_item(value)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(day_item.value -> 'locations', '[]'::jsonb)) location_item(value)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(location_item.value -> 'courts', '[]'::jsonb)) court_item(value)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(court_item.value -> 'sport_match_targets', '[]'::jsonb)) target_item(value)
  ) AS court_dimensions
  CROSS JOIN LATERAL championship_bracket_preview_private.resolve_slot_sport_target(
    jobs_table.payload,
    court_dimensions.event_date,
    court_dimensions.court_key,
    court_dimensions.sport_id
  ) AS target_resolution
  LEFT JOIN public.sports sports_table ON sports_table.id = court_dimensions.sport_id
  WHERE jobs_table.id = _job_id
    AND target_resolution.has_sport_targets;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_v8_target_completion_diagnostics(_job_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH targets AS (
    SELECT *
    FROM championship_bracket_preview_private.resolve_v8_sport_targets(
      _job_id
    )
  ),
  target_usage AS (
    SELECT
      targets.*,
      count(assignments_table.match_id)::integer AS assigned_match_count
    FROM targets
    LEFT JOIN championship_bracket_preview_private.slots
      AS slots_table
      ON slots_table.job_id = _job_id
      AND slots_table.event_date =
        targets.event_date
      AND slots_table.court_key =
        targets.court_key
      AND slots_table.sport_id =
        targets.sport_id
    LEFT JOIN championship_bracket_preview_private.assignments
      AS assignments_table
      ON assignments_table.job_id = _job_id
      AND assignments_table.slot_id =
        slots_table.id
    GROUP BY
      targets.event_date,
      targets.court_key,
      targets.court_name,
      targets.sport_id,
      targets.sport_name,
      targets.planned_match_count
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'code',
        'SPORT_MATCH_TARGET_EXCEEDED',
        'message',
        format(
          '%s em %s para %s permite %s jogos, mas recebeu %s partidas de grupos.',
          court_name,
          event_date,
          sport_name,
          planned_match_count,
          assigned_match_count
        ),
        'date',
        event_date,
        'court_key',
        court_key,
        'court_name',
        court_name,
        'sport_id',
        sport_id,
        'sport_name',
        sport_name,
        'target',
        planned_match_count,
        'obtained',
        assigned_match_count
      )
      ORDER BY
        event_date,
        court_name,
        sport_name
    ),
    '[]'::jsonb
  )
  FROM target_usage
  WHERE assigned_match_count
    > planned_match_count;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.resolve_v8_target_preflight(_job_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH targets AS (
    SELECT *
    FROM championship_bracket_preview_private.resolve_v8_sport_targets(
      _job_id
    )
  ),
  target_usage AS (
    SELECT
      targets.event_date,
      targets.court_key,
      targets.court_name,
      targets.sport_id,
      targets.sport_name,
      targets.planned_match_count,
      count(slots_table.id)::integer
        AS structural_match_count
    FROM targets
    LEFT JOIN championship_bracket_preview_private.slots
      AS slots_table
      ON slots_table.job_id = _job_id
      AND slots_table.event_date = targets.event_date
      AND slots_table.court_key = targets.court_key
      AND slots_table.sport_id = targets.sport_id
      AND NOT slots_table.structural_manual_final
    GROUP BY
      targets.event_date,
      targets.court_key,
      targets.court_name,
      targets.sport_id,
      targets.sport_name,
      targets.planned_match_count
  ),
  group_matches AS (
    SELECT
      competitions_table.id AS competition_id,
      competitions_table.competition_key,
      competitions_table.sport_name,
      competitions_table.naipe,
      competitions_table.division,
      count(matches_table.id)::integer
        AS match_count
    FROM championship_bracket_preview_private.competitions
      AS competitions_table
    LEFT JOIN championship_bracket_preview_private.matches
      AS matches_table
      ON matches_table.job_id = _job_id
      AND matches_table.competition_id =
        competitions_table.id
    WHERE competitions_table.job_id = _job_id
    GROUP BY
      competitions_table.id,
      competitions_table.competition_key,
      competitions_table.sport_name,
      competitions_table.naipe,
      competitions_table.division
  ),
  group_slots AS (
    SELECT
      slots_table.structural_competition_id
        AS competition_id,
      count(*)::integer
        AS slot_count
    FROM championship_bracket_preview_private.slots
      AS slots_table
    WHERE slots_table.job_id = _job_id
      AND slots_table.structural_phase =
        'GROUP_STAGE'
    GROUP BY
      slots_table.structural_competition_id
  ),
  slot_overlaps AS (
    SELECT
      first_slot.event_date,
      first_slot.court_key,
      first_slot.court_name,
      first_slot.structural_slot_key
        AS first_slot_key,
      second_slot.structural_slot_key
        AS second_slot_key
    FROM championship_bracket_preview_private.slots
      AS first_slot
    JOIN championship_bracket_preview_private.slots
      AS second_slot
      ON second_slot.job_id = first_slot.job_id
      AND second_slot.id > first_slot.id
      AND second_slot.event_date =
        first_slot.event_date
      AND second_slot.court_key =
        first_slot.court_key
      AND second_slot.start_at <
        first_slot.end_at
      AND second_slot.end_at >
        first_slot.start_at
    WHERE first_slot.job_id = _job_id
  )
  SELECT COALESCE(
    jsonb_agg(
      diagnostic
      ORDER BY
        diagnostic ->> 'code',
        diagnostic ->> 'date',
        diagnostic ->> 'court_name'
    ),
    '[]'::jsonb
  )
  FROM (
    SELECT jsonb_build_object(
      'code',
      'STRUCTURAL_TARGET_MISMATCH',
      'message',
      format(
        '%s em %s para %s possui target %s, mas o manifesto estrutural possui %s slots.',
        target_usage.court_name,
        target_usage.event_date,
        target_usage.sport_name,
        target_usage.planned_match_count,
        target_usage.structural_match_count
      ),
      'date',
      target_usage.event_date,
      'court_key',
      target_usage.court_key,
      'court_name',
      target_usage.court_name,
      'sport_id',
      target_usage.sport_id,
      'sport_name',
      target_usage.sport_name,
      'target',
      target_usage.planned_match_count,
      'obtained',
      target_usage.structural_match_count
    ) AS diagnostic
    FROM target_usage
    WHERE target_usage.structural_match_count
      <> target_usage.planned_match_count

    UNION ALL

    SELECT jsonb_build_object(
      'code',
      'STRUCTURAL_GROUP_SLOT_COUNT_MISMATCH',
      'message',
      format(
        '%s possui %s partidas de grupos, mas o manifesto reservou %s slots de grupos.',
        group_matches.competition_key,
        group_matches.match_count,
        COALESCE(
          group_slots.slot_count,
          0
        )
      ),
      'competition_key',
      group_matches.competition_key,
      'target',
      group_matches.match_count,
      'obtained',
      COALESCE(
        group_slots.slot_count,
        0
      )
    )
    FROM group_matches
    LEFT JOIN group_slots
      ON group_slots.competition_id =
        group_matches.competition_id
    WHERE COALESCE(
      group_slots.slot_count,
      0
    ) <> group_matches.match_count

    UNION ALL

    SELECT jsonb_build_object(
      'code',
      'STRUCTURAL_SLOT_OVERLAP',
      'message',
      format(
        'A quadra %s em %s possui slots estruturais sobrepostos.',
        slot_overlaps.court_name,
        slot_overlaps.event_date
      ),
      'date',
      slot_overlaps.event_date,
      'court_key',
      slot_overlaps.court_key,
      'court_name',
      slot_overlaps.court_name,
      'first_slot_key',
      slot_overlaps.first_slot_key,
      'second_slot_key',
      slot_overlaps.second_slot_key
    )
    FROM slot_overlaps
  ) AS diagnostics_result;
$function$;

SET check_function_bodies = on;
