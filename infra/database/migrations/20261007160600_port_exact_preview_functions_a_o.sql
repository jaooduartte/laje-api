-- LAJE-126: A-O
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.apply_v8_structural_knockout_schedule(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  diagnostics JSONB := '[]'::jsonb;
BEGIN
  PERFORM championship_bracket_preview_private.create_v8_knockout_matches(
    _job_id
  );

  UPDATE championship_bracket_preview_private.knockout_matches
    AS knockout_matches
  SET
    scheduled_slot_id = structural_slot.id,
    scheduled_date = structural_slot.event_date,
    location_key = structural_slot.location_key,
    location_name = structural_slot.location_name,
    court_key = structural_slot.court_key,
    court_name = structural_slot.court_name,
    start_at = structural_slot.start_at,
    end_at = structural_slot.end_at,
    duration_minutes = (
      extract(
        epoch FROM (
          structural_slot.end_at
          - structural_slot.start_at
        )
      ) / 60
    )::integer,
    manual_final =
      structural_slot.structural_manual_final
  FROM championship_bracket_preview_private.slots
    AS structural_slot
  WHERE knockout_matches.job_id = _job_id
    AND NOT knockout_matches.is_bye
    AND structural_slot.job_id = _job_id
    AND structural_slot.structural_competition_id =
      knockout_matches.competition_id
    AND structural_slot.structural_phase =
      knockout_matches.phase
    AND structural_slot.structural_phase_slot_number =
      knockout_matches.slot_number
    AND structural_slot.structural_phase <>
      'GROUP_STAGE';

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'code',
        'STRUCTURAL_KNOCKOUT_SLOT_MISSING',
        'message',
        format(
          'O confronto %s não possui slot estrutural correspondente no manifesto.',
          knockout_matches.logical_key
        ),
        'logical_key',
        knockout_matches.logical_key,
        'phase',
        knockout_matches.phase,
        'slot_number',
        knockout_matches.slot_number
      )
      ORDER BY
        knockout_matches.round_number,
        knockout_matches.slot_number,
        knockout_matches.logical_key
    ),
    '[]'::jsonb
  )
  INTO diagnostics
  FROM championship_bracket_preview_private.knockout_matches
    AS knockout_matches
  WHERE knockout_matches.job_id = _job_id
    AND NOT knockout_matches.is_bye
    AND (
      knockout_matches.scheduled_date IS NULL
      OR knockout_matches.start_at IS NULL
      OR knockout_matches.end_at IS NULL
      OR knockout_matches.court_key IS NULL
      OR knockout_matches.location_key IS NULL
    );

  IF jsonb_array_length(diagnostics) > 0 THEN
    RETURN diagnostics;
  END IF;

  SELECT diagnostics || COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'code',
        'STRUCTURAL_KNOCKOUT_SLOT_UNUSED',
        'message',
        format(
          'O slot estrutural %s não corresponde a nenhum confronto eliminatório.',
          structural_slot.structural_slot_key
        ),
        'slot_key',
        structural_slot.structural_slot_key,
        'phase',
        structural_slot.structural_phase,
        'phase_slot_number',
        structural_slot.structural_phase_slot_number
      )
      ORDER BY
        structural_slot.event_date,
        structural_slot.start_at,
        structural_slot.structural_slot_key
    ),
    '[]'::jsonb
  )
  INTO diagnostics
  FROM championship_bracket_preview_private.slots
    AS structural_slot
  LEFT JOIN championship_bracket_preview_private.knockout_matches
    AS knockout_matches
    ON knockout_matches.job_id = _job_id
    AND knockout_matches.competition_id =
      structural_slot.structural_competition_id
    AND knockout_matches.phase =
      structural_slot.structural_phase
    AND knockout_matches.slot_number =
      structural_slot.structural_phase_slot_number
  WHERE structural_slot.job_id = _job_id
    AND structural_slot.structural_phase <>
      'GROUP_STAGE'
    AND knockout_matches.id IS NULL;

  IF jsonb_array_length(diagnostics) > 0 THEN
    RETURN diagnostics;
  END IF;

  SELECT diagnostics || COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'code',
        'STRUCTURAL_KNOCKOUT_DEPENDENCY_ORDER',
        'message',
        format(
          'O confronto %s inicia antes do término de uma dependência anterior.',
          child_match.logical_key
        ),
        'logical_key',
        child_match.logical_key,
        'start_at',
        child_match.start_at,
        'dependency_end_at',
        predecessor_state.latest_end_at
      )
      ORDER BY
        child_match.round_number,
        child_match.slot_number,
        child_match.logical_key
    ),
    '[]'::jsonb
  )
  INTO diagnostics
  FROM championship_bracket_preview_private.knockout_matches
    AS child_match
  CROSS JOIN LATERAL (
    SELECT max(predecessor.end_at)
      AS latest_end_at
    FROM championship_bracket_preview_private.knockout_matches
      AS predecessor
    WHERE predecessor.id = ANY(
      child_match.predecessor_match_ids
    )
      AND NOT predecessor.is_bye
  ) AS predecessor_state
  WHERE child_match.job_id = _job_id
    AND NOT child_match.is_bye
    AND cardinality(
      child_match.predecessor_match_ids
    ) > 0
    AND predecessor_state.latest_end_at IS NOT NULL
    AND child_match.start_at <
      predecessor_state.latest_end_at;

  RETURN diagnostics;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.assign_job_match_numbers(_job_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH job_config AS (
    SELECT COALESCE(payload ->> 'match_numbering_mode', 'COURT') AS numbering_mode
    FROM championship_bracket_preview_private.jobs
    WHERE id = _job_id
  ), numbered_assignments AS (
    SELECT
      assignments_table.job_id,
      assignments_table.match_id,
      row_number() OVER (
        PARTITION BY CASE job_config.numbering_mode
          WHEN 'SPORT_NAIPE' THEN concat(
            'SPORT_NAIPE::',
            competitions_table.sport_id,
            '::',
            competitions_table.naipe
          )
          WHEN 'SPORT' THEN concat('SPORT::', competitions_table.sport_id)
          ELSE concat(
            'COURT::',
            slots_table.location_key,
            '::',
            slots_table.court_key
          )
        END
        ORDER BY
          slots_table.event_date,
          slots_table.start_at,
          slots_table.location_position,
          slots_table.court_position,
          competitions_table.position,
          groups_table.group_number,
          matches_table.round_number,
          matches_table.slot_number,
          matches_table.id
      )::integer AS match_number
    FROM championship_bracket_preview_private.assignments AS assignments_table
    JOIN championship_bracket_preview_private.matches AS matches_table
      ON matches_table.id = assignments_table.match_id
    JOIN championship_bracket_preview_private.competitions AS competitions_table
      ON competitions_table.id = matches_table.competition_id
    JOIN championship_bracket_preview_private.groups AS groups_table
      ON groups_table.id = matches_table.group_id
    JOIN championship_bracket_preview_private.slots AS slots_table
      ON slots_table.id = assignments_table.slot_id
    CROSS JOIN job_config
    WHERE assignments_table.job_id = _job_id
  )
  UPDATE championship_bracket_preview_private.assignments AS assignments_table
  SET match_number = numbered_assignments.match_number
  FROM numbered_assignments
  WHERE assignments_table.job_id = numbered_assignments.job_id
    AND assignments_table.match_id = numbered_assignments.match_id;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.build_unassigned_match_diagnostics(_job_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH unassigned_matches AS (
    SELECT
      matches_table.id AS match_id,
      matches_table.round_number,
      matches_table.slot_number,
      matches_table.home_team_id,
      matches_table.away_team_id,
      competitions_table.sport_id,
      competitions_table.sport_name,
      competitions_table.naipe,
      competitions_table.division,
      competitions_table.competition_key,
      competitions_table.position AS competition_position,
      groups_table.group_number,
      home_teams_table.name AS home_team_name,
      away_teams_table.name AS away_team_name,
      jobs_table.payload
    FROM championship_bracket_preview_private.matches AS matches_table
    JOIN championship_bracket_preview_private.competitions AS competitions_table
      ON competitions_table.id = matches_table.competition_id
    JOIN championship_bracket_preview_private.groups AS groups_table
      ON groups_table.id = matches_table.group_id
    JOIN championship_bracket_preview_private.jobs AS jobs_table
      ON jobs_table.id = matches_table.job_id
    JOIN public.teams AS home_teams_table
      ON home_teams_table.id = matches_table.home_team_id
    JOIN public.teams AS away_teams_table
      ON away_teams_table.id = matches_table.away_team_id
    WHERE matches_table.job_id = _job_id
      AND matches_table.assigned = false
  ), compatible_slots AS (
    SELECT
      unassigned_matches.match_id,
      slots_table.id AS slot_id,
      public.is_championship_bracket_competition_slot_playable(
        unassigned_matches.payload,
        unassigned_matches.competition_key,
        slots_table.event_date,
        slots_table.start_at,
        slots_table.end_at
      ) AS competition_playable,
      public.is_championship_bracket_team_slot_playable(
        unassigned_matches.payload,
        unassigned_matches.home_team_id,
        unassigned_matches.competition_key,
        slots_table.event_date,
        slots_table.start_at,
        slots_table.end_at
      )
      AND public.is_championship_bracket_team_slot_playable(
        unassigned_matches.payload,
        unassigned_matches.away_team_id,
        unassigned_matches.competition_key,
        slots_table.event_date,
        slots_table.start_at,
        slots_table.end_at
      ) AS teams_playable,
      NOT slot_target.has_sport_targets
      OR slot_target.planned_match_count > COALESCE(target_usage.assigned_match_count, 0) AS target_available,
      NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.assignments AS occupied_assignments
        JOIN championship_bracket_preview_private.slots AS occupied_slots
          ON occupied_slots.id = occupied_assignments.slot_id
        WHERE occupied_assignments.job_id = _job_id
          AND occupied_slots.court_key = slots_table.court_key
          AND occupied_slots.start_at < slots_table.end_at
          AND occupied_slots.end_at > slots_table.start_at
      ) AS physical_slot_available
    FROM unassigned_matches
    JOIN championship_bracket_preview_private.slots AS slots_table
      ON slots_table.job_id = _job_id
      AND slots_table.sport_id = unassigned_matches.sport_id
    CROSS JOIN LATERAL championship_bracket_preview_private.resolve_slot_sport_target(
      unassigned_matches.payload,
      slots_table.event_date,
      slots_table.court_key,
      slots_table.sport_id
    ) AS slot_target
    LEFT JOIN LATERAL (
      SELECT count(*)::integer AS assigned_match_count
      FROM championship_bracket_preview_private.assignments AS target_assignments
      JOIN championship_bracket_preview_private.slots AS assigned_slots
        ON assigned_slots.id = target_assignments.slot_id
      WHERE target_assignments.job_id = _job_id
        AND assigned_slots.event_date = slots_table.event_date
        AND assigned_slots.court_key = slots_table.court_key
        AND assigned_slots.sport_id = slots_table.sport_id
    ) AS target_usage ON true
  ), compatibility_by_match AS (
    SELECT
      unassigned_matches.*,
      count(compatible_slots.slot_id) > 0 AS has_sport_slot,
      COALESCE(bool_or(compatible_slots.competition_playable), false) AS has_competition_slot,
      COALESCE(bool_or(
        compatible_slots.competition_playable
        AND compatible_slots.teams_playable
      ), false) AS has_team_slot,
      COALESCE(bool_or(
        compatible_slots.competition_playable
        AND compatible_slots.teams_playable
        AND compatible_slots.target_available
      ), false) AS has_target_slot,
      COALESCE(bool_or(
        compatible_slots.competition_playable
        AND compatible_slots.teams_playable
        AND compatible_slots.target_available
        AND compatible_slots.physical_slot_available
      ), false) AS has_physical_slot
    FROM unassigned_matches
    LEFT JOIN compatible_slots
      ON compatible_slots.match_id = unassigned_matches.match_id
    GROUP BY
      unassigned_matches.match_id,
      unassigned_matches.round_number,
      unassigned_matches.slot_number,
      unassigned_matches.home_team_id,
      unassigned_matches.away_team_id,
      unassigned_matches.sport_id,
      unassigned_matches.sport_name,
      unassigned_matches.naipe,
      unassigned_matches.division,
      unassigned_matches.competition_key,
      unassigned_matches.competition_position,
      unassigned_matches.group_number,
      unassigned_matches.home_team_name,
      unassigned_matches.away_team_name,
      unassigned_matches.payload
  ), classified_diagnostics AS (
    SELECT
      compatibility_by_match.*,
      CASE
        WHEN NOT has_sport_slot THEN 'NO_COURT_FOR_SPORT'
        WHEN NOT has_competition_slot THEN 'COMPETITION_UNAVAILABLE'
        WHEN NOT has_team_slot THEN 'TEAM_UNAVAILABLE'
        WHEN NOT has_target_slot THEN 'SPORT_TARGET_EXHAUSTED'
        WHEN NOT has_physical_slot THEN 'COURT_CAPACITY_EXHAUSTED'
        ELSE 'TEAM_REST_CONSTRAINT'
      END AS reason_code
    FROM compatibility_by_match
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'code', 'UNASSIGNED_MATCH',
        'severity', 'ERROR',
        'message', format(
          '%s × %s — Grupo %s, rodada %s: %s',
          classified_diagnostics.home_team_name,
          classified_diagnostics.away_team_name,
          classified_diagnostics.group_number,
          classified_diagnostics.round_number,
          CASE classified_diagnostics.reason_code
            WHEN 'NO_COURT_FOR_SPORT' THEN format(
              'não há quadra configurada para %s.',
              classified_diagnostics.sport_name
            )
            WHEN 'COMPETITION_UNAVAILABLE' THEN
              'a competição não possui janela disponível nas datas configuradas.'
            WHEN 'TEAM_UNAVAILABLE' THEN
              'as disponibilidades das equipes não oferecem um horário em comum.'
            WHEN 'SPORT_TARGET_EXHAUSTED' THEN format(
              'as metas de %s nas quadras e datas compatíveis foram totalmente utilizadas.',
              classified_diagnostics.sport_name
            )
            WHEN 'COURT_CAPACITY_EXHAUSTED' THEN
              'todos os horários físicos compatíveis com a meta já estavam ocupados.'
            ELSE
              'os horários restantes violam simultaneidade ou intervalo mínimo entre jogos das equipes.'
          END
        ),
        'reason_code', classified_diagnostics.reason_code,
        'match_id', classified_diagnostics.match_id,
        'date', NULL,
        'location_name', NULL,
        'court_name', NULL,
        'sport_id', classified_diagnostics.sport_id,
        'sport_name', classified_diagnostics.sport_name,
        'naipe', classified_diagnostics.naipe,
        'division', classified_diagnostics.division,
        'phase', 'GROUP_STAGE',
        'group_number', classified_diagnostics.group_number,
        'round_number', classified_diagnostics.round_number,
        'home_team_id', classified_diagnostics.home_team_id,
        'home_team_name', classified_diagnostics.home_team_name,
        'away_team_id', classified_diagnostics.away_team_id,
        'away_team_name', classified_diagnostics.away_team_name
      )
      ORDER BY
        classified_diagnostics.competition_position,
        classified_diagnostics.group_number,
        classified_diagnostics.round_number,
        classified_diagnostics.slot_number,
        classified_diagnostics.match_id
    ),
    '[]'::jsonb
  )
  FROM classified_diagnostics;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.cleanup_manifest_daily_probe(_job_id uuid, _event_date date, _rest_gap integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
BEGIN
  DELETE FROM championship_bracket_preview_private.assignments
    AS assignments_table
  USING championship_bracket_preview_private.manifest_daily_probe_frames
    AS frames_table
  WHERE frames_table.job_id = _job_id
    AND frames_table.event_date = _event_date
    AND frames_table.rest_gap = _rest_gap
    AND frames_table.chosen_match_id IS NOT NULL
    AND assignments_table.job_id = _job_id
    AND assignments_table.match_id =
      frames_table.chosen_match_id
    AND assignments_table.slot_id =
      frames_table.slot_id;

  UPDATE championship_bracket_preview_private.matches
    AS matches_table
  SET
    assigned = false,
    applied_rest_gap = 3,
    relaxed_rest_gap_applied = false
  WHERE matches_table.job_id = _job_id
    AND matches_table.id IN (
      SELECT frames_table.chosen_match_id
      FROM championship_bracket_preview_private.manifest_daily_probe_frames
        AS frames_table
      WHERE frames_table.job_id = _job_id
        AND frames_table.event_date = _event_date
        AND frames_table.rest_gap = _rest_gap
        AND frames_table.chosen_match_id IS NOT NULL
    );

  DELETE FROM championship_bracket_preview_private.manifest_daily_probe_tried_matches
  WHERE job_id = _job_id
    AND event_date = _event_date
    AND rest_gap = _rest_gap;

  DELETE FROM championship_bracket_preview_private.manifest_daily_probe_frames
  WHERE job_id = _job_id
    AND event_date = _event_date
    AND rest_gap = _rest_gap;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.compact_v8_schedule(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  gap_record RECORD;
  candidate_slot_record RECORD;
  tier_record RECORD;
  branch_status TEXT;
  attempt_started_at TIMESTAMPTZ;
  moved BOOLEAN;
  passes INTEGER := 0;
BEGIN
  WHILE passes < 4 LOOP
    moved := false;
    passes := passes + 1;
    FOR gap_record IN
      WITH assigned AS (
        SELECT
          assignments_table.match_id,
          slots_table.event_date,
          slots_table.location_key,
          slots_table.court_key,
          slots_table.start_at,
          slots_table.end_at,
          lead(assignments_table.match_id) OVER physical_order AS next_match_id,
          lead(slots_table.start_at) OVER physical_order AS next_start_at
        FROM championship_bracket_preview_private.assignments assignments_table
        JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id = assignments_table.slot_id
        WHERE assignments_table.job_id = _job_id
        WINDOW physical_order AS (
          PARTITION BY slots_table.event_date, slots_table.location_key, slots_table.court_key
          ORDER BY slots_table.start_at, slots_table.end_at, assignments_table.match_id
        )
      )
      SELECT *
      FROM assigned
      WHERE next_start_at > end_at
        AND EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.assignments next_assignment
          WHERE next_assignment.job_id = _job_id
            AND next_assignment.match_id = assigned.next_match_id
        )
    LOOP
      SELECT candidate_slots.* INTO candidate_slot_record
      FROM championship_bracket_preview_private.slots candidate_slots
      JOIN championship_bracket_preview_private.matches next_match ON next_match.id = gap_record.next_match_id
      JOIN championship_bracket_preview_private.competitions next_competition ON next_competition.id = next_match.competition_id
      WHERE candidate_slots.job_id = _job_id
        AND candidate_slots.event_date = gap_record.event_date
        AND candidate_slots.location_key = gap_record.location_key
        AND candidate_slots.court_key = gap_record.court_key
        AND candidate_slots.sport_id = next_competition.sport_id
        AND candidate_slots.start_at >= gap_record.end_at
        AND candidate_slots.end_at <= gap_record.next_start_at
        AND NOT EXISTS (
          SELECT 1 FROM championship_bracket_preview_private.assignments occupied
          WHERE occupied.job_id = _job_id AND occupied.slot_id = candidate_slots.id
        )
      ORDER BY candidate_slots.start_at, candidate_slots.id
      LIMIT 1;

      IF candidate_slot_record.id IS NULL THEN
        CONTINUE;
      END IF;

      IF championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
        _job_id, gap_record.next_match_id, candidate_slot_record.id, 4
      ) THEN
        UPDATE championship_bracket_preview_private.assignments
        SET slot_id = candidate_slot_record.id
        WHERE job_id = _job_id AND match_id = gap_record.next_match_id;
        moved := true;
        EXIT;
      END IF;

      FOR tier_record IN
        SELECT *
        FROM (VALUES
          ('FAST'::text, 2, 12, 4, 400),
          ('MEDIUM'::text, 6, 48, 16, 1800),
          ('DEEP'::text, 12, 120, 40, 9000)
        ) AS tiers(search_tier, max_depth, candidate_limit, relocation_limit, budget_ms)
      LOOP
        attempt_started_at := clock_timestamp();
        branch_status := championship_bracket_preview_private.try_place_match_backtracking_status(
          _job_id, gap_record.next_match_id, candidate_slot_record.id,
          ARRAY[]::uuid[], ARRAY[]::bigint[], 0,
          tier_record.max_depth, tier_record.candidate_limit, tier_record.relocation_limit,
          NULL, 3, clock_timestamp() + make_interval(secs => tier_record.budget_ms::numeric / 1000)
        );
        INSERT INTO championship_bracket_preview_private.relocation_attempt_metrics(
          job_id, match_id, phase, rest_gap, search_tier, candidate_rank,
          candidate_slot_id, max_depth, candidate_limit, relocation_limit,
          result_status, timeout_count, relocations_used, branches_examined, duration_ms
        ) VALUES (
          _job_id, gap_record.next_match_id, 'COMPACTION', 4, tier_record.search_tier,
          NULL, candidate_slot_record.id, tier_record.max_depth,
          tier_record.candidate_limit, tier_record.relocation_limit,
          CASE WHEN branch_status = 'SUCCESS' THEN 'SUCCESS' ELSE format('%s_%s', tier_record.search_tier, CASE WHEN branch_status = 'TIMEOUT' THEN 'TIMEOUT' ELSE 'DEAD_END' END) END,
          CASE WHEN branch_status = 'TIMEOUT' THEN 1 ELSE 0 END, 0, 0,
          (extract(epoch FROM clock_timestamp() - attempt_started_at) * 1000)::integer
        );
        EXIT WHEN branch_status = 'SUCCESS';
      END LOOP;
      IF branch_status = 'SUCCESS' THEN
        moved := true;
        EXIT;
      END IF;
    END LOOP;
    EXIT WHEN NOT moved;
  END LOOP;
  RETURN championship_bracket_preview_private.resolve_v8_internal_empty_diagnostics(_job_id);
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.compact_v8_schedule_batch(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  gap_record RECORD;
  candidate_slot_record RECORD;
  tier_record RECORD;
  branch_status TEXT := 'DEAD_END';
  attempt_started_at TIMESTAMPTZ;
  overall_deadline TIMESTAMPTZ;
  tier_deadline TIMESTAMPTZ;
  moved BOOLEAN := false;
  search_timed_out BOOLEAN := false;
  compaction_status TEXT;
  compaction_timeout_count INTEGER;
BEGIN
  overall_deadline := clock_timestamp() + interval '10 seconds';

  WITH assigned AS (
    SELECT
      assignments_table.match_id,
      slots_table.event_date,
      slots_table.location_key,
      slots_table.court_key,
      slots_table.start_at,
      slots_table.end_at,
      lead(assignments_table.match_id) OVER physical_order AS next_match_id,
      lead(slots_table.start_at) OVER physical_order AS next_start_at
    FROM championship_bracket_preview_private.assignments assignments_table
    JOIN championship_bracket_preview_private.slots slots_table
      ON slots_table.id = assignments_table.slot_id
    WHERE assignments_table.job_id = _job_id
    WINDOW physical_order AS (
      PARTITION BY
        slots_table.event_date,
        slots_table.location_key,
        slots_table.court_key
      ORDER BY
        slots_table.start_at,
        slots_table.end_at,
        assignments_table.match_id
    )
  ),
  gaps AS (
    SELECT
      assigned.*,
      format(
        '%s:%s:%s:%s',
        assigned.location_key,
        assigned.court_key,
        assigned.end_at,
        assigned.next_match_id
      ) AS gap_key
    FROM assigned
    WHERE assigned.next_start_at > assigned.end_at
  )
  SELECT gaps.*
  INTO gap_record
  FROM gaps
  WHERE NOT EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.compaction_gaps
      AS compaction_gaps
    WHERE compaction_gaps.job_id = _job_id
  AND compaction_gaps.gap_key = gaps.gap_key
  AND compaction_gaps.status = 'UNRESOLVED'
  )
  ORDER BY
    gaps.event_date,
    gaps.location_key,
    gaps.court_key,
    gaps.end_at,
    gaps.next_match_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'continue', false,
      'done', true
    );
  END IF;

  SELECT candidate_slots.*
  INTO candidate_slot_record
  FROM championship_bracket_preview_private.slots candidate_slots
  JOIN championship_bracket_preview_private.matches next_match
    ON next_match.id = gap_record.next_match_id
  JOIN championship_bracket_preview_private.competitions next_competition
    ON next_competition.id = next_match.competition_id
  WHERE candidate_slots.job_id = _job_id
    AND candidate_slots.event_date = gap_record.event_date
    AND candidate_slots.location_key = gap_record.location_key
    AND candidate_slots.court_key = gap_record.court_key
    AND candidate_slots.sport_id = next_competition.sport_id
    AND candidate_slots.start_at >= gap_record.end_at
    AND candidate_slots.end_at <= gap_record.next_start_at
    AND NOT EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.assignments occupied
      WHERE occupied.job_id = _job_id
        AND occupied.slot_id = candidate_slots.id
    )
  ORDER BY
    candidate_slots.start_at,
    candidate_slots.id
  LIMIT 1;

  IF candidate_slot_record.id IS NOT NULL
    AND championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(
      _job_id,
      gap_record.next_match_id,
      candidate_slot_record.id,
      3
    )
  THEN
    UPDATE championship_bracket_preview_private.assignments
    SET slot_id = candidate_slot_record.id
    WHERE job_id = _job_id
      AND match_id = gap_record.next_match_id;

    moved := true;
  ELSIF candidate_slot_record.id IS NOT NULL THEN
    FOR tier_record IN
      SELECT *
      FROM (
        VALUES
          ('FAST'::text, 2, 12, 4, 400),
          ('MEDIUM'::text, 6, 48, 16, 1800),
          ('DEEP'::text, 12, 120, 40, 7000)
      ) AS tiers(
        search_tier,
        max_depth,
        candidate_limit,
        relocation_limit,
        budget_ms
      )
    LOOP
      IF clock_timestamp() >= overall_deadline THEN
        search_timed_out := true;
        EXIT;
      END IF;

      tier_deadline := LEAST(
        overall_deadline,
        clock_timestamp()
          + make_interval(
              secs => tier_record.budget_ms::numeric / 1000
            )
      );

      attempt_started_at := clock_timestamp();

      branch_status :=
        championship_bracket_preview_private.try_place_match_backtracking_status(
          _job_id,
          gap_record.next_match_id,
          candidate_slot_record.id,
          ARRAY[]::UUID[],
          ARRAY[]::BIGINT[],
          0,
          tier_record.max_depth,
          tier_record.candidate_limit,
          tier_record.relocation_limit,
          NULL,
          3,
          tier_deadline
        );

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
        gap_record.next_match_id,
        'COMPACTION',
        3,
        tier_record.search_tier,
        1,
        candidate_slot_record.id,
        tier_record.max_depth,
        tier_record.candidate_limit,
        tier_record.relocation_limit,
        CASE
          WHEN branch_status = 'SUCCESS'
            THEN 'SUCCESS'
          WHEN branch_status = 'TIMEOUT'
            THEN tier_record.search_tier || '_TIMEOUT'
          ELSE tier_record.search_tier || '_DEAD_END'
        END,
        CASE
          WHEN branch_status = 'TIMEOUT' THEN 1
          ELSE 0
        END,
        0,
        0,
        (
          extract(
            epoch FROM clock_timestamp() - attempt_started_at
          ) * 1000
        )::integer
      );

      IF branch_status = 'SUCCESS' THEN
        moved := true;
        EXIT;
      END IF;

      IF branch_status = 'TIMEOUT' THEN
        search_timed_out := true;
        EXIT;
      END IF;
    END LOOP;
  END IF;

  IF moved THEN
  DELETE FROM championship_bracket_preview_private.compaction_gaps
WHERE job_id = _job_id
  AND gap_key = gap_record.gap_key;
    RETURN jsonb_build_object(
      'continue', true,
      'done', false,
      'progressed', true
    );
  END IF;

  IF search_timed_out
  OR clock_timestamp() >= overall_deadline
THEN
  INSERT INTO championship_bracket_preview_private.compaction_gaps (
    job_id,
    gap_key,
    status,
    timeout_count
  )
  VALUES (
    _job_id,
    gap_record.gap_key,
    'RETRY',
    1
  )
  ON CONFLICT (job_id, gap_key)
  DO UPDATE SET
    timeout_count =
      championship_bracket_preview_private.compaction_gaps.timeout_count + 1,
    status =
      CASE
        WHEN championship_bracket_preview_private.compaction_gaps.timeout_count + 1 >= 3
          THEN 'UNRESOLVED'
        ELSE 'RETRY'
      END,
    attempted_at = now()
  RETURNING status, timeout_count
  INTO compaction_status, compaction_timeout_count;

  RETURN jsonb_build_object(
    'continue', true,
    'done', false,
    'progressed', false,
    'retry', compaction_status = 'RETRY',
    'search_limit', compaction_status = 'UNRESOLVED',
    'timeout_count', compaction_timeout_count,
    'gap_key', gap_record.gap_key
  );
END IF;

  INSERT INTO championship_bracket_preview_private.compaction_gaps (
    job_id,
    gap_key,
    status
  )
  VALUES (
    _job_id,
    gap_record.gap_key,
    'UNRESOLVED'
  )
  ON CONFLICT (job_id, gap_key)
  DO UPDATE SET
    status = EXCLUDED.status,
    attempted_at = now();

  RETURN jsonb_build_object(
    'continue', true,
    'done', false,
    'progressed', false,
    'retry', false,
    'gap_key', gap_record.gap_key
  );
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.create_v8_knockout_matches(_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  competition_record RECORD;
  bracket_size INTEGER;
  direct_qualified_count INTEGER;
  qualified_count INTEGER;
  total_rounds INTEGER;
  round_number_value INTEGER;
  slot_number_value INTEGER;
  round_match_count INTEGER;
  phase_name TEXT;
  predecessor_ids UUID[];
  is_bye_value BOOLEAN;
  home_seed INTEGER;
  away_seed INTEGER;
  home_source JSONB;
  away_source JSONB;
  should_include_best_second_placed_teams BOOLEAN;
  seed_order INTEGER[];
BEGIN
  DELETE FROM championship_bracket_preview_private.knockout_matches
  WHERE job_id = _job_id;

  FOR competition_record IN
    SELECT
      competitions_table.*,
      COALESCE(
        championship_sports_table.default_match_duration_minutes,
        35
      )::integer AS duration_minutes
    FROM championship_bracket_preview_private.competitions competitions_table
    LEFT JOIN public.championship_sports championship_sports_table
      ON championship_sports_table.championship_id = (
        SELECT championship_id
        FROM championship_bracket_preview_private.jobs
        WHERE id = _job_id
      )
      AND championship_sports_table.sport_id = competitions_table.sport_id
    WHERE competitions_table.job_id = _job_id
    ORDER BY
      competitions_table.position,
      competitions_table.competition_key
  LOOP
    direct_qualified_count :=
      competition_record.groups_count
      * competition_record.qualifiers_per_group;

    bracket_size := 1;

    IF competition_record.qualifiers_per_group = 1
      AND competition_record.best_second
    THEN
      WHILE bracket_size <= direct_qualified_count LOOP
        bracket_size := bracket_size * 2;
      END LOOP;
    ELSE
      WHILE bracket_size < direct_qualified_count LOOP
        bracket_size := bracket_size * 2;
      END LOOP;
    END IF;

    should_include_best_second_placed_teams :=
      competition_record.qualifiers_per_group = 1
      AND bracket_size > direct_qualified_count;

    qualified_count := CASE
      WHEN competition_record.qualifiers_per_group IN (1, 2)
        AND bracket_size > direct_qualified_count
      THEN bracket_size
      ELSE direct_qualified_count
    END;

    IF bracket_size < 2 OR qualified_count < 2 THEN
      CONTINUE;
    END IF;

    seed_order :=
      public.resolve_championship_knockout_seed_order(
        competition_record.pairing_mode,
        bracket_size
      );

    IF COALESCE(array_length(seed_order, 1), 0) <> bracket_size THEN
      RAISE EXCEPTION
        'Invalid knockout seed order for competition %, mode %, bracket size %',
        competition_record.id,
        competition_record.pairing_mode,
        bracket_size;
    END IF;

    total_rounds := 0;

    WHILE power(2, total_rounds)::integer < bracket_size LOOP
      total_rounds := total_rounds + 1;
    END LOOP;

    FOR round_number_value IN 1..total_rounds LOOP
      round_match_count :=
        power(
          2,
          total_rounds - round_number_value
        )::integer;

      FOR slot_number_value IN 1..round_match_count LOOP
        SELECT COALESCE(
          array_agg(
            previous_matches.id
            ORDER BY previous_matches.slot_number
          ),
          ARRAY[]::uuid[]
        )
        INTO predecessor_ids
        FROM championship_bracket_preview_private.knockout_matches previous_matches
        WHERE previous_matches.job_id = _job_id
          AND previous_matches.competition_id = competition_record.id
          AND previous_matches.round_number = round_number_value - 1
          AND previous_matches.slot_number IN (
            (slot_number_value * 2) - 1,
            slot_number_value * 2
          )
          AND previous_matches.phase <> 'THIRD_PLACE';

        IF round_number_value = 1 THEN
          home_seed :=
            seed_order[
              ((slot_number_value - 1) * 2) + 1
            ];

          away_seed :=
            seed_order[
              ((slot_number_value - 1) * 2) + 2
            ];
        ELSE
          home_seed := slot_number_value;
          away_seed := bracket_size + 1 - slot_number_value;
        END IF;

        home_source :=
          championship_bracket_preview_private.resolve_v8_knockout_seed_source(
            competition_record.groups_count,
            competition_record.qualifiers_per_group,
            should_include_best_second_placed_teams,
            FALSE,
            home_seed,
            qualified_count
          );

        away_source :=
          championship_bracket_preview_private.resolve_v8_knockout_seed_source(
            competition_record.groups_count,
            competition_record.qualifiers_per_group,
            should_include_best_second_placed_teams,
            FALSE,
            away_seed,
            qualified_count
          );

        is_bye_value :=
          round_number_value = 1
          AND (
            (home_source ->> 'type' = 'BYE')
            <> (away_source ->> 'type' = 'BYE')
          );

        phase_name := CASE
          WHEN round_number_value = total_rounds
            THEN 'FINAL'
          WHEN round_number_value = total_rounds - 1
            THEN 'SEMIFINAL'
          WHEN round_match_count = 4
            THEN 'QUARTERFINAL'
          WHEN round_match_count = 8
            THEN 'ROUND_OF_16'
          WHEN round_match_count = 16
            THEN 'ROUND_OF_32'
          ELSE 'KNOCKOUT'
        END;

        INSERT INTO championship_bracket_preview_private.knockout_matches(
          job_id,
          competition_id,
          phase,
          round_number,
          slot_number,
          logical_key,
          home_source_type,
          home_source_reference,
          away_source_type,
          away_source_reference,
          predecessor_match_ids,
          duration_minutes,
          is_bye
        )
        VALUES (
          _job_id,
          competition_record.id,
          phase_name,
          round_number_value,
          slot_number_value,
          format(
            '%s::%s::%s',
            competition_record.competition_key,
            phase_name,
            slot_number_value
          ),
          CASE
            WHEN round_number_value = 1
              THEN home_source ->> 'type'
            ELSE 'WINNER_OF_MATCH'
          END,
          CASE
            WHEN round_number_value = 1
              THEN home_source ->> 'reference'
            ELSE format(
              'WINNER_OF_%s',
              predecessor_ids[1]
            )
          END,
          CASE
            WHEN round_number_value = 1
              THEN away_source ->> 'type'
            ELSE 'WINNER_OF_MATCH'
          END,
          CASE
            WHEN round_number_value = 1
              THEN away_source ->> 'reference'
            ELSE format(
              'WINNER_OF_%s',
              predecessor_ids[2]
            )
          END,
          predecessor_ids,
          competition_record.duration_minutes,
          is_bye_value
        );
      END LOOP;
    END LOOP;

    IF competition_record.third_place_mode = 'MATCH'
      AND total_rounds > 1
    THEN
      SELECT array_agg(
        semifinals.id
        ORDER BY semifinals.slot_number
      )
      INTO predecessor_ids
      FROM championship_bracket_preview_private.knockout_matches semifinals
      WHERE semifinals.job_id = _job_id
        AND semifinals.competition_id = competition_record.id
        AND semifinals.round_number = total_rounds - 1;

      INSERT INTO championship_bracket_preview_private.knockout_matches(
        job_id,
        competition_id,
        phase,
        round_number,
        slot_number,
        logical_key,
        home_source_type,
        home_source_reference,
        away_source_type,
        away_source_reference,
        predecessor_match_ids,
        duration_minutes
      )
      VALUES (
        _job_id,
        competition_record.id,
        'THIRD_PLACE',
        total_rounds,
        2,
        format(
          '%s::THIRD_PLACE::1',
          competition_record.competition_key
        ),
        'LOSER_OF_MATCH',
        format(
          'LOSER_OF_%s',
          predecessor_ids[1]
        ),
        'LOSER_OF_MATCH',
        format(
          'LOSER_OF_%s',
          predecessor_ids[2]
        ),
        predecessor_ids,
        competition_record.duration_minutes
      );
    END IF;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.finalize_job(_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  job_record RECORD;
  target_diagnostics JSONB;
  timeline_diagnostics JSONB;
  final_diagnostics JSONB;
  manifest JSONB;
  group_count INTEGER;
  knockout_count INTEGER;
  scheduled_knockout_count INTEGER;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id
  FOR UPDATE;

  IF job_record.status <> 'FINALIZING'
    OR job_record.stage <> 'FINALIZING'
  THEN
    RETURN;
  END IF;

  SELECT
    championship_bracket_preview_private.resolve_v8_target_completion_diagnostics(
      _job_id
    )
  INTO target_diagnostics;

  SELECT
    championship_bracket_preview_private.resolve_v8_internal_empty_diagnostics(
      _job_id
    )
  INTO timeline_diagnostics;

  SELECT count(*)
  INTO group_count
  FROM championship_bracket_preview_private.assignments
  WHERE job_id = _job_id;

  SELECT count(*)
  INTO knockout_count
  FROM championship_bracket_preview_private.knockout_matches
  WHERE job_id = _job_id
    AND NOT is_bye;

  SELECT count(*)
  INTO scheduled_knockout_count
  FROM championship_bracket_preview_private.knockout_matches
  WHERE job_id = _job_id
    AND NOT is_bye
    AND scheduled_date IS NOT NULL
    AND location_key IS NOT NULL
    AND court_key IS NOT NULL
    AND start_at IS NOT NULL
    AND end_at IS NOT NULL;

  final_diagnostics :=
    target_diagnostics
    || timeline_diagnostics;

  IF group_count <> (
    SELECT count(*)
    FROM championship_bracket_preview_private.matches
    WHERE job_id = _job_id
  )
    OR knockout_count <> scheduled_knockout_count
  THEN
    final_diagnostics :=
      final_diagnostics
      || jsonb_build_array(
        jsonb_build_object(
          'code',
          'SCHEDULE_INCOMPLETE',
          'message',
          'A prévia v8 não possui todas as partidas estruturais programadas.',
          'target',
          (
            SELECT count(*)
            FROM championship_bracket_preview_private.matches
            WHERE job_id = _job_id
          ) + knockout_count,
          'obtained',
          group_count + scheduled_knockout_count
        )
      );
  END IF;

  IF jsonb_array_length(
    final_diagnostics
  ) > 0 THEN
    UPDATE championship_bracket_preview_private.jobs
    SET
      status = 'FAILED',
      stage = 'Validação da programação',
      diagnostics = final_diagnostics,
      error_message =
        final_diagnostics -> 0 ->> 'message',
      completed_at = now(),
      updated_at = now()
    WHERE id = _job_id;

    RETURN;
  END IF;

  SELECT jsonb_build_object(
    'algorithm_version',
    'async-exact-v8',
    'groups',
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'competition',
            competitions.competition_key,
            'group',
            groups.group_number,
            'teams',
            (
              SELECT jsonb_agg(
                group_teams.team_id
                ORDER BY group_teams.position
              )
              FROM championship_bracket_preview_private.group_teams
                AS group_teams
              WHERE group_teams.group_id =
                groups.id
            )
          )
          ORDER BY
            competitions.position,
            groups.group_number
        )
        FROM championship_bracket_preview_private.groups
          AS groups
        JOIN championship_bracket_preview_private.competitions
          AS competitions
          ON competitions.id =
            groups.competition_id
        WHERE groups.job_id = _job_id
      ),
      '[]'::jsonb
    ),
    'group_matches',
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'key',
            matches.logical_key,
            'slot_id',
            assignments.slot_id,
            'home_team_id',
            matches.home_team_id,
            'away_team_id',
            matches.away_team_id,
            'date',
            slots.event_date,
            'location_key',
            slots.location_key,
            'location',
            slots.location_name,
            'court_key',
            slots.court_key,
            'court',
            slots.court_name,
            'start',
            slots.start_at,
            'end',
            slots.end_at,
            'match_number',
            assignments.match_number
          )
          ORDER BY matches.logical_key
        )
        FROM championship_bracket_preview_private.assignments
          AS assignments
        JOIN championship_bracket_preview_private.matches
          AS matches
          ON matches.id =
            assignments.match_id
        JOIN championship_bracket_preview_private.slots
          AS slots
          ON slots.id =
            assignments.slot_id
        WHERE assignments.job_id = _job_id
      ),
      '[]'::jsonb
    ),
    'knockout_matches',
    COALESCE(
      (
        SELECT jsonb_agg(
          jsonb_build_object(
            'key',
            knockout_matches.logical_key,
            'phase',
            knockout_matches.phase,
            'round',
            knockout_matches.round_number,
            'slot',
            knockout_matches.slot_number,
            'home_source_type',
            knockout_matches.home_source_type,
            'home_source',
            knockout_matches.home_source_reference,
            'away_source_type',
            knockout_matches.away_source_type,
            'away_source',
            knockout_matches.away_source_reference,
            'predecessors',
            knockout_matches.predecessor_match_ids,
            'is_bye',
            knockout_matches.is_bye,
            'date',
            knockout_matches.scheduled_date,
            'location_key',
            knockout_matches.location_key,
            'location',
            knockout_matches.location_name,
            'court_key',
            knockout_matches.court_key,
            'court',
            knockout_matches.court_name,
            'start',
            CASE
              WHEN knockout_matches.is_bye
                THEN NULL
              ELSE knockout_matches.start_at
            END,
            'end',
            CASE
              WHEN knockout_matches.is_bye
                THEN NULL
              ELSE knockout_matches.end_at
            END,
            'manual_final',
            knockout_matches.manual_final
          )
          ORDER BY
            knockout_matches.round_number,
            knockout_matches.slot_number,
            knockout_matches.logical_key
        )
        FROM championship_bracket_preview_private.knockout_matches
          AS knockout_matches
        WHERE knockout_matches.job_id = _job_id
      ),
      '[]'::jsonb
    )
  )
  INTO manifest;

  UPDATE championship_bracket_preview_private.jobs
  SET
    status = 'COMPLETED',
    stage = 'Concluída',
    progress_percentage = 100,
    summary = jsonb_build_object(
      'total_matches',
      group_count + knockout_count,
      'group_stage_matches',
      group_count,
      'knockout_matches',
      knockout_count,
      'scheduled_matches',
      group_count + scheduled_knockout_count,
      'occupied_minutes',
      (
        SELECT COALESCE(
          sum(minutes),
          0
        )::integer
        FROM (
          SELECT
            extract(
              epoch FROM (
                slots_table.end_at
                - slots_table.start_at
              )
            ) / 60 AS minutes
          FROM championship_bracket_preview_private.assignments
            AS assignments_table
          JOIN championship_bracket_preview_private.slots
            AS slots_table
            ON slots_table.id =
              assignments_table.slot_id
          WHERE assignments_table.job_id = _job_id

          UNION ALL

          SELECT
            extract(
              epoch FROM (
                knockout_matches.end_at
                - knockout_matches.start_at
              )
            ) / 60
          FROM championship_bracket_preview_private.knockout_matches
            AS knockout_matches
          WHERE knockout_matches.job_id = _job_id
            AND NOT knockout_matches.is_bye
        ) AS occupied
      ),
      'available_minutes',
      (
        SELECT COALESCE(
          sum(
            extract(
              epoch FROM (
                end_at - start_at
              )
            ) / 60
          )::integer,
          0
        )
        FROM championship_bracket_preview_private.slots
        WHERE job_id = _job_id
      ),
      'utilization_percentage',
      NULL,
      'free_windows',
      NULL,
      'conflict_count',
      0,
      'warning_count',
      0,
      'search_tiers',
      jsonb_build_object(
        'fast_attempts',
        (
          SELECT count(*)
          FROM championship_bracket_preview_private.relocation_attempt_metrics
          WHERE job_id = _job_id
            AND search_tier = 'FAST'
        ),
        'medium_attempts',
        (
          SELECT count(*)
          FROM championship_bracket_preview_private.relocation_attempt_metrics
          WHERE job_id = _job_id
            AND search_tier = 'MEDIUM'
        ),
        'deep_attempts',
        (
          SELECT count(*)
          FROM championship_bracket_preview_private.relocation_attempt_metrics
          WHERE job_id = _job_id
            AND search_tier = 'DEEP'
        ),
        'relocations_used',
        0,
        'branches_examined',
        0
      )
    ),
    generation_signature =
      encode(
        extensions.digest(
          convert_to(
            manifest::text,
            'UTF8'
          ),
          'sha256'
        ),
        'hex'
      ),
    completed_at = now(),
    expires_at =
      now() + interval '7 days',
    updated_at = now()
  WHERE id = _job_id;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.finalize_job_v7(_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '15s'
AS $function$
DECLARE
  job_record RECORD;
  manifest JSONB;
  total_group INTEGER;
  knockout_estimate INTEGER;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id
  FOR UPDATE;

  IF job_record.status <> 'FINALIZING' THEN
    RETURN;
  END IF;

  PERFORM championship_bracket_preview_private.assign_job_match_numbers(_job_id);

  SELECT count(*)
  INTO total_group
  FROM championship_bracket_preview_private.matches
  WHERE job_id = _job_id;

  SELECT COALESCE(
    sum(
      GREATEST(
        competitions_table.groups_count * competitions_table.qualifiers_per_group - 1,
        0
      ) + CASE
        WHEN competitions_table.third_place_mode <> 'NONE' THEN 1
        ELSE 0
      END
    ),
    0
  )::integer
  INTO knockout_estimate
  FROM championship_bracket_preview_private.competitions AS competitions_table
  WHERE competitions_table.job_id = _job_id;

  SELECT jsonb_build_object(
    'algorithm_version', job_record.algorithm_version,
    'payload_signature', job_record.payload_signature,
    'dependency_signature', job_record.dependency_signature,
    'groups', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'competition', competitions_table.competition_key,
          'group', groups_table.group_number,
          'teams', (
            SELECT jsonb_agg(group_teams_table.team_id ORDER BY group_teams_table.position)
            FROM championship_bracket_preview_private.group_teams AS group_teams_table
            WHERE group_teams_table.group_id = groups_table.id
          )
        )
        ORDER BY competitions_table.position, groups_table.group_number
      )
      FROM championship_bracket_preview_private.groups AS groups_table
      JOIN championship_bracket_preview_private.competitions AS competitions_table
        ON competitions_table.id = groups_table.competition_id
      WHERE groups_table.job_id = _job_id
    ), '[]'::jsonb),
    'matches', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'key', matches_table.logical_key,
          'competition', competitions_table.competition_key,
          'round', matches_table.round_number,
          'slot', matches_table.slot_number,
          'home', matches_table.home_team_id,
          'away', matches_table.away_team_id,
          'date', slots_table.event_date,
          'location', slots_table.location_name,
          'court', slots_table.court_name,
          'start', slots_table.start_at,
          'end', slots_table.end_at
        )
        ORDER BY
          slots_table.event_date,
          slots_table.start_at,
          slots_table.location_position,
          slots_table.court_position,
          matches_table.logical_key
      )
      FROM championship_bracket_preview_private.assignments AS assignments_table
      JOIN championship_bracket_preview_private.matches AS matches_table
        ON matches_table.id = assignments_table.match_id
      JOIN championship_bracket_preview_private.competitions AS competitions_table
        ON competitions_table.id = matches_table.competition_id
      JOIN championship_bracket_preview_private.slots AS slots_table
        ON slots_table.id = assignments_table.slot_id
      WHERE assignments_table.job_id = _job_id
    ), '[]'::jsonb)
  )
  INTO manifest;

  UPDATE championship_bracket_preview_private.jobs
  SET
    status = 'COMPLETED',
    stage = 'Concluída',
    progress_percentage = 100,
    summary = jsonb_build_object(
      'total_matches', total_group + knockout_estimate,
      'group_stage_matches', total_group,
      'knockout_matches', knockout_estimate,
      'scheduled_matches', total_group,
      'occupied_minutes', COALESCE((
        SELECT sum(EXTRACT(EPOCH FROM (slots_table.end_at - slots_table.start_at)) / 60)::integer
        FROM championship_bracket_preview_private.assignments AS assignments_table
        JOIN championship_bracket_preview_private.slots AS slots_table
          ON slots_table.id = assignments_table.slot_id
        WHERE assignments_table.job_id = _job_id
      ), 0),
      'available_minutes', COALESCE((
        SELECT sum(EXTRACT(EPOCH FROM (slots_table.end_at - slots_table.start_at)) / 60)::integer
        FROM championship_bracket_preview_private.slots AS slots_table
        WHERE slots_table.job_id = _job_id
      ), 0),
      'utilization_percentage', round(
        100 * total_group::numeric /
        GREATEST((
          SELECT count(*)
          FROM championship_bracket_preview_private.slots AS slots_table
          WHERE slots_table.job_id = _job_id
        ), 1),
        2
      ),
      'free_windows', (
        SELECT count(*)
        FROM championship_bracket_preview_private.slots AS slots_table
        WHERE slots_table.job_id = _job_id
          AND NOT EXISTS (
            SELECT 1
            FROM championship_bracket_preview_private.assignments AS assignments_table
            WHERE assignments_table.slot_id = slots_table.id
          )
      ),
      'conflict_count', 0,
      'warning_count', 0,
      'games_by_day', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'date', day_count.event_date,
            'matches', day_count.matches
          )
          ORDER BY day_count.event_date
        )
        FROM (
          SELECT
            slots_table.event_date,
            count(*)::integer AS matches
          FROM championship_bracket_preview_private.assignments AS assignments_table
          JOIN championship_bracket_preview_private.slots AS slots_table
            ON slots_table.id = assignments_table.slot_id
          WHERE assignments_table.job_id = _job_id
          GROUP BY slots_table.event_date
        ) AS day_count
      ), '[]'::jsonb)
    ),
    generation_signature = encode(
      extensions.digest(convert_to(manifest::text, 'UTF8'), 'sha256'),
      'hex'
    ),
    completed_at = now(),
    expires_at = now() + interval '7 days',
    heartbeat_at = now(),
    updated_at = now()
  WHERE id = _job_id;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.initialize_job(_job_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '15s'
AS $function$
DECLARE
  job_record RECORD;
BEGIN
  SELECT * INTO job_record FROM championship_bracket_preview_private.jobs WHERE id = _job_id FOR UPDATE;
  IF job_record.status NOT IN ('QUEUED', 'INITIALIZING') THEN RETURN; END IF;

  UPDATE championship_bracket_preview_private.jobs SET
    status = 'INITIALIZING', stage = 'Normalizando configuração', started_at = COALESCE(started_at, now()),
    heartbeat_at = now(), updated_at = now()
  WHERE id = _job_id;

  INSERT INTO championship_bracket_preview_private.competitions (
    id, job_id, sport_id, sport_name, naipe, division, groups_count,
    qualifiers_per_group, third_place_mode, best_second, pairing_mode,
    competition_key, position
  )
  SELECT gen_random_uuid(), _job_id, (competition.value ->> 'sport_id')::uuid,
    COALESCE(s.name, competition.value ->> 'sport_id'),
    (competition.value ->> 'naipe')::public.match_naipe,
    NULLIF(competition.value ->> 'division', '')::public.team_division,
    GREATEST((competition.value ->> 'groups_count')::integer, 1),
    GREATEST((competition.value ->> 'qualifiers_per_group')::integer, 1),
    COALESCE(NULLIF(competition.value ->> 'third_place_mode', '')::public.bracket_third_place_mode, 'NONE'),
    COALESCE((competition.value ->> 'should_complete_knockout_with_best_second_placed_teams')::boolean, false),
    COALESCE(NULLIF(competition.value ->> 'knockout_pairing_mode', ''), 'LINEAR'),
    (competition.value ->> 'sport_id') || '::' || (competition.value ->> 'naipe') || '::' || COALESCE(NULLIF(competition.value ->> 'division', ''), 'WITHOUT_DIVISION'),
    competition.ordinality::integer
  FROM jsonb_array_elements(COALESCE(job_record.payload -> 'competitions', '[]'::jsonb)) WITH ORDINALITY competition(value, ordinality)
  LEFT JOIN public.sports s ON s.id = (competition.value ->> 'sport_id')::uuid
  ON CONFLICT (job_id, competition_key) DO NOTHING;

  INSERT INTO championship_bracket_preview_private.groups (id, job_id, competition_id, group_number)
  SELECT gen_random_uuid(), _job_id, c.id, (group_item.value ->> 'group_number')::integer
  FROM jsonb_array_elements(COALESCE(job_record.payload -> 'competitions', '[]'::jsonb)) competition(value)
  JOIN championship_bracket_preview_private.competitions c ON c.job_id = _job_id
    AND c.competition_key = (competition.value ->> 'sport_id') || '::' || (competition.value ->> 'naipe') || '::' || COALESCE(NULLIF(competition.value ->> 'division', ''), 'WITHOUT_DIVISION')
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(competition.value -> 'groups', '[]'::jsonb)) group_item(value)
  ON CONFLICT (job_id, competition_id, group_number) DO NOTHING;

  INSERT INTO championship_bracket_preview_private.group_teams (job_id, group_id, team_id, position)
  SELECT _job_id, g.id, trim(both '"' from team_item.value::text)::uuid, team_item.ordinality::integer
  FROM jsonb_array_elements(COALESCE(job_record.payload -> 'competitions', '[]'::jsonb)) competition(value)
  JOIN championship_bracket_preview_private.competitions c ON c.job_id = _job_id
    AND c.competition_key = (competition.value ->> 'sport_id') || '::' || (competition.value ->> 'naipe') || '::' || COALESCE(NULLIF(competition.value ->> 'division', ''), 'WITHOUT_DIVISION')
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(competition.value -> 'groups', '[]'::jsonb)) group_item(value)
  JOIN championship_bracket_preview_private.groups g ON g.job_id = _job_id AND g.competition_id = c.id
    AND g.group_number = (group_item.value ->> 'group_number')::integer
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(group_item.value -> 'team_ids', '[]'::jsonb)) WITH ORDINALITY team_item(value, ordinality)
  ON CONFLICT DO NOTHING;

  INSERT INTO championship_bracket_preview_private.matches (
    id, job_id, competition_id, group_id, logical_key, round_number, slot_number,
    home_team_id, away_team_id, priority_weight
  )
  SELECT gen_random_uuid(), _job_id, g.competition_id, g.id,
    format('%s:%s:%s', g.id, home.position, away.position),
    ((row_number() OVER (PARTITION BY g.id ORDER BY home.position, away.position) - 1)
      / GREATEST((team_count.count_value / 2), 1) + 1)::integer,
    row_number() OVER (PARTITION BY g.competition_id ORDER BY g.group_number, home.position, away.position)::integer,
    home.team_id, away.team_id,
    (team_count.count_value * 100) - home.position - away.position
  FROM championship_bracket_preview_private.groups g
  JOIN championship_bracket_preview_private.group_teams home ON home.job_id = _job_id AND home.group_id = g.id
  JOIN championship_bracket_preview_private.group_teams away ON away.job_id = _job_id AND away.group_id = g.id AND away.position > home.position
  JOIN LATERAL (SELECT count(*)::integer count_value FROM championship_bracket_preview_private.group_teams gt WHERE gt.job_id = _job_id AND gt.group_id = g.id) team_count ON true
  WHERE g.job_id = _job_id
  ON CONFLICT (job_id, logical_key) DO NOTHING;

  INSERT INTO championship_bracket_preview_private.slots (
    job_id, event_date, location_key, location_name, location_position,
    court_key, court_name, court_position, sport_id, start_at, end_at,
    sequence_index, preferred_sport, preferred_naipe, preferred_division,
    sequence_mode, cursor_position
  )
  SELECT _job_id, (day_item.value ->> 'date')::date,
    (location_item.value ->> 'location_key')::uuid, location_item.value ->> 'name',
    COALESCE((location_item.value ->> 'position')::integer, location_item.ordinality::integer),
    (court_item.value ->> 'court_key')::uuid, court_item.value ->> 'name',
    COALESCE((court_item.value ->> 'position')::integer, court_item.ordinality::integer),
    trim(both '"' from sport_item.value::text)::uuid,
    slot_start, slot_start + make_interval(mins => duration.duration_minutes),
    row_number() OVER (PARTITION BY day_item.value ->> 'date', court_item.value ->> 'court_key', sport_item.value::text ORDER BY slot_start)::integer,
    COALESCE(court_item.value -> 'sport_preference' ->> 'preferred_sport_id', '') = trim(both '"' from sport_item.value::text),
    NULLIF(court_item.value -> 'sport_preference' ->> 'preferred_naipe', '')::public.match_naipe,
    NULLIF(court_item.value -> 'sport_preference' ->> 'preferred_division', '')::public.team_division,
    COALESCE(court_item.value -> 'sport_preference' ->> 'sequence_mode', 'FLEXIBLE'),
    row_number() OVER (ORDER BY (day_item.value ->> 'date')::date, slot_start,
      COALESCE((location_item.value ->> 'position')::integer, location_item.ordinality::integer),
      COALESCE((court_item.value ->> 'position')::integer, court_item.ordinality::integer), sport_item.value::text)
  FROM jsonb_array_elements(COALESCE(job_record.payload -> 'schedule_days', '[]'::jsonb)) WITH ORDINALITY day_item(value, ordinality)
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(day_item.value -> 'locations', '[]'::jsonb)) WITH ORDINALITY location_item(value, ordinality)
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(location_item.value -> 'courts', '[]'::jsonb)) WITH ORDINALITY court_item(value, ordinality)
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(court_item.value -> 'sport_ids', '[]'::jsonb)) sport_item(value)
  JOIN LATERAL (SELECT GREATEST(COALESCE(cs.default_match_duration_minutes, 35), 1)::integer duration_minutes
    FROM public.championship_sports cs WHERE cs.championship_id = job_record.championship_id
      AND cs.sport_id = trim(both '"' from sport_item.value::text)::uuid LIMIT 1) duration ON true
  CROSS JOIN LATERAL generate_series(
    public.combine_bracket_schedule_timestamp((day_item.value ->> 'date')::date, (day_item.value ->> 'start_time')::time),
    public.combine_bracket_schedule_timestamp((day_item.value ->> 'date')::date, (day_item.value ->> 'end_time')::time) - make_interval(mins => duration.duration_minutes),
    make_interval(mins => duration.duration_minutes)
  ) slot_start
  WHERE NOT EXISTS (
    SELECT 1 FROM jsonb_array_elements(COALESCE(job_record.payload -> 'resource_locks', '[]'::jsonb)) lock_item(value)
    WHERE lock_item.value ->> 'lock_mode' = 'HARD'
      AND lock_item.value ->> 'date' = day_item.value ->> 'date'
      AND lock_item.value ->> 'court_key' = court_item.value ->> 'court_key'
      AND slot_start < public.combine_bracket_schedule_timestamp((day_item.value ->> 'date')::date, (lock_item.value ->> 'end_time')::time)
      AND slot_start + make_interval(mins => duration.duration_minutes) > public.combine_bracket_schedule_timestamp((day_item.value ->> 'date')::date, (lock_item.value ->> 'start_time')::time)
  )
  AND NOT (
    NULLIF(day_item.value ->> 'break_start_time', '') IS NOT NULL
    AND NULLIF(day_item.value ->> 'break_end_time', '') IS NOT NULL
    AND slot_start < public.combine_bracket_schedule_timestamp(
      (day_item.value ->> 'date')::date,
      (day_item.value ->> 'break_end_time')::time
    )
    AND slot_start + make_interval(mins => duration.duration_minutes) >
      public.combine_bracket_schedule_timestamp(
        (day_item.value ->> 'date')::date,
        (day_item.value ->> 'break_start_time')::time
      )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements(COALESCE(job_record.payload -> 'knockout_program_blocks', '[]'::jsonb)) block_item(value)
    WHERE block_item.value ->> 'date' = day_item.value ->> 'date'
      AND block_item.value ->> 'court_key' = court_item.value ->> 'court_key'
      AND slot_start < public.combine_bracket_schedule_timestamp(
        (day_item.value ->> 'date')::date,
        (block_item.value ->> 'end_time')::time
      )
      AND slot_start + make_interval(mins => duration.duration_minutes) >
        public.combine_bracket_schedule_timestamp(
          (day_item.value ->> 'date')::date,
          (block_item.value ->> 'start_time')::time
        )
  )
  ON CONFLICT DO NOTHING;

  UPDATE championship_bracket_preview_private.jobs SET
    status = 'SCHEDULING', stage = 'Distribuindo jogos por dia',
    total_slots = (SELECT count(*) FROM championship_bracket_preview_private.slots WHERE job_id = _job_id),
    progress_percentage = 5, heartbeat_at = now(), updated_at = now()
  WHERE id = _job_id;
END;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.is_job_slot_within_day_bounds(_job_id uuid, _slot_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  SELECT COALESCE(EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.jobs AS jobs_table
    JOIN championship_bracket_preview_private.slots AS slots_table
      ON slots_table.job_id = jobs_table.id
      AND slots_table.id = _slot_id
    CROSS JOIN LATERAL jsonb_array_elements(
      COALESCE(jobs_table.payload -> 'schedule_days', '[]'::jsonb)
    ) AS day_item(value)
    WHERE jobs_table.id = _job_id
      AND day_item.value ->> 'date' = slots_table.event_date::text
      AND slots_table.start_at >= public.combine_bracket_schedule_timestamp(
        slots_table.event_date,
        (day_item.value ->> 'start_time')::time
      )
      AND slots_table.end_at <= public.combine_bracket_schedule_timestamp(
        slots_table.event_date,
        (day_item.value ->> 'end_time')::time
      )
  ), false);
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.is_manifest_csp_dynamic_candidate_eligible(_job_id uuid, _match_id uuid, _slot_id bigint, _rest_gap integer)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH candidate_context AS (
    SELECT
      matches_table.id AS match_id,
      matches_table.competition_id,
      matches_table.group_id,
      matches_table.round_number,
      matches_table.home_team_id,
      matches_table.away_team_id,
      competitions_table.sport_id,
      competitions_table.naipe,
      slots_table.id AS slot_id,
      slots_table.event_date,
      slots_table.court_key,
      slots_table.start_at,
      slots_table.end_at,
      slots_table.sequence_index
    FROM championship_bracket_preview_private.manifest_solver_candidates
      AS candidate
    JOIN championship_bracket_preview_private.matches
      AS matches_table
      ON matches_table.id = candidate.match_id
    JOIN championship_bracket_preview_private.competitions
      AS competitions_table
      ON competitions_table.id =
        matches_table.competition_id
    JOIN championship_bracket_preview_private.slots
      AS slots_table
      ON slots_table.id = candidate.slot_id
    WHERE candidate.job_id = _job_id
      AND candidate.match_id = _match_id
      AND candidate.slot_id = _slot_id
  )
  SELECT COALESCE(
    (
      SELECT
        NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.assignments
            AS occupied_assignment
          WHERE occupied_assignment.job_id = _job_id
            AND occupied_assignment.slot_id =
              candidate_context.slot_id
            AND occupied_assignment.match_id <>
              candidate_context.match_id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.matches
            AS earlier_match
          WHERE earlier_match.job_id = _job_id
            AND earlier_match.id <>
              candidate_context.match_id
            AND earlier_match.competition_id =
              candidate_context.competition_id
            AND earlier_match.group_id =
              candidate_context.group_id
            AND earlier_match.round_number <
              candidate_context.round_number
            AND NOT earlier_match.assigned
        )
        AND NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.assignments
            AS earlier_assignment
          JOIN championship_bracket_preview_private.matches
            AS earlier_match
            ON earlier_match.id =
              earlier_assignment.match_id
          JOIN championship_bracket_preview_private.slots
            AS earlier_slot
            ON earlier_slot.id =
              earlier_assignment.slot_id
          WHERE earlier_assignment.job_id = _job_id
            AND earlier_match.competition_id =
              candidate_context.competition_id
            AND earlier_match.group_id =
              candidate_context.group_id
            AND earlier_match.round_number <
              candidate_context.round_number
            AND earlier_slot.end_at >
              candidate_context.start_at
        )
        AND NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.assignments
            AS later_assignment
          JOIN championship_bracket_preview_private.matches
            AS later_match
            ON later_match.id =
              later_assignment.match_id
          JOIN championship_bracket_preview_private.slots
            AS later_slot
            ON later_slot.id =
              later_assignment.slot_id
          WHERE later_assignment.job_id = _job_id
            AND later_match.competition_id =
              candidate_context.competition_id
            AND later_match.group_id =
              candidate_context.group_id
            AND later_match.round_number >
              candidate_context.round_number
            AND candidate_context.end_at >
              later_slot.start_at
        )
        AND NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.assignments
            AS other_assignment
          JOIN championship_bracket_preview_private.matches
            AS other_match
            ON other_match.id =
              other_assignment.match_id
          JOIN championship_bracket_preview_private.competitions
            AS other_competition
            ON other_competition.id =
              other_match.competition_id
          JOIN championship_bracket_preview_private.slots
            AS other_slot
            ON other_slot.id =
              other_assignment.slot_id
          WHERE other_assignment.job_id = _job_id
            AND other_assignment.match_id <>
              candidate_context.match_id
            AND other_competition.naipe =
              candidate_context.naipe
            AND other_slot.event_date =
              candidate_context.event_date
            AND (
              other_match.home_team_id IN (
                candidate_context.home_team_id,
                candidate_context.away_team_id
              )
              OR other_match.away_team_id IN (
                candidate_context.home_team_id,
                candidate_context.away_team_id
              )
            )
            AND (
              CASE
                WHEN other_slot.court_key =
                  candidate_context.court_key
                THEN
                  candidate_context.sequence_index
                    IS NOT NULL
                  AND other_slot.sequence_index
                    IS NOT NULL
                  AND abs(
                    candidate_context.sequence_index
                      - other_slot.sequence_index
                  ) <
                  CASE
                    WHEN other_competition.sport_id =
                      candidate_context.sport_id
                    THEN 3
                    ELSE LEAST(
                      3,
                      GREATEST(
                        COALESCE(_rest_gap, 3),
                        2
                      )
                    )
                  END
                ELSE
                  abs(
                    extract(
                      epoch FROM (
                        other_slot.start_at
                          - candidate_context.start_at
                      )
                    ) / 60.0
                  ) <
                  GREATEST(
                    (
                      extract(
                        epoch FROM (
                          candidate_context.end_at
                            - candidate_context.start_at
                        )
                      ) / 60
                    )::integer,
                    (
                      extract(
                        epoch FROM (
                          other_slot.end_at
                            - other_slot.start_at
                        )
                      ) / 60
                    )::integer,
                    1
                  )
                  *
                  CASE
                    WHEN other_competition.sport_id =
                      candidate_context.sport_id
                    THEN 3
                    ELSE LEAST(
                      3,
                      GREATEST(
                        COALESCE(_rest_gap, 3),
                        2
                      )
                    )
                  END
              END
            )
        )
      FROM candidate_context
    ),
    false
  );
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.is_match_pair_rest_conflict(_job_id uuid, _candidate_match_id uuid, _candidate_slot_id bigint, _other_match_id uuid, _other_slot_id bigint, _required_gap integer DEFAULT 3)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH candidate_context AS (
    SELECT
      candidate_match.home_team_id,
      candidate_match.away_team_id,
      candidate_competition.sport_id,
      candidate_competition.naipe,
      candidate_slot.event_date,
      candidate_slot.court_key,
      candidate_slot.start_at,
      candidate_slot.end_at,
      candidate_slot.sequence_index
    FROM championship_bracket_preview_private.matches
      AS candidate_match
    JOIN championship_bracket_preview_private.competitions
      AS candidate_competition
      ON candidate_competition.id =
        candidate_match.competition_id
    JOIN championship_bracket_preview_private.slots
      AS candidate_slot
      ON candidate_slot.job_id =
        candidate_match.job_id
      AND candidate_slot.id =
        _candidate_slot_id
    WHERE candidate_match.job_id = _job_id
      AND candidate_match.id =
        _candidate_match_id
  ),
  other_context AS (
    SELECT
      other_match.home_team_id,
      other_match.away_team_id,
      other_competition.sport_id,
      other_competition.naipe,
      other_slot.event_date,
      other_slot.court_key,
      other_slot.start_at,
      other_slot.end_at,
      other_slot.sequence_index
    FROM championship_bracket_preview_private.matches
      AS other_match
    JOIN championship_bracket_preview_private.competitions
      AS other_competition
      ON other_competition.id =
        other_match.competition_id
    JOIN championship_bracket_preview_private.slots
      AS other_slot
      ON other_slot.job_id =
        other_match.job_id
      AND other_slot.id =
        _other_slot_id
    WHERE other_match.job_id = _job_id
      AND other_match.id =
        _other_match_id
  ),
  comparison AS (
    SELECT
      candidate_context.*,
      other_context.home_team_id
        AS other_home_team_id,
      other_context.away_team_id
        AS other_away_team_id,
      other_context.sport_id
        AS other_sport_id,
      other_context.naipe
        AS other_naipe,
      other_context.event_date
        AS other_event_date,
      other_context.court_key
        AS other_court_key,
      other_context.start_at
        AS other_start_at,
      other_context.end_at
        AS other_end_at,
      other_context.sequence_index
        AS other_sequence_index,
      CASE
        WHEN candidate_context.sport_id =
          other_context.sport_id
        THEN 3
        ELSE LEAST(
          3,
          GREATEST(
            COALESCE(_required_gap, 3),
            2
          )
        )
      END AS effective_required_gap
    FROM candidate_context
    CROSS JOIN other_context
  )
  SELECT COALESCE(
    (
      SELECT
        comparison.event_date =
          comparison.other_event_date
        AND comparison.naipe IS NOT NULL
        AND comparison.other_naipe IS NOT NULL
        AND comparison.naipe =
          comparison.other_naipe
        AND (
          comparison.other_home_team_id IN (
            comparison.home_team_id,
            comparison.away_team_id
          )
          OR comparison.other_away_team_id IN (
            comparison.home_team_id,
            comparison.away_team_id
          )
        )
        AND (
          CASE
            WHEN comparison.court_key =
              comparison.other_court_key
            THEN
              comparison.sequence_index
                IS NOT NULL
              AND comparison.other_sequence_index
                IS NOT NULL
              AND abs(
                comparison.sequence_index
                  - comparison.other_sequence_index
              ) < comparison.effective_required_gap
            ELSE
              abs(
                extract(
                  epoch FROM (
                    comparison.other_start_at
                      - comparison.start_at
                  )
                ) / 60.0
              ) <
              GREATEST(
                (
                  extract(
                    epoch FROM (
                      comparison.end_at
                        - comparison.start_at
                    )
                  ) / 60
                )::integer,
                (
                  extract(
                    epoch FROM (
                      comparison.other_end_at
                        - comparison.other_start_at
                    )
                  ) / 60
                )::integer,
                1
              )
              * comparison.effective_required_gap
          END
        )
      FROM comparison
    ),
    false
  );
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.is_match_rest_conflict(_job_id uuid, _candidate_match_id uuid, _candidate_slot_id bigint, _other_match_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  SELECT
    championship_bracket_preview_private.is_match_rest_conflict_with_gap(
      _job_id,
      _candidate_match_id,
      _candidate_slot_id,
      _other_match_id,
      3
    );
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.is_match_rest_conflict_with_gap(_job_id uuid, _candidate_match_id uuid, _candidate_slot_id bigint, _other_match_id uuid, _required_gap integer DEFAULT 3)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  SELECT COALESCE(
    (
      SELECT
        championship_bracket_preview_private.is_match_pair_rest_conflict(
          _job_id,
          _candidate_match_id,
          _candidate_slot_id,
          _other_match_id,
          other_assignment.slot_id,
          GREATEST(
            COALESCE(_required_gap, 3),
            1
          )
        )
      FROM championship_bracket_preview_private.assignments
        AS other_assignment
      WHERE other_assignment.job_id = _job_id
        AND other_assignment.match_id =
          _other_match_id
    ),
    false
  );
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.is_match_round_order_eligible(_job_id uuid, _match_id uuid, _slot_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH candidate_context AS (
    SELECT
      candidate_match.id,
      candidate_match.competition_id,
      candidate_match.group_id,
      candidate_match.round_number,
      candidate_slot.start_at,
      candidate_slot.end_at
    FROM championship_bracket_preview_private.matches AS candidate_match
    JOIN championship_bracket_preview_private.slots AS candidate_slot
      ON candidate_slot.job_id = candidate_match.job_id
      AND candidate_slot.id = _slot_id
    WHERE candidate_match.job_id = _job_id
      AND candidate_match.id = _match_id
  )
  SELECT COALESCE((
    SELECT
      NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.matches AS earlier_match
        WHERE earlier_match.job_id = _job_id
          AND earlier_match.id <> candidate_context.id
          AND earlier_match.competition_id = candidate_context.competition_id
          AND earlier_match.group_id = candidate_context.group_id
          AND earlier_match.round_number < candidate_context.round_number
          AND earlier_match.assigned = false
      )
      AND NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.assignments AS ordered_assignment
        JOIN championship_bracket_preview_private.matches AS ordered_match
          ON ordered_match.id = ordered_assignment.match_id
        JOIN championship_bracket_preview_private.slots AS ordered_slot
          ON ordered_slot.id = ordered_assignment.slot_id
        WHERE ordered_assignment.job_id = _job_id
          AND ordered_match.id <> candidate_context.id
          AND ordered_match.competition_id = candidate_context.competition_id
          AND ordered_match.group_id = candidate_context.group_id
          AND (
            (
              ordered_match.round_number < candidate_context.round_number
              AND ordered_slot.end_at > candidate_context.start_at
            )
            OR (
              ordered_match.round_number > candidate_context.round_number
              AND candidate_context.end_at > ordered_slot.start_at
            )
          )
      )
    FROM candidate_context
  ), false);
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.is_match_slot_eligible(_job_id uuid, _match_id uuid, _slot_id bigint, _check_rest boolean DEFAULT true)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH context AS (
    SELECT
      jobs_table.payload,
      matches_table.id AS match_id,
      matches_table.home_team_id,
      matches_table.away_team_id,
      competitions_table.sport_id,
      competitions_table.naipe,
      competitions_table.division,
      competitions_table.competition_key,
      slots_table.id AS slot_id,
      slots_table.event_date,
      slots_table.court_key,
      slots_table.start_at,
      slots_table.end_at,
      slots_table.preferred_naipe,
      slots_table.preferred_division,
      slots_table.sequence_mode,
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
    CROSS JOIN LATERAL championship_bracket_preview_private.resolve_slot_sport_target(
      jobs_table.payload,
      slots_table.event_date,
      slots_table.court_key,
      slots_table.sport_id
    ) AS slot_target
    WHERE jobs_table.id = _job_id
  )
  SELECT COALESCE((
    SELECT
      (
        context.sequence_mode <> 'GROUP_NAIPE'
        OR context.preferred_naipe IS NULL
        OR context.preferred_naipe = context.naipe
      )
      AND (
        context.preferred_division IS NULL
        OR context.preferred_division IS NOT DISTINCT FROM context.division
        OR context.sequence_mode <> 'GROUP_DIVISION'
      )
      AND public.is_championship_bracket_competition_slot_playable(
        context.payload,
        context.competition_key,
        context.event_date,
        context.start_at,
        context.end_at
      )
      AND public.is_championship_bracket_team_slot_playable(
        context.payload,
        context.home_team_id,
        context.competition_key,
        context.event_date,
        context.start_at,
        context.end_at
      )
      AND public.is_championship_bracket_team_slot_playable(
        context.payload,
        context.away_team_id,
        context.competition_key,
        context.event_date,
        context.start_at,
        context.end_at
      )
      AND championship_bracket_preview_private.is_job_slot_within_day_bounds(
        _job_id,
        _slot_id
      )
      AND championship_bracket_preview_private.is_match_round_order_eligible(
        _job_id,
        _match_id,
        _slot_id
      )
      AND (
        NOT context.has_sport_targets
        OR context.planned_match_count > (
          SELECT count(*)
          FROM championship_bracket_preview_private.assignments AS target_assignment
          JOIN championship_bracket_preview_private.slots AS target_slot
            ON target_slot.id = target_assignment.slot_id
          WHERE target_assignment.job_id = _job_id
            AND target_assignment.match_id <> _match_id
            AND target_slot.event_date = context.event_date
            AND target_slot.court_key = context.court_key
            AND target_slot.sport_id = context.sport_id
        )
      )
      AND NOT EXISTS (
        SELECT 1
        FROM championship_bracket_preview_private.assignments AS occupied_assignment
        JOIN championship_bracket_preview_private.slots AS occupied_slot
          ON occupied_slot.id = occupied_assignment.slot_id
        WHERE occupied_assignment.job_id = _job_id
          AND occupied_assignment.match_id <> _match_id
          AND occupied_slot.court_key = context.court_key
          AND occupied_slot.start_at < context.end_at
          AND occupied_slot.end_at > context.start_at
      )
      AND (
        NOT COALESCE(_check_rest, true)
        OR NOT EXISTS (
          SELECT 1
          FROM championship_bracket_preview_private.assignments AS previous_assignment
          WHERE previous_assignment.job_id = _job_id
            AND previous_assignment.match_id <> _match_id
            AND championship_bracket_preview_private.is_match_rest_conflict(
              _job_id,
              _match_id,
              _slot_id,
              previous_assignment.match_id
            )
        )
      )
    FROM context
  ), false);
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.is_match_slot_eligible_with_rest_gap(_job_id uuid, _match_id uuid, _slot_id bigint, _required_gap integer DEFAULT 3)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  SELECT
    championship_bracket_preview_private.is_match_slot_static_eligible(
      _job_id,
      _match_id,
      _slot_id
    )
    AND championship_bracket_preview_private.is_match_slot_eligible(
      _job_id,
      _match_id,
      _slot_id,
      false
    )
    AND NOT EXISTS (
      SELECT 1
      FROM championship_bracket_preview_private.assignments
        AS previous_assignment
      WHERE previous_assignment.job_id = _job_id
        AND previous_assignment.match_id <> _match_id
        AND championship_bracket_preview_private.is_match_rest_conflict_with_gap(
          _job_id,
          _match_id,
          _slot_id,
          previous_assignment.match_id,
          GREATEST(
            COALESCE(_required_gap, 3),
            1
          )
        )
    );
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.is_match_slot_static_eligible(_job_id uuid, _match_id uuid, _slot_id bigint)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
  WITH context AS (
    SELECT
      jobs_table.payload,
      matches_table.competition_id AS match_competition_id,
      competitions_table.sport_id,
      competitions_table.naipe,
      competitions_table.division,
      competitions_table.competition_key,
      matches_table.home_team_id,
      matches_table.away_team_id,
      slots_table.event_date,
      slots_table.start_at,
      slots_table.end_at,
      slots_table.preferred_naipe,
      slots_table.preferred_division,
      slots_table.sequence_mode,
      slots_table.structural_competition_id,
      slots_table.structural_phase
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
    WHERE jobs_table.id = _job_id
  )
  SELECT COALESCE(
    (
      SELECT
        (
          context.structural_phase IS NULL
          OR (
            context.structural_phase = 'GROUP_STAGE'
            AND context.structural_competition_id =
              context.match_competition_id
          )
        )
        AND (
          context.sequence_mode <> 'GROUP_NAIPE'
          OR context.preferred_naipe IS NULL
          OR context.preferred_naipe = context.naipe
        )
        AND (
          context.preferred_division IS NULL
          OR context.preferred_division
            IS NOT DISTINCT FROM context.division
          OR context.sequence_mode <> 'GROUP_DIVISION'
        )
        AND public.is_championship_bracket_competition_slot_playable(
          context.payload,
          context.competition_key,
          context.event_date,
          context.start_at,
          context.end_at
        )
        AND public.is_championship_bracket_team_slot_playable(
          context.payload,
          context.home_team_id,
          context.competition_key,
          context.event_date,
          context.start_at,
          context.end_at
        )
        AND public.is_championship_bracket_team_slot_playable(
          context.payload,
          context.away_team_id,
          context.competition_key,
          context.event_date,
          context.start_at,
          context.end_at
        )
        AND championship_bracket_preview_private.is_job_slot_within_day_bounds(
          _job_id,
          _slot_id
        )
      FROM context
    ),
    false
  );
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.normalize_relocation_metric_rest_gap()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
BEGIN
  IF NEW.rest_gap > 3 THEN
    NEW.rest_gap := 3;
  END IF;

  RETURN NEW;
END;
$function$;

SET check_function_bodies = on;
