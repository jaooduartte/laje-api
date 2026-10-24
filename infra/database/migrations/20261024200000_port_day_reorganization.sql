-- LAJE-150: original day rearrangement, court spacing and match redistribution logic.
-- Only exposed via authenticated laje-api. No DML is executed until an explicit request.

-- Original: apply_day_schedule_reorganization(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
CREATE OR REPLACE FUNCTION public.apply_day_schedule_reorganization(_bracket_edition_id uuid, _payload jsonb, _expected_revision bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  preview JSONB;
  current_revision BIGINT;
  target_date DATE;
  next_day_start TIME;
  next_day_end TIME;
  primary_break_id UUID;
  break_policy TEXT;
  next_break_start TIME;
  next_break_end TIME;
BEGIN
  IF COALESCE(jsonb_array_length(COALESCE(_payload->'match_ids', '[]'::JSONB)), 0) = 0
    OR jsonb_array_length(COALESCE(_payload->'placed_match_ids', '[]'::JSONB)) <> jsonb_array_length(COALESCE(_payload->'match_ids', '[]'::JSONB))
    OR EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text(COALESCE(_payload->'placed_match_ids', '[]'::JSONB)) AS placed_match_id
      WHERE NOT (COALESCE(_payload->'match_ids', '[]'::JSONB) ? placed_match_id)
    )
  THEN
    RAISE EXCEPTION 'Posicione todos os jogos selecionados antes de confirmar.';
  END IF;

  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para reorganizar a programação.';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(format('day-schedule-reorganization:%s', _bracket_edition_id), 0));

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

  preview := public.build_day_schedule_reorganization_preview(_bracket_edition_id, _payload);

  IF jsonb_array_length(COALESCE(preview->'blockers', '[]'::JSONB)) > 0
    OR EXISTS (
      SELECT 1
      FROM jsonb_array_elements(COALESCE(preview->'timeline', '[]'::JSONB)) AS timeline_item
      WHERE jsonb_array_length(COALESCE(timeline_item->'rest_conflicts', '[]'::JSONB)) > 0
    )
  THEN
    RAISE EXCEPTION 'A reorganização possui conflitos e não pode ser aplicada.';
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
    manual_schedule_override_notes = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.manual_schedule_override_notes END,
    is_pending_manual_relocation = CASE WHEN changes_json.is_selected THEN false ELSE matches_table.is_pending_manual_relocation END,
    pending_manual_relocation_reason = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_reason END,
    pending_manual_relocation_notes = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_notes END,
    pending_manual_relocation_previous_schedule = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_previous_schedule END,
    pending_manual_relocation_previous_label = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_previous_label END,
    pending_manual_relocation_created_by = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_created_by END,
    pending_manual_relocation_at = CASE WHEN changes_json.is_selected THEN NULL ELSE matches_table.pending_manual_relocation_at END
  FROM jsonb_to_recordset(preview->'changes') AS changes_json(item_type TEXT, match_id UUID, is_selected BOOLEAN, after JSONB)
  CROSS JOIN LATERAL jsonb_to_record(changes_json.after) AS changes_table(scheduled_date DATE, location TEXT, court_name TEXT, start_time TIMESTAMPTZ, end_time TIMESTAMPTZ, queue_position INTEGER, scheduled_slot INTEGER)
  WHERE changes_json.item_type = 'MATCH'
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
  next_day_start := (preview->>'next_day_start')::TIME;
  next_day_end := (preview->>'next_day_end')::TIME;
  primary_break_id := NULLIF(preview->'break'->'before'->>'id', '')::UUID;
  break_policy := preview->'break'->>'policy';
  next_break_start := NULLIF(preview->'break'->'after'->>'start_time', '')::TIME;
  next_break_end := NULLIF(preview->'break'->'after'->>'end_time', '')::TIME;

  UPDATE public.championship_bracket_days
  SET
    start_time = LEAST(start_time, next_day_start),
    end_time = GREATEST(end_time, next_day_end)
  WHERE bracket_edition_id = _bracket_edition_id
    AND event_date = target_date;

  IF primary_break_id IS NOT NULL AND break_policy = 'REMOVE' THEN
    DELETE FROM public.championship_bracket_day_breaks
    WHERE id = primary_break_id;
  ELSIF primary_break_id IS NOT NULL AND next_break_start IS NOT NULL AND next_break_end IS NOT NULL THEN
    UPDATE public.championship_bracket_day_breaks
    SET break_start_time = next_break_start,
        break_end_time = next_break_end
    WHERE id = primary_break_id;
  END IF;

  UPDATE public.championship_bracket_days AS days_table
  SET
    break_start_time = (
      SELECT breaks_table.break_start_time
      FROM public.championship_bracket_day_breaks AS breaks_table
      WHERE breaks_table.bracket_day_id = days_table.id
        AND breaks_table.scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
      ORDER BY breaks_table.position, breaks_table.break_start_time
      LIMIT 1
    ),
    break_end_time = (
      SELECT breaks_table.break_end_time
      FROM public.championship_bracket_day_breaks AS breaks_table
      WHERE breaks_table.bracket_day_id = days_table.id
        AND breaks_table.scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
      ORDER BY breaks_table.position, breaks_table.break_start_time
      LIMIT 1
    )
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND days_table.event_date = target_date;

  IF break_policy = 'REMOVE'
    AND _payload ? 'removable_resource_lock'
  THEN
    UPDATE public.championship_bracket_editions
    SET payload_snapshot = jsonb_set(
      payload_snapshot,
      '{resource_locks}',
      COALESCE((
        SELECT jsonb_agg(resource_lock.value)
        FROM jsonb_array_elements(COALESCE(payload_snapshot->'resource_locks', '[]'::JSONB)) AS resource_lock(value)
        WHERE NOT (
          resource_lock.value->>'date' = _payload->'removable_resource_lock'->>'date'
          AND resource_lock.value->>'location_key' = _payload->'removable_resource_lock'->>'location_group_id'
          AND resource_lock.value->>'court_key' = _payload->'removable_resource_lock'->>'court_group_id'
          AND resource_lock.value->>'start_time' = _payload->'removable_resource_lock'->>'start_time'
          AND resource_lock.value->>'end_time' = _payload->'removable_resource_lock'->>'end_time'
          AND COALESCE(resource_lock.value->>'lock_mode', '') = 'HARD'
          AND NULLIF(resource_lock.value->>'sport_id', '') IS NULL
          AND NULLIF(resource_lock.value->>'naipe', '') IS NULL
          AND NULLIF(resource_lock.value->>'division', '') IS NULL
        )
      ), '[]'::JSONB),
      true
    )
    WHERE id = _bracket_edition_id;
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

-- Original: apply_society_2026_official_schedule(_bracket_edition_id uuid)
CREATE OR REPLACE FUNCTION public.apply_society_2026_official_schedule(_bracket_edition_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  target_bracket_edition_id CONSTANT uuid := 'a63df7b3-752e-421a-bf08-dcebeef99643'::uuid;
  target_championship_id CONSTANT uuid := '17b92cf5-dd92-44eb-9295-b28000372e4b'::uuid;
  target_season_year CONSTANT integer := 2026;
  target_sport_name CONSTANT text := 'Futebol Society';
  expected_group_stage_match_count CONSTANT integer := 45;
  matched_group_stage_match_count integer := 0;
BEGIN
  IF _bracket_edition_id IS DISTINCT FROM target_bracket_edition_id THEN
    RETURN;
  END IF;

  PERFORM set_config('app.skip_queue_trigger', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  DROP TABLE IF EXISTS tmp_society_2026_official_schedule_rows;
  CREATE TEMP TABLE tmp_society_2026_official_schedule_rows (
    phase public.bracket_phase NOT NULL,
    competition_id UUID NULL,
    round_number INTEGER NULL,
    slot_number INTEGER NULL,
    is_third_place BOOLEAN NOT NULL DEFAULT false,
    scheduled_date DATE NOT NULL,
    location TEXT NOT NULL,
    court_name TEXT NOT NULL,
    planned_start_time TIME NOT NULL,
    scheduled_slot INTEGER NOT NULL,
    queue_position INTEGER NOT NULL,
    naipe public.match_naipe NOT NULL,
    division public.team_division NULL,
    home_team_name TEXT NULL,
    away_team_name TEXT NULL,
    sheet_representation TEXT NULL
  ) ON COMMIT DROP;

  INSERT INTO tmp_society_2026_official_schedule_rows (
    phase,
    competition_id,
    round_number,
    slot_number,
    is_third_place,
    scheduled_date,
    location,
    court_name,
    planned_start_time,
    scheduled_slot,
    queue_position,
    naipe,
    division,
    home_team_name,
    away_team_name,
    sheet_representation
  )
  VALUES
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '08:00',  1,  1, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'AAAUS',     'RASANTE',   'CO'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '08:40',  2,  2, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'RAPOSAS',   'AAAMU',     'AAAUS x RASANTE'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '09:20',  3,  3, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'GARRUDOS',  'CCT',       'RAPOSAS x AAAMU'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '10:00',  4,  4, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'TAUROS',    'CAMALEÃO',  'GARRUDOS x CCT'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '10:40',  5,  5, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'AAAMU',     'UEFA',      'TAUROS x CAMALEÃO'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '11:20',  6,  6, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'GARRUDOS',  'RASANTE',   'AAAMU x UEFA'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '13:00',  7,  7, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'ATENUN',    'TAUROS',    'GARRUDOS x RASANTE'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '13:40',  8,  8, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'AAASF',     'CCT',       'ATENUN x TAUROS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '14:20',  9,  9, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'CAMALEÃO',  'RAPOSAS',   'AAASF x CCT'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '15:00', 10, 10, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'AAASF',     'RASANTE',   'CAMALEÃO x RAPOSAS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '15:40', 11, 11, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'TAUROS',    'ADIN',      'AAASF x RASANTE'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '16:20', 12, 12, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'UEFA',      'GARRUDOS',  'TAUROS x ADIN'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '17:00', 13, 13, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'ATENUN',    'AAAMU',     'UEFA x GARRUDOS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '17:40', 14, 14, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'AAASF',     'CAMALEÃO',  'ATENUN x AAAMU'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '18:20', 15, 15, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'ATENUN',    'AAAUS',     'AAASF x CAMALEÃO'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '19:00', 16, 16, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'CCT',       'AAAMU',     'ATENUN x AAAUS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '19:40', 17, 17, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'AAASF',     'UEFA',      'CCT x AAAMU'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra A', time '20:20', 18, 18, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'RASANTE',   'RAPOSAS',   'AAASF x UEFA'),

    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '08:00',  1,  1, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'AAJ',       'ABUS',      'CO'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '10:00',  4,  2, 'FEMININO'::public.match_naipe,  'DIVISAO_ACESSO'::public.team_division,     'AFA',       'AMEN',      'AAJ x ABUS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '10:40',  5,  3, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'ENGÊNIOS',  'AACOM',     'AFA x AMEN'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '11:20',  6,  4, 'FEMININO'::public.match_naipe,  'DIVISAO_ACESSO'::public.team_division,     'AGUA',      'SOBERANOS', 'ENGÊNIOS x AACOM'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '13:00',  7,  5, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'UCA',       'AMEN',      'AGUA x SOBERANOS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '13:40',  8,  6, 'FEMININO'::public.match_naipe,  'DIVISAO_ACESSO'::public.team_division,     'AFA',       'AAJ',       'UCA x AMEN'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '14:20',  9,  7, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'ACATO',     'SOBERANOS', 'AFA x AAJ'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '15:00', 10,  8, 'FEMININO'::public.match_naipe,  'DIVISAO_ACESSO'::public.team_division,     'AGUA',      'UCA',       'ACATO x SOBERANOS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '15:40', 11,  9, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'AAJ',       'ENGÊNIOS',  'AGUA x UCA'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '16:20', 12, 10, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'ABUS',      'AACOM',     'AAJ x ENGÊNIOS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '17:00', 13, 11, 'FEMININO'::public.match_naipe,  'DIVISAO_ACESSO'::public.team_division,     'AMEN',      'AAJ',       'ABUS x AACOM'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '17:40', 14, 12, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'AFA',       'SOBERANOS', 'AMEN x AAJ'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '18:20', 15, 13, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'UCA',       'AGUA',      'AFA x SOBERANOS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '19:00', 16, 14, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'ABUS',      'ENGÊNIOS',  'UCA x AGUA'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-20'::date, 'Arena Seven', 'Quadra B', time '19:40', 17, 15, 'FEMININO'::public.match_naipe,  'DIVISAO_ACESSO'::public.team_division,     'UCA',       'SOBERANOS', 'ABUS x ENGÊNIOS'),

    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '08:00',  1, 19, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'GARRUDOS',  'AAAUS',     'CO'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '08:40',  2, 20, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'ADIN',      'CAMALEÃO',  'GARRUDOS x AAAUS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '09:20',  3, 21, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'RAPOSAS',   'AAASF',     'ADIN x CAMALEÃO'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '10:00',  4, 22, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'AAAMU',     'GARRUDOS',  'RAPOSAS x AAASF'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '10:40',  5, 23, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'UEFA',      'CCT',       'AAAMU x GARRUDOS'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '11:20',  6, 24, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'AAAUS',     'TAUROS',    'UEFA x CCT'),

    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '08:00',  1, 17, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'AMEN',      'AGUA',      'CO'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '08:40',  2, 18, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'AACOM',     'AAJ',       'AMEN x AGUA'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '09:20',  3, 19, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'CCT',       'UEFA',      'AACOM x AAJ'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '10:00',  4, 20, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, 'CAMALEÃO',  'RASANTE',   'CCT x UEFA'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '10:40',  5, 21, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, 'ATENUN',    'RAPOSAS',   'CAMALEÃO x RASANTE'),
    ('GROUP_STAGE'::public.bracket_phase, NULL, NULL, NULL, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '11:20',  6, 16, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     'ACATO',     'AFA',       'ATENUN x RAPOSAS'),

    ('KNOCKOUT'::public.bracket_phase, 'c1cef97e-0589-48dd-b278-9badf0fc51e9'::uuid, 1, 1, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '13:00',  7, 25, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, NULL, NULL, NULL),
    ('KNOCKOUT'::public.bracket_phase, 'c1cef97e-0589-48dd-b278-9badf0fc51e9'::uuid, 1, 2, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '13:40',  8, 26, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, NULL, NULL, NULL),
    ('KNOCKOUT'::public.bracket_phase, '806dc1b5-bdb8-473e-9bce-16d6bd8e5b75'::uuid, 1, 1, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '14:20',  9, 27, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, NULL, NULL, NULL),
    ('KNOCKOUT'::public.bracket_phase, '806dc1b5-bdb8-473e-9bce-16d6bd8e5b75'::uuid, 1, 2, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '15:00', 10, 28, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, NULL, NULL, NULL),

    ('KNOCKOUT'::public.bracket_phase, 'e2b305c3-999f-4f35-b6a3-10da8ce10a4a'::uuid, 1, 1, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '13:00',  7, 22, 'FEMININO'::public.match_naipe,  'DIVISAO_ACESSO'::public.team_division,     NULL, NULL, NULL),
    ('KNOCKOUT'::public.bracket_phase, 'e2b305c3-999f-4f35-b6a3-10da8ce10a4a'::uuid, 1, 2, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '13:40',  8, 23, 'FEMININO'::public.match_naipe,  'DIVISAO_ACESSO'::public.team_division,     NULL, NULL, NULL),
    ('KNOCKOUT'::public.bracket_phase, 'aabfaf6f-0e28-4285-94d0-b2ab6c89b903'::uuid, 1, 1, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '14:20',  9, 24, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     NULL, NULL, NULL),
    ('KNOCKOUT'::public.bracket_phase, 'aabfaf6f-0e28-4285-94d0-b2ab6c89b903'::uuid, 1, 2, false, '2026-06-21'::date, 'Arena Seven', 'Quadra B', time '15:00', 10, 25, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     NULL, NULL, NULL),

    ('KNOCKOUT'::public.bracket_phase, 'e2b305c3-999f-4f35-b6a3-10da8ce10a4a'::uuid, 2, 1, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '15:45', 11, 29, 'FEMININO'::public.match_naipe,  'DIVISAO_ACESSO'::public.team_division,     NULL, NULL, NULL),
    ('KNOCKOUT'::public.bracket_phase, 'aabfaf6f-0e28-4285-94d0-b2ab6c89b903'::uuid, 2, 1, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '16:30', 12, 30, 'MASCULINO'::public.match_naipe, 'DIVISAO_ACESSO'::public.team_division,     NULL, NULL, NULL),
    ('KNOCKOUT'::public.bracket_phase, 'c1cef97e-0589-48dd-b278-9badf0fc51e9'::uuid, 2, 1, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '17:15', 13, 31, 'FEMININO'::public.match_naipe,  'DIVISAO_PRINCIPAL'::public.team_division, NULL, NULL, NULL),
    ('KNOCKOUT'::public.bracket_phase, '806dc1b5-bdb8-473e-9bce-16d6bd8e5b75'::uuid, 2, 1, false, '2026-06-21'::date, 'Arena Seven', 'Quadra A', time '18:00', 14, 32, 'MASCULINO'::public.match_naipe, 'DIVISAO_PRINCIPAL'::public.team_division, NULL, NULL, NULL);

  DROP TABLE IF EXISTS tmp_society_2026_group_stage_matches;
  CREATE TEMP TABLE tmp_society_2026_group_stage_matches AS
  SELECT
    official_rows.*,
    matches_table.id AS match_id,
    matches_table.status AS match_status
  FROM tmp_society_2026_official_schedule_rows AS official_rows
  JOIN public.matches AS matches_table
    ON matches_table.championship_id = target_championship_id
    AND matches_table.season_year = target_season_year
    AND matches_table.naipe = official_rows.naipe
    AND matches_table.division IS NOT DISTINCT FROM official_rows.division
  JOIN public.sports AS sports_table
    ON sports_table.id = matches_table.sport_id
    AND sports_table.name = target_sport_name
  JOIN public.teams AS home_teams_table
    ON home_teams_table.id = matches_table.home_team_id
    AND public.normalize_bracket_entity_name(home_teams_table.name) = public.normalize_bracket_entity_name(official_rows.home_team_name)
  JOIN public.teams AS away_teams_table
    ON away_teams_table.id = matches_table.away_team_id
    AND public.normalize_bracket_entity_name(away_teams_table.name) = public.normalize_bracket_entity_name(official_rows.away_team_name)
  JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.match_id = matches_table.id
    AND bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
    AND bracket_matches_table.bracket_edition_id = target_bracket_edition_id
  WHERE official_rows.phase = 'GROUP_STAGE'::public.bracket_phase;

  SELECT count(*)::integer
  INTO matched_group_stage_match_count
  FROM tmp_society_2026_group_stage_matches;

  IF matched_group_stage_match_count <> expected_group_stage_match_count THEN
    RAISE EXCEPTION
      'A agenda oficial do Society 2026 esperava mapear % jogos de grupos, mas encontrou %.',
      expected_group_stage_match_count,
      matched_group_stage_match_count;
  END IF;

  UPDATE public.matches AS matches_table
  SET
    scheduled_slot = NULL,
    queue_position = NULL
  FROM tmp_society_2026_group_stage_matches AS group_stage_matches_table
  WHERE matches_table.id = group_stage_matches_table.match_id
    AND matches_table.status = 'SCHEDULED'::public.match_status;

  UPDATE public.matches AS matches_table
  SET
    scheduled_date = group_stage_matches_table.scheduled_date,
    location = group_stage_matches_table.location,
    court_name = group_stage_matches_table.court_name,
    scheduled_slot = group_stage_matches_table.scheduled_slot,
    queue_position = group_stage_matches_table.queue_position,
    start_time = CASE
      WHEN matches_table.status = 'SCHEDULED'::public.match_status THEN
        public.combine_bracket_schedule_timestamp(
          group_stage_matches_table.scheduled_date,
          group_stage_matches_table.planned_start_time
        )
      ELSE matches_table.start_time
    END,
    end_time = CASE
      WHEN matches_table.status = 'SCHEDULED'::public.match_status THEN
        public.combine_bracket_schedule_timestamp(
          group_stage_matches_table.scheduled_date,
          group_stage_matches_table.planned_start_time
        ) + interval '40 minutes'
      ELSE matches_table.end_time
    END
  FROM tmp_society_2026_group_stage_matches AS group_stage_matches_table
  WHERE matches_table.id = group_stage_matches_table.match_id
    AND matches_table.status = 'SCHEDULED'::public.match_status;

  DROP TABLE IF EXISTS tmp_society_2026_knockout_matches;
  CREATE TEMP TABLE tmp_society_2026_knockout_matches AS
  SELECT
    official_rows.*,
    matches_table.id AS match_id,
    matches_table.status AS match_status
  FROM tmp_society_2026_official_schedule_rows AS official_rows
  JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.bracket_edition_id = target_bracket_edition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.competition_id = official_rows.competition_id
    AND bracket_matches_table.round_number = official_rows.round_number
    AND bracket_matches_table.slot_number = official_rows.slot_number
    AND COALESCE(bracket_matches_table.is_third_place, false) = official_rows.is_third_place
    AND bracket_matches_table.match_id IS NOT NULL
  JOIN public.matches AS matches_table
    ON matches_table.id = bracket_matches_table.match_id
    AND matches_table.championship_id = target_championship_id
    AND matches_table.season_year = target_season_year
  WHERE official_rows.phase = 'KNOCKOUT'::public.bracket_phase;

  UPDATE public.matches AS matches_table
  SET
    scheduled_slot = NULL,
    queue_position = NULL
  FROM tmp_society_2026_knockout_matches AS knockout_matches_table
  WHERE matches_table.id = knockout_matches_table.match_id
    AND matches_table.status = 'SCHEDULED'::public.match_status;

  UPDATE public.matches AS matches_table
  SET
    scheduled_date = knockout_matches_table.scheduled_date,
    location = knockout_matches_table.location,
    court_name = knockout_matches_table.court_name,
    scheduled_slot = knockout_matches_table.scheduled_slot,
    queue_position = knockout_matches_table.queue_position,
    start_time = CASE
      WHEN matches_table.status = 'SCHEDULED'::public.match_status THEN
        public.combine_bracket_schedule_timestamp(
          knockout_matches_table.scheduled_date,
          knockout_matches_table.planned_start_time
        )
      ELSE matches_table.start_time
    END,
    end_time = CASE
      WHEN matches_table.status = 'SCHEDULED'::public.match_status THEN
        public.combine_bracket_schedule_timestamp(
          knockout_matches_table.scheduled_date,
          knockout_matches_table.planned_start_time
        ) + interval '40 minutes'
      ELSE matches_table.end_time
    END
  FROM tmp_society_2026_knockout_matches AS knockout_matches_table
  WHERE matches_table.id = knockout_matches_table.match_id
    AND matches_table.status = 'SCHEDULED'::public.match_status;
END;
$function$;

-- Original: build_day_schedule_reorganization_preview(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.build_day_schedule_reorganization_preview(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  selected_match_ids UUID[];
  source_match_ids UUID[];
  selected_matches_count INTEGER;
  selected_championship_id UUID;
  selected_season_year INTEGER;
  target_date DATE;
  target_location TEXT;
  target_court_name TEXT;
  target_start_time TIME;
  strategy TEXT;
  break_policy TEXT;
  relocation_reason TEXT;
  manual_court_item_order JSONB;
  day_record RECORD;
  target_location_record RECORD;
  target_court_record RECORD;
  primary_break_record RECORD;
  knockout_anchor_record RECORD;
  item_record RECORD;
  plan_record RECORD;
  current_candidate_start TIMESTAMPTZ;
  candidate_end TIMESTAMPTZ;
  conflicting_end TIMESTAMPTZ;
  day_start_at TIMESTAMPTZ;
  day_end_at TIMESTAMPTZ;
  next_day_start_at TIMESTAMPTZ;
  next_day_end_at TIMESTAMPTZ;
  next_break_start_at TIMESTAMPTZ;
  next_break_end_at TIMESTAMPTZ;
  primary_break_duration INTERVAL;
  candidate_court_position INTEGER;
  loop_count INTEGER;
  should_recalculate_target_court BOOLEAN := false;
  changes JSONB := '[]'::JSONB;
  timeline JSONB := '[]'::JSONB;
  blockers JSONB := '[]'::JSONB;
  revision_value BIGINT;
  edition_payload JSONB;
  previous_day_start TEXT;
  previous_day_end TEXT;
  should_reposition_target_court_break BOOLEAN := false;
BEGIN
  SELECT array_agg(value::UUID)
  INTO source_match_ids
  FROM jsonb_array_elements_text(COALESCE(_payload->'match_ids', '[]'::JSONB)) AS value;

  SELECT array_agg(value::UUID)
  INTO selected_match_ids
  FROM jsonb_array_elements_text(COALESCE(_payload->'placed_match_ids', '[]'::JSONB)) AS value;

  target_date := NULLIF(_payload->>'target_date', '')::DATE;
  target_location := NULLIF(trim(COALESCE(_payload->>'target_location', '')), '');
  target_court_name := NULLIF(trim(COALESCE(_payload->>'target_court_name', '')), '');
  target_start_time := NULLIF(_payload->>'day_start_time', '')::TIME;
  strategy := upper(trim(COALESCE(_payload->>'strategy', '')));
  break_policy := upper(trim(COALESCE(_payload->>'break_policy', '')));
  relocation_reason := upper(trim(COALESCE(_payload->>'reason', '')));
  manual_court_item_order := COALESCE(_payload->'manual_court_item_order', '{}'::JSONB);

  IF COALESCE(cardinality(source_match_ids), 0) = 0 THEN
    RAISE EXCEPTION 'Selecione ao menos um jogo aguardando realocação.';
  END IF;

  IF COALESCE(cardinality(selected_match_ids), 0) > 0
    AND NOT (selected_match_ids <@ source_match_ids)
  THEN
    RAISE EXCEPTION 'Os jogos posicionados precisam pertencer à seleção original.';
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

  IF strategy NOT IN ('START', 'END', 'AUTO', 'MANUAL') THEN
    RAISE EXCEPTION 'Informe uma estratégia válida para a reorganização.';
  END IF;

  IF strategy = 'MANUAL'
    AND COALESCE(cardinality(selected_match_ids), 0) > 0
    AND EXISTS (
      SELECT 1
      FROM unnest(selected_match_ids) AS selected_match_item(match_id)
      WHERE NOT EXISTS (
        SELECT 1
        FROM jsonb_each(manual_court_item_order) AS court_order(court_name, item_ids)
        CROSS JOIN LATERAL jsonb_array_elements_text(court_order.item_ids) AS manual_order_item(item_id)
        WHERE manual_order_item.item_id = selected_match_item.match_id::TEXT
      )
    )
  THEN
    RAISE EXCEPTION 'Posicione todos os jogos selecionados no cronograma.';
  END IF;

  IF break_policy NOT IN ('KEEP_BEFORE_KNOCKOUT', 'REMOVE') THEN
    RAISE EXCEPTION 'Informe uma política válida para o intervalo.';
  END IF;

  IF relocation_reason NOT IN ('WEATHER', 'COURT_UNAVAILABLE', 'OPERATIONAL_DELAY', 'SAFETY', 'OTHER') THEN
    RAISE EXCEPTION 'Informe um motivo válido para a reorganização.';
  END IF;

  SELECT editions_table.championship_id, editions_table.season_year, editions_table.reprogramming_revision, editions_table.payload_snapshot
  INTO selected_championship_id, selected_season_year, revision_value, edition_payload
  FROM public.championship_bracket_editions AS editions_table
  WHERE editions_table.id = _bracket_edition_id;

  IF selected_championship_id IS NULL THEN
    RAISE EXCEPTION 'Edição de chaveamento inválida.';
  END IF;

  SELECT days_table.*
  INTO day_record
  FROM public.championship_bracket_days AS days_table
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND days_table.event_date = target_date;

  IF day_record.id IS NULL THEN
    RAISE EXCEPTION 'O dia de destino não está configurado na agenda do campeonato.';
  END IF;

  SELECT locations_table.*
  INTO target_location_record
  FROM public.championship_bracket_locations AS locations_table
  WHERE locations_table.bracket_day_id = day_record.id
    AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(target_location);

  IF target_location_record.id IS NULL THEN
    RAISE EXCEPTION 'O local de destino não está configurado nesse dia.';
  END IF;

  SELECT courts_table.*
  INTO target_court_record
  FROM public.championship_bracket_courts AS courts_table
  WHERE courts_table.bracket_location_id = target_location_record.id
    AND public.normalize_bracket_entity_name(courts_table.name) = public.normalize_bracket_entity_name(target_court_name);

  IF target_court_record.id IS NULL THEN
    RAISE EXCEPTION 'A quadra de destino não está configurada nesse dia.';
  END IF;

  SELECT count(*)
  INTO selected_matches_count
  FROM public.matches AS matches_table
  JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.match_id = matches_table.id
  WHERE bracket_matches_table.bracket_edition_id = _bracket_edition_id
    AND matches_table.id = ANY(source_match_ids)
    AND matches_table.status = 'SCHEDULED'::public.match_status
    AND COALESCE(matches_table.is_pending_manual_relocation, false);

  IF selected_matches_count <> cardinality(source_match_ids) THEN
    RAISE EXCEPTION 'Somente jogos aguardando realocação desta edição podem ser reorganizados.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.matches AS matches_table
    WHERE matches_table.id = ANY(source_match_ids)
      AND NOT EXISTS (
        SELECT 1
        FROM public.championship_bracket_court_sports AS court_sports_table
        WHERE court_sports_table.bracket_court_id = target_court_record.id
          AND court_sports_table.sport_id = matches_table.sport_id
      )
  ) THEN
    RAISE EXCEPTION 'A quadra de destino não atende todas as modalidades selecionadas.';
  END IF;

  CREATE TEMP TABLE day_schedule_reorganization_items (
    item_type TEXT NOT NULL,
    item_id UUID NOT NULL,
    match_id UUID NULL,
    placeholder_id UUID NULL,
    label TEXT NOT NULL,
    is_selected BOOLEAN NOT NULL,
    is_fixed BOOLEAN NOT NULL,
    is_knockout BOOLEAN NOT NULL,
    bracket_court_id UUID NOT NULL,
    court_group_id UUID NOT NULL,
    location_group_id UUID NOT NULL,
    location_name TEXT NOT NULL,
    court_name TEXT NOT NULL,
    court_position INTEGER NOT NULL,
    sport_id UUID NOT NULL,
    naipe public.match_naipe NOT NULL,
    home_team_id UUID NULL,
    away_team_id UUID NULL,
    duration_minutes INTEGER NOT NULL,
    original_start_at TIMESTAMPTZ NULL,
    original_end_at TIMESTAMPTZ NULL,
    original_queue_position INTEGER NULL,
    original_scheduled_slot INTEGER NULL,
    selection_order INTEGER NULL,
    manual_order_position INTEGER NULL,
    planned_start_at TIMESTAMPTZ NULL,
    planned_end_at TIMESTAMPTZ NULL,
    planned_court_position INTEGER NULL,
    planned_queue_position INTEGER NULL,
    planned_scheduled_slot INTEGER NULL
  ) ON COMMIT DROP;

  INSERT INTO day_schedule_reorganization_items (
    item_type, item_id, match_id, placeholder_id, label, is_selected, is_fixed, is_knockout,
    bracket_court_id, court_group_id, location_group_id, location_name, court_name, court_position,
    sport_id, naipe, home_team_id, away_team_id, duration_minutes, original_start_at,
    original_end_at, original_queue_position, original_scheduled_slot
  )
  SELECT
    'MATCH',
    matches_table.id,
    matches_table.id,
    NULL,
    concat_ws(' x ', home_teams_table.name, away_teams_table.name),
    false,
    matches_table.status <> 'SCHEDULED'::public.match_status
      OR COALESCE(matches_table.is_manual_schedule_override, false),
    bracket_matches_table.phase <> 'GROUP_STAGE'::public.bracket_phase,
    courts_table.id,
    courts_table.court_group_id,
    locations_table.location_group_id,
    locations_table.name,
    courts_table.name,
    courts_table.position,
    matches_table.sport_id,
    matches_table.naipe,
    matches_table.home_team_id,
    matches_table.away_team_id,
    GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1),
    matches_table.start_time,
    COALESCE(matches_table.end_time, matches_table.start_time + make_interval(mins => GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1))),
    matches_table.queue_position,
    matches_table.scheduled_slot
  FROM public.matches AS matches_table
  JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.match_id = matches_table.id
    AND bracket_matches_table.bracket_edition_id = _bracket_edition_id
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.bracket_day_id = day_record.id
    AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(matches_table.location)
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
    AND public.normalize_bracket_entity_name(courts_table.name) = public.normalize_bracket_entity_name(matches_table.court_name)
  LEFT JOIN public.championship_sports AS championship_sports_table
    ON championship_sports_table.championship_id = matches_table.championship_id
    AND championship_sports_table.sport_id = matches_table.sport_id
  LEFT JOIN public.teams AS home_teams_table ON home_teams_table.id = matches_table.home_team_id
  LEFT JOIN public.teams AS away_teams_table ON away_teams_table.id = matches_table.away_team_id
  WHERE matches_table.championship_id = selected_championship_id
    AND matches_table.season_year = selected_season_year
    AND matches_table.scheduled_date = target_date
    AND locations_table.id = target_location_record.id
    AND COALESCE(matches_table.is_pending_manual_relocation, false) = false;

  INSERT INTO day_schedule_reorganization_items (
    item_type, item_id, match_id, placeholder_id, label, is_selected, is_fixed, is_knockout,
    bracket_court_id, court_group_id, location_group_id, location_name, court_name, court_position,
    sport_id, naipe, home_team_id, away_team_id, duration_minutes, original_start_at,
    original_end_at, original_queue_position, original_scheduled_slot, selection_order
  )
  SELECT
    'MATCH',
    matches_table.id,
    matches_table.id,
    NULL,
    concat_ws(' x ', home_teams_table.name, away_teams_table.name),
    true,
    false,
    bracket_matches_table.phase <> 'GROUP_STAGE'::public.bracket_phase,
    target_court_record.id,
    target_court_record.court_group_id,
    target_location_record.location_group_id,
    target_location_record.name,
    target_court_record.name,
    target_court_record.position,
    matches_table.sport_id,
    matches_table.naipe,
    matches_table.home_team_id,
    matches_table.away_team_id,
    GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1),
    public.combine_bracket_schedule_timestamp(
      target_date,
      COALESCE(
        ((matches_table.pending_manual_relocation_previous_schedule->>'start_time')::TIMESTAMPTZ AT TIME ZONE 'America/Sao_Paulo')::TIME,
        target_start_time,
        day_record.start_time
      )
    ),
    NULL,
    NULLIF(matches_table.pending_manual_relocation_previous_schedule->>'queue_position', '')::INTEGER,
    NULLIF(matches_table.pending_manual_relocation_previous_schedule->>'scheduled_slot', '')::INTEGER,
    row_number() OVER (
      ORDER BY
        NULLIF(matches_table.pending_manual_relocation_previous_schedule->>'start_time', '')::TIMESTAMPTZ,
        NULLIF(matches_table.pending_manual_relocation_previous_schedule->>'scheduled_slot', '')::INTEGER,
        NULLIF(matches_table.pending_manual_relocation_previous_schedule->>'queue_position', '')::INTEGER,
        matches_table.id
    )::INTEGER
  FROM public.matches AS matches_table
  JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.match_id = matches_table.id
    AND bracket_matches_table.bracket_edition_id = _bracket_edition_id
  LEFT JOIN public.championship_sports AS championship_sports_table
    ON championship_sports_table.championship_id = matches_table.championship_id
    AND championship_sports_table.sport_id = matches_table.sport_id
  LEFT JOIN public.teams AS home_teams_table ON home_teams_table.id = matches_table.home_team_id
  LEFT JOIN public.teams AS away_teams_table ON away_teams_table.id = matches_table.away_team_id
  WHERE matches_table.id = ANY(selected_match_ids);

  INSERT INTO day_schedule_reorganization_items (
    item_type, item_id, match_id, placeholder_id, label, is_selected, is_fixed, is_knockout,
    bracket_court_id, court_group_id, location_group_id, location_name, court_name, court_position,
    sport_id, naipe, home_team_id, away_team_id, duration_minutes, original_start_at,
    original_end_at, original_queue_position, original_scheduled_slot
  )
  SELECT
    'KNOCKOUT_PLACEHOLDER',
    bracket_matches_table.id,
    NULL,
    bracket_matches_table.id,
    format('A definir • %s', COALESCE(sports_table.name, 'Mata-mata')),
    false,
    false,
    true,
    courts_table.id,
    courts_table.court_group_id,
    locations_table.location_group_id,
    locations_table.name,
    courts_table.name,
    courts_table.position,
    competitions_table.sport_id,
    competitions_table.naipe,
    NULL,
    NULL,
    GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1),
    public.combine_bracket_schedule_timestamp(target_date, bracket_matches_table.planned_start_time),
    public.combine_bracket_schedule_timestamp(target_date, COALESCE(bracket_matches_table.planned_end_time, bracket_matches_table.planned_start_time + make_interval(mins => GREATEST(COALESCE(championship_sports_table.default_match_duration_minutes, 35), 1)))),
    bracket_matches_table.planned_queue_position,
    bracket_matches_table.planned_scheduled_slot
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
    ON championship_sports_table.championship_id = selected_championship_id
    AND championship_sports_table.sport_id = competitions_table.sport_id
  LEFT JOIN public.sports AS sports_table ON sports_table.id = competitions_table.sport_id
  WHERE competitions_table.bracket_edition_id = _bracket_edition_id
    AND bracket_matches_table.match_id IS NULL
    AND bracket_matches_table.is_bye = false
    AND bracket_matches_table.planned_scheduled_date = target_date
    AND locations_table.id = target_location_record.id
    AND bracket_matches_table.planned_start_time IS NOT NULL;

  UPDATE day_schedule_reorganization_items AS items_table
  SET manual_order_position = manual_order_items.position
  FROM jsonb_each(manual_court_item_order) AS court_order(court_name, item_ids)
  CROSS JOIN LATERAL jsonb_array_elements_text(court_order.item_ids) WITH ORDINALITY AS manual_order_items(item_id, position)
  WHERE items_table.court_name = court_order.court_name
    AND items_table.item_id::TEXT = manual_order_items.item_id;

  should_recalculate_target_court := COALESCE(cardinality(selected_match_ids), 0) > 0
    OR EXISTS (
      SELECT 1
      FROM day_schedule_reorganization_items
      WHERE manual_order_position IS NOT NULL
    );

  SELECT breaks_table.*
  INTO primary_break_record
  FROM public.championship_bracket_day_breaks AS breaks_table
  WHERE breaks_table.bracket_day_id = day_record.id
    AND (
      breaks_table.scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
      OR (
        breaks_table.scope_type = 'COURT'::public.bracket_day_break_scope_type
        AND breaks_table.bracket_court_id = target_court_record.id
      )
    )
  ORDER BY
    CASE WHEN breaks_table.scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type THEN 0 ELSE 1 END,
    breaks_table.position,
    breaks_table.break_start_time
  LIMIT 1;

  IF primary_break_record.id IS NOT NULL AND break_policy = 'KEEP_BEFORE_KNOCKOUT' THEN
    primary_break_duration := primary_break_record.break_end_time - primary_break_record.break_start_time;

    SELECT *
    INTO knockout_anchor_record
    FROM day_schedule_reorganization_items
    WHERE is_knockout
      AND (
        primary_break_record.scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
        OR bracket_court_id = primary_break_record.bracket_court_id
      )
      AND original_start_at >= public.combine_bracket_schedule_timestamp(target_date, primary_break_record.break_end_time)
    ORDER BY original_start_at, original_scheduled_slot, item_id
    LIMIT 1;

    IF knockout_anchor_record.item_id IS NULL THEN
      blockers := blockers || jsonb_build_array('Não há jogo de mata-mata após o intervalo para preservar sua posição.');
      next_break_start_at := public.combine_bracket_schedule_timestamp(target_date, primary_break_record.break_start_time);
      next_break_end_at := public.combine_bracket_schedule_timestamp(target_date, primary_break_record.break_end_time);
    ELSE
      next_break_end_at := knockout_anchor_record.original_start_at;
      next_break_start_at := next_break_end_at - primary_break_duration;
      UPDATE day_schedule_reorganization_items
      SET is_fixed = true
      WHERE item_id = knockout_anchor_record.item_id;
    END IF;
  ELSE
    next_break_start_at := NULL;
    next_break_end_at := NULL;
  END IF;

  previous_day_start := to_char(public.combine_bracket_schedule_timestamp(target_date, day_record.start_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI');
  previous_day_end := to_char(public.combine_bracket_schedule_timestamp(target_date, day_record.end_time) AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI');

  IF target_start_time IS NOT NULL AND target_start_time > day_record.start_time THEN
    RAISE EXCEPTION 'O novo horário de início do dia deve antecipar ou manter o início já configurado.';
  END IF;

  day_start_at := public.combine_bracket_schedule_timestamp(target_date, COALESCE(target_start_time, day_record.start_time));
  day_end_at := public.combine_bracket_schedule_timestamp(target_date, day_record.end_time);

  UPDATE day_schedule_reorganization_items
  SET
    planned_start_at = original_start_at,
    planned_end_at = original_end_at,
    planned_court_position = fixed_items.court_position
  FROM (
    SELECT
      item_id,
      row_number() OVER (
        PARTITION BY bracket_court_id
        ORDER BY original_start_at, item_id
      )::INTEGER AS court_position
    FROM day_schedule_reorganization_items
    WHERE is_fixed
  ) AS fixed_items
  WHERE fixed_items.item_id = day_schedule_reorganization_items.item_id;

  UPDATE day_schedule_reorganization_items
  SET
    planned_start_at = original_start_at,
    planned_end_at = original_end_at,
    planned_court_position = original_positions.court_position,
    planned_queue_position = original_queue_position,
    planned_scheduled_slot = original_scheduled_slot
  FROM (
    SELECT
      item_id,
      row_number() OVER (
        PARTITION BY bracket_court_id
        ORDER BY original_start_at, item_id
      )::INTEGER AS court_position
    FROM day_schedule_reorganization_items
    WHERE is_selected = false
  ) AS original_positions
  WHERE original_positions.item_id = day_schedule_reorganization_items.item_id;

  IF should_recalculate_target_court THEN
    UPDATE day_schedule_reorganization_items
    SET
      planned_start_at = NULL,
      planned_end_at = NULL,
      planned_court_position = NULL,
      planned_queue_position = NULL,
      planned_scheduled_slot = NULL
    WHERE is_fixed = false
      AND (
        (
          bracket_court_id = target_court_record.id
          AND COALESCE(cardinality(selected_match_ids), 0) > 0
        )
        OR manual_order_position IS NOT NULL
      );
  END IF;

  FOR item_record IN
    SELECT *
    FROM day_schedule_reorganization_items
    WHERE is_fixed = false
      AND should_recalculate_target_court
      AND (
        (
          bracket_court_id = target_court_record.id
          AND COALESCE(cardinality(selected_match_ids), 0) > 0
        )
        OR manual_order_position IS NOT NULL
      )
    ORDER BY
      CASE
        WHEN strategy = 'MANUAL' AND manual_order_position IS NOT NULL THEN 0
        WHEN strategy = 'START' AND is_selected THEN 0
        WHEN strategy = 'MANUAL' AND item_id = NULLIF(_payload->>'manual_anchor_item_id', '')::UUID THEN 0
        WHEN strategy = 'MANUAL' AND is_selected THEN 1
        WHEN strategy = 'MANUAL' AND is_knockout THEN 3
        WHEN strategy = 'MANUAL'
          AND original_start_at < (
            SELECT anchor_item.original_end_at
            FROM day_schedule_reorganization_items AS anchor_item
            WHERE anchor_item.item_id = NULLIF(_payload->>'manual_anchor_item_id', '')::UUID
          ) THEN 0
        WHEN strategy = 'MANUAL' THEN 2
        WHEN strategy = 'AUTO'
          AND bracket_court_id = target_court_record.id
          AND is_knockout
        THEN 3
        WHEN strategy = 'AUTO' AND is_selected THEN 1
        WHEN strategy = 'AUTO'
          AND bracket_court_id = target_court_record.id
        THEN 0
        WHEN strategy = 'AUTO'
          AND original_start_at < COALESCE((
            SELECT max(target_group_items.original_end_at)
            FROM day_schedule_reorganization_items AS target_group_items
            WHERE target_group_items.bracket_court_id = target_court_record.id
              AND target_group_items.is_selected = false
              AND target_group_items.is_knockout = false
          ), 'infinity'::TIMESTAMPTZ)
        THEN 0
        WHEN strategy = 'AUTO' THEN 2
        WHEN strategy = 'END' AND is_selected THEN 2
        ELSE 1
      END,
      CASE WHEN strategy = 'MANUAL' THEN manual_order_position ELSE NULL END NULLS LAST,
      CASE WHEN is_selected THEN selection_order ELSE NULL END NULLS LAST,
      original_start_at,
      original_scheduled_slot,
      original_queue_position,
      item_id
  LOOP
    current_candidate_start := GREATEST(
      day_start_at,
      COALESCE(
        CASE
          WHEN strategy = 'START' AND item_record.is_selected THEN
            day_start_at + COALESCE((
              SELECT sum(make_interval(mins => selected_items.duration_minutes))
              FROM day_schedule_reorganization_items AS selected_items
              WHERE selected_items.is_selected
                AND selected_items.selection_order < item_record.selection_order
            ), INTERVAL '0 minutes')
          WHEN strategy = 'AUTO' AND item_record.is_selected THEN
            COALESCE((
              SELECT max(existing_items.planned_end_at)
              FROM day_schedule_reorganization_items AS existing_items
              WHERE existing_items.bracket_court_id = item_record.bracket_court_id
                AND existing_items.is_selected = false
                AND existing_items.is_knockout = false
                AND existing_items.planned_end_at IS NOT NULL
                AND existing_items.original_start_at < COALESCE((
                  SELECT min(knockout_items.original_start_at)
                  FROM day_schedule_reorganization_items AS knockout_items
                  WHERE knockout_items.bracket_court_id = item_record.bracket_court_id
                    AND knockout_items.is_knockout
                ), 'infinity'::TIMESTAMPTZ)
            ), day_start_at) + COALESCE((
              SELECT sum(make_interval(mins => selected_items.duration_minutes))
              FROM day_schedule_reorganization_items AS selected_items
              WHERE selected_items.is_selected
                AND selected_items.selection_order < item_record.selection_order
            ), INTERVAL '0 minutes')
          WHEN strategy = 'MANUAL'
            AND item_record.is_selected
            AND item_record.manual_order_position IS NULL
          THEN
            COALESCE((
              SELECT anchor_item.planned_end_at
              FROM day_schedule_reorganization_items AS anchor_item
              WHERE anchor_item.item_id = NULLIF(_payload->>'manual_anchor_item_id', '')::UUID
            ), day_start_at) + COALESCE((
              SELECT sum(make_interval(mins => selected_items.duration_minutes))
              FROM day_schedule_reorganization_items AS selected_items
              WHERE selected_items.is_selected
                AND selected_items.selection_order < item_record.selection_order
            ), INTERVAL '0 minutes')
          WHEN strategy = 'END' AND item_record.is_selected THEN day_start_at
          WHEN strategy = 'AUTO'
            AND item_record.is_knockout
            AND item_record.bracket_court_id = target_court_record.id
          THEN GREATEST(
            item_record.original_start_at,
            COALESCE((
              SELECT max(selected_items.planned_end_at)
              FROM day_schedule_reorganization_items AS selected_items
              WHERE selected_items.is_selected
                AND selected_items.bracket_court_id = target_court_record.id
                AND selected_items.planned_end_at IS NOT NULL
            ), day_start_at)
          )
          ELSE COALESCE((
            SELECT max(previous_items.planned_end_at)
            FROM day_schedule_reorganization_items AS previous_items
            WHERE previous_items.bracket_court_id = item_record.bracket_court_id
              AND previous_items.planned_end_at IS NOT NULL
          ), day_start_at)
        END,
        day_start_at
      )
    );
    loop_count := 0;

    LOOP
      loop_count := loop_count + 1;
      IF loop_count > 200 THEN
        blockers := blockers || jsonb_build_array(format('Não foi possível encontrar horário elegível para %s.', item_record.label));
        EXIT;
      END IF;

      candidate_end := current_candidate_start + make_interval(mins => item_record.duration_minutes);

      SELECT max(planned_end_at)
      INTO conflicting_end
      FROM day_schedule_reorganization_items
      WHERE planned_start_at IS NOT NULL
        AND bracket_court_id = item_record.bracket_court_id
        AND current_candidate_start < planned_end_at
        AND candidate_end > planned_start_at;

      IF conflicting_end IS NOT NULL THEN
        current_candidate_start := conflicting_end;
        CONTINUE;
      END IF;

      SELECT max(
        public.combine_bracket_schedule_timestamp(
          target_date,
          (resource_lock.value->>'end_time')::TIME
        )
      )
      INTO conflicting_end
      FROM jsonb_array_elements(COALESCE(edition_payload->'resource_locks', '[]'::JSONB)) AS resource_lock(value)
      WHERE resource_lock.value->>'date' = target_date::TEXT
        AND resource_lock.value->>'location_key' = item_record.location_group_id::TEXT
        AND resource_lock.value->>'court_key' = item_record.court_group_id::TEXT
        AND NULLIF(resource_lock.value->>'start_time', '') IS NOT NULL
        AND NULLIF(resource_lock.value->>'end_time', '') IS NOT NULL
        AND NOT (
          break_policy = 'REMOVE'
          AND resource_lock.value->>'date' = _payload->'removable_resource_lock'->>'date'
          AND resource_lock.value->>'location_key' = _payload->'removable_resource_lock'->>'location_group_id'
          AND resource_lock.value->>'court_key' = _payload->'removable_resource_lock'->>'court_group_id'
          AND resource_lock.value->>'start_time' = _payload->'removable_resource_lock'->>'start_time'
          AND resource_lock.value->>'end_time' = _payload->'removable_resource_lock'->>'end_time'
          AND COALESCE(resource_lock.value->>'lock_mode', '') = 'HARD'
          AND NULLIF(resource_lock.value->>'sport_id', '') IS NULL
          AND NULLIF(resource_lock.value->>'naipe', '') IS NULL
          AND NULLIF(resource_lock.value->>'division', '') IS NULL
        )
        AND current_candidate_start < public.combine_bracket_schedule_timestamp(target_date, (resource_lock.value->>'end_time')::TIME)
        AND candidate_end > public.combine_bracket_schedule_timestamp(target_date, (resource_lock.value->>'start_time')::TIME);

      IF conflicting_end IS NOT NULL THEN
        current_candidate_start := conflicting_end;
        CONTINUE;
      END IF;

      SELECT max(public.combine_bracket_schedule_timestamp(target_date, breaks_table.break_end_time))
      INTO conflicting_end
      FROM public.championship_bracket_day_breaks AS breaks_table
      WHERE breaks_table.bracket_day_id = day_record.id
        AND (primary_break_record.id IS NULL OR breaks_table.id <> primary_break_record.id)
        AND (
          breaks_table.scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
          OR (breaks_table.scope_type = 'COURT'::public.bracket_day_break_scope_type AND breaks_table.bracket_court_id = item_record.bracket_court_id)
        )
        AND current_candidate_start < public.combine_bracket_schedule_timestamp(target_date, breaks_table.break_end_time)
        AND candidate_end > public.combine_bracket_schedule_timestamp(target_date, breaks_table.break_start_time);

      IF conflicting_end IS NOT NULL THEN
        current_candidate_start := conflicting_end;
        CONTINUE;
      END IF;

      IF next_break_start_at IS NOT NULL
        AND (
          primary_break_record.scope_type = 'ALL_COURTS'::public.bracket_day_break_scope_type
          OR item_record.bracket_court_id = primary_break_record.bracket_court_id
        )
        AND NOT (
          primary_break_record.scope_type = 'COURT'::public.bracket_day_break_scope_type
          AND item_record.is_selected
          AND (
            should_reposition_target_court_break
            OR current_candidate_start < public.combine_bracket_schedule_timestamp(target_date, primary_break_record.break_end_time)
          )
        )
        AND current_candidate_start < next_break_end_at
        AND candidate_end > next_break_start_at
      THEN
        current_candidate_start := next_break_end_at;
        CONTINUE;
      END IF;

      EXIT;
    END LOOP;

    SELECT count(*) + 1
    INTO candidate_court_position
    FROM day_schedule_reorganization_items
    WHERE planned_start_at IS NOT NULL
      AND bracket_court_id = item_record.bracket_court_id
      AND planned_start_at <= current_candidate_start;

    UPDATE day_schedule_reorganization_items
    SET
      planned_start_at = current_candidate_start,
      planned_end_at = current_candidate_start + make_interval(mins => item_record.duration_minutes),
      planned_court_position = candidate_court_position
    WHERE item_id = item_record.item_id;

    IF primary_break_record.id IS NOT NULL
      AND primary_break_record.scope_type = 'COURT'::public.bracket_day_break_scope_type
      AND item_record.is_selected
      AND (
        should_reposition_target_court_break
        OR current_candidate_start < public.combine_bracket_schedule_timestamp(target_date, primary_break_record.break_end_time)
      )
    THEN
      should_reposition_target_court_break := true;
      next_break_start_at := GREATEST(
        next_break_start_at,
        current_candidate_start + make_interval(mins => item_record.duration_minutes)
      );
      next_break_end_at := next_break_start_at + primary_break_duration;
    END IF;
  END LOOP;

  UPDATE day_schedule_reorganization_items AS items_table
  SET planned_queue_position = numbered_items.queue_position,
      planned_scheduled_slot = numbered_items.scheduled_slot
  FROM (
    SELECT
      item_id,
      row_number() OVER (
        PARTITION BY bracket_court_id
        ORDER BY planned_start_at, item_id
      )::INTEGER AS queue_position,
      row_number() OVER (
        ORDER BY planned_start_at, court_position, item_id
      )::INTEGER AS scheduled_slot
    FROM day_schedule_reorganization_items
    WHERE planned_start_at IS NOT NULL
  ) AS numbered_items
  WHERE numbered_items.item_id = items_table.item_id
    AND should_recalculate_target_court
    AND (
      (
        items_table.bracket_court_id = target_court_record.id
        AND COALESCE(cardinality(selected_match_ids), 0) > 0
      )
      OR items_table.manual_order_position IS NOT NULL
    );

  SELECT LEAST(day_start_at, COALESCE(min(planned_start_at), day_start_at)),
    GREATEST(day_end_at, COALESCE(max(planned_end_at), day_end_at), COALESCE(next_break_end_at, day_end_at))
  INTO next_day_start_at, next_day_end_at
  FROM day_schedule_reorganization_items;

  IF (next_day_end_at AT TIME ZONE 'America/Sao_Paulo')::DATE > target_date THEN
    blockers := blockers || jsonb_build_array('A reorganização ultrapassa meia-noite e deve ser dividida em outro dia configurado.');
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'item_type', item_type,
      'item_id', item_id,
      'match_id', match_id,
      'placeholder_id', placeholder_id,
      'label', label,
      'is_selected', is_selected,
      'before', jsonb_build_object(
        'scheduled_date', target_date,
        'location', location_name,
        'court_name', court_name,
        'start_time', original_start_at,
        'end_time', original_end_at,
        'queue_position', original_queue_position,
        'scheduled_slot', original_scheduled_slot
      ),
      'after', jsonb_build_object(
        'scheduled_date', target_date,
        'location', location_name,
        'court_name', court_name,
        'location_group_id', location_group_id,
        'court_group_id', court_group_id,
        'start_time', planned_start_at,
        'end_time', planned_end_at,
        'queue_position', planned_queue_position,
        'scheduled_slot', planned_scheduled_slot
      )
    )
    ORDER BY planned_start_at, court_position, item_id
  ), '[]'::JSONB)
  INTO changes
  FROM day_schedule_reorganization_items
  WHERE is_fixed = false
    AND (
      is_selected
      OR original_start_at IS DISTINCT FROM planned_start_at
      OR original_end_at IS DISTINCT FROM planned_end_at
      OR original_queue_position IS DISTINCT FROM planned_queue_position
      OR original_scheduled_slot IS DISTINCT FROM planned_scheduled_slot
    );

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'item_type', item_type,
      'item_id', item_id,
      'match_id', match_id,
      'placeholder_id', placeholder_id,
      'label', label,
      'status', CASE WHEN item_type = 'KNOCKOUT_PLACEHOLDER' THEN 'PLANNED' ELSE 'SCHEDULED' END,
      'start_time', planned_start_at,
      'end_time', planned_end_at,
      'location', location_name,
      'court_name', court_name,
      'is_relocated', is_selected,
      'is_fixed', is_fixed,
      'rest_conflicts', CASE WHEN EXISTS (
        SELECT 1
        FROM day_schedule_reorganization_items AS conflicting_items
        WHERE conflicting_items.item_id <> timeline_items.item_id
          AND conflicting_items.naipe = timeline_items.naipe
          AND conflicting_items.is_knockout = false
          AND (
            timeline_items.home_team_id = conflicting_items.home_team_id
            OR timeline_items.home_team_id = conflicting_items.away_team_id
            OR timeline_items.away_team_id = conflicting_items.home_team_id
            OR timeline_items.away_team_id = conflicting_items.away_team_id
          )
          AND timeline_items.is_knockout = false
          AND (
            CASE
              WHEN conflicting_items.bracket_court_id = timeline_items.bracket_court_id
              THEN abs(
                timeline_items.planned_court_position
                  - conflicting_items.planned_court_position
              ) < CASE
                WHEN timeline_items.sport_id = conflicting_items.sport_id THEN 3
                ELSE 2
              END
              ELSE abs(
                extract(epoch FROM (
                  conflicting_items.planned_start_at
                    - timeline_items.planned_start_at
                )) / 60.0
              ) < greatest(
                greatest(timeline_items.duration_minutes, 1),
                greatest(conflicting_items.duration_minutes, 1)
              ) * CASE
                WHEN timeline_items.sport_id = conflicting_items.sport_id THEN 3
                ELSE 2
              END
            END
          )
      ) THEN COALESCE((
        SELECT jsonb_agg(
          format(
            'Descanso insuficiente no naipe %s: conflito com %s na %s, %s–%s.',
            timeline_items.naipe,
            conflicting_items.label,
            conflicting_items.court_name,
            to_char(conflicting_items.planned_start_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
            to_char(conflicting_items.planned_end_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI')
          )
        )
        FROM day_schedule_reorganization_items AS conflicting_items
        WHERE conflicting_items.item_id <> timeline_items.item_id
          AND conflicting_items.naipe = timeline_items.naipe
          AND conflicting_items.is_knockout = false
          AND (
            timeline_items.home_team_id = conflicting_items.home_team_id
            OR timeline_items.home_team_id = conflicting_items.away_team_id
            OR timeline_items.away_team_id = conflicting_items.home_team_id
            OR timeline_items.away_team_id = conflicting_items.away_team_id
          )
          AND timeline_items.is_knockout = false
          AND (
            CASE
              WHEN conflicting_items.bracket_court_id = timeline_items.bracket_court_id
              THEN abs(
                timeline_items.planned_court_position
                  - conflicting_items.planned_court_position
              ) < CASE
                WHEN timeline_items.sport_id = conflicting_items.sport_id THEN 3
                ELSE 2
              END
              ELSE abs(
                extract(epoch FROM (
                  conflicting_items.planned_start_at
                    - timeline_items.planned_start_at
                )) / 60.0
              ) < greatest(
                greatest(timeline_items.duration_minutes, 1),
                greatest(conflicting_items.duration_minutes, 1)
              ) * CASE
                WHEN timeline_items.sport_id = conflicting_items.sport_id THEN 3
                ELSE 2
              END
            END
          )
      ), '[]'::JSONB) ELSE '[]'::JSONB END,
      'is_displaced', COALESCE(cardinality(selected_match_ids), 0) > 0 AND is_selected = false AND (
        original_start_at IS DISTINCT FROM planned_start_at
        OR original_end_at IS DISTINCT FROM planned_end_at
      )
    )
    ORDER BY planned_start_at, court_position, item_id
  ), '[]'::JSONB)
  INTO timeline
  FROM day_schedule_reorganization_items AS timeline_items;

  RETURN jsonb_build_object(
    'revision', revision_value,
    'blockers', blockers,
    'changes', changes,
    'timeline', timeline,
    'previous_day_start', previous_day_start,
    'next_day_start', to_char(next_day_start_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
    'advances_day_start', next_day_start_at < day_start_at,
    'previous_day_end', previous_day_end,
    'next_day_end', to_char(next_day_end_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
    'extends_day_end', next_day_end_at > day_end_at,
    'target_date', target_date,
    'target_location', target_location_record.name,
    'target_court_name', target_court_record.name,
    'insertion_position', CASE WHEN strategy = 'START' THEN 'START' WHEN strategy = 'END' THEN 'END' ELSE 'SLOT' END,
    'manual_anchor_item_id', CASE WHEN strategy = 'MANUAL' THEN NULLIF(_payload->>'manual_anchor_item_id', '') ELSE NULL END,
    'strategy', strategy,
    'reason', relocation_reason,
    'representation_warning', 'A representação e o descanso entre as duas quadras devem ser conferidos na timeline antes da confirmação.',
    'break', jsonb_build_object(
      'policy', break_policy,
      'before', jsonb_build_object(
        'id', primary_break_record.id,
        'start_time', CASE WHEN primary_break_record.id IS NULL THEN NULL ELSE to_char(primary_break_record.break_start_time, 'HH24:MI') END,
        'end_time', CASE WHEN primary_break_record.id IS NULL THEN NULL ELSE to_char(primary_break_record.break_end_time, 'HH24:MI') END
      ),
      'after', jsonb_build_object(
        'start_time', CASE WHEN next_break_start_at IS NULL THEN NULL ELSE to_char(next_break_start_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') END,
        'end_time', CASE WHEN next_break_end_at IS NULL THEN NULL ELSE to_char(next_break_end_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI') END
      )
    )
  );
END;
$function$;

-- Original: is_bracket_knockout_priority_court_match(_bracket_edition_id uuid, _priority_court_group_id uuid, _candidate_court_group_id uuid)
CREATE OR REPLACE FUNCTION public.is_bracket_knockout_priority_court_match(_bracket_edition_id uuid, _priority_court_group_id uuid, _candidate_court_group_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  priority_location_name TEXT;
  priority_court_name TEXT;
  candidate_location_name TEXT;
  candidate_court_name TEXT;
BEGIN
  IF _bracket_edition_id IS NULL
    OR _priority_court_group_id IS NULL
    OR _candidate_court_group_id IS NULL
  THEN
    RETURN FALSE;
  END IF;

  IF _priority_court_group_id = _candidate_court_group_id THEN
    RETURN TRUE;
  END IF;

  SELECT locations_table.name, courts_table.name
  INTO priority_location_name, priority_court_name
  FROM public.championship_bracket_days AS days_table
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.bracket_day_id = days_table.id
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND courts_table.court_group_id = _priority_court_group_id
  ORDER BY
    days_table.event_date ASC,
    locations_table.position ASC,
    courts_table.position ASC
  LIMIT 1;

  SELECT locations_table.name, courts_table.name
  INTO candidate_location_name, candidate_court_name
  FROM public.championship_bracket_days AS days_table
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.bracket_day_id = days_table.id
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND courts_table.court_group_id = _candidate_court_group_id
  ORDER BY
    days_table.event_date ASC,
    locations_table.position ASC,
    courts_table.position ASC
  LIMIT 1;

  IF priority_location_name IS NULL
    OR priority_court_name IS NULL
    OR candidate_location_name IS NULL
    OR candidate_court_name IS NULL
  THEN
    RETURN FALSE;
  END IF;

  RETURN public.normalize_bracket_entity_name(priority_location_name) =
      public.normalize_bracket_entity_name(candidate_location_name)
    AND public.normalize_bracket_entity_name(priority_court_name) =
      public.normalize_bracket_entity_name(candidate_court_name);
END;
$function$;

-- Original: preview_day_schedule_reorganization(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.preview_day_schedule_reorganization(_bracket_edition_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para reorganizar a programação.';
  END IF;

  RETURN public.build_day_schedule_reorganization_preview(_bracket_edition_id, _payload);
END;
$function$;

-- Original: redistribute_bracket_scheduled_matches(_bracket_edition_id uuid)
CREATE OR REPLACE FUNCTION public.redistribute_bracket_scheduled_matches(_bracket_edition_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  bracket_edition_record RECORD;
  day_court_record RECORD;
  slot_record RECORD;
  pending_match_record RECORD;
  slot_probe_at TIMESTAMPTZ;
  slot_start_at TIMESTAMPTZ;
  slot_end_at TIMESTAMPTZ;
  slot_sequence_index INTEGER;
  slot_last_naipe public.match_naipe;
  slot_last_division public.team_division;

  has_same_day_pending BOOLEAN;
  strict_group_pending BOOLEAN;
  slot_match_assigned BOOLEAN;

  strict_active_naipe public.match_naipe;
  strict_active_division public.team_division;
  strict_current_knockout_round INTEGER;
  strict_alternate_naipe_after_exclusive_knockout_phase BOOLEAN;
  strict_phase_naipes public.match_naipe[];
  strict_exclusive_knockout_naipe public.match_naipe;

  strict_completed_naipes public.match_naipe[];
  strict_completed_divisions public.team_division[];

  has_reserved_division_pending BOOLEAN;
  has_reserved_naipe_pending BOOLEAN;
  same_start_time_team_conflict BOOLEAN;
  same_court_same_naipe_rest_conflict BOOLEAN;
  same_court_different_naipe_rest_conflict BOOLEAN;
  cross_court_same_naipe_time_conflict BOOLEAN;
  cross_court_different_naipe_time_conflict BOOLEAN;
BEGIN
  SELECT
    championship_id,
    season_year,
    payload_snapshot
  INTO bracket_edition_record
  FROM public.championship_bracket_editions
  WHERE id = _bracket_edition_id
  LIMIT 1;

  IF bracket_edition_record.championship_id IS NULL THEN
    RAISE EXCEPTION 'Edição de chaveamento inválida.';
  END IF;

  DROP TABLE IF EXISTS temp_schedule_day_bounds;

  CREATE TEMP TABLE temp_schedule_day_bounds (
    event_date DATE PRIMARY KEY,
    day_start_at TIMESTAMPTZ NOT NULL,
    day_end_at TIMESTAMPTZ NOT NULL,
    day_start_time TIME NOT NULL,
    day_end_time TIME NOT NULL,
    break_start_time TIME NULL,
    break_end_time TIME NULL
  ) ON COMMIT DROP;

  INSERT INTO temp_schedule_day_bounds (
    event_date,
    day_start_at,
    day_end_at,
    day_start_time,
    day_end_time,
    break_start_time,
    break_end_time
  )
  SELECT
    days_table.event_date,
    public.combine_bracket_schedule_timestamp(
      days_table.event_date,
      days_table.start_time
    ),
    public.combine_bracket_schedule_timestamp(
      days_table.event_date,
      days_table.end_time
    ),
    days_table.start_time,
    days_table.end_time,
    days_table.break_start_time,
    days_table.break_end_time
  FROM public.championship_bracket_days AS days_table
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND days_table.start_time IS NOT NULL
    AND days_table.end_time IS NOT NULL
    AND days_table.end_time > days_table.start_time;

  DROP TABLE IF EXISTS temp_competition_date_availability_modes;

  CREATE TEMP TABLE temp_competition_date_availability_modes (
    competition_key TEXT NOT NULL,
    event_date DATE NOT NULL,
    mode TEXT NOT NULL,
    PRIMARY KEY (
      competition_key,
      event_date
    )
  ) ON COMMIT DROP;

  INSERT INTO temp_competition_date_availability_modes (
    competition_key,
    event_date,
    mode
  )
  SELECT DISTINCT ON (
    explicit_modes.competition_key,
    explicit_modes.event_date
  )
    explicit_modes.competition_key,
    explicit_modes.event_date,
    explicit_modes.mode
  FROM (
    SELECT
      COALESCE(
        availability_item.value ->> 'competition_key',
        ''
      ) AS competition_key,
      NULLIF(
        availability_item.value ->> 'date',
        ''
      )::date AS event_date,
      COALESCE(
        availability_item.value ->> 'mode',
        'FULL_DAY'
      ) AS mode,
      availability_item.ordinality
    FROM jsonb_array_elements(
      COALESCE(
        bracket_edition_record.payload_snapshot
          -> 'competition_date_availability',
        '[]'::jsonb
      )
    )
    WITH ORDINALITY AS availability_item(
      value,
      ordinality
    )
  ) AS explicit_modes
  WHERE explicit_modes.competition_key <> ''
    AND explicit_modes.event_date IS NOT NULL
  ORDER BY
    explicit_modes.competition_key ASC,
    explicit_modes.event_date ASC,
    explicit_modes.ordinality DESC;

  DROP TABLE IF EXISTS temp_competition_date_availability_windows;

  CREATE TEMP TABLE temp_competition_date_availability_windows (
    competition_key TEXT NOT NULL,
    event_date DATE NOT NULL,
    window_start_at TIMESTAMPTZ NOT NULL,
    window_end_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (
      competition_key,
      event_date,
      window_start_at,
      window_end_at
    )
  ) ON COMMIT DROP;

  INSERT INTO temp_competition_date_availability_windows (
    competition_key,
    event_date,
    window_start_at,
    window_end_at
  )
  SELECT
    explicit_modes.competition_key,
    explicit_modes.event_date,
    CASE
      WHEN explicit_modes.mode = 'FULL_DAY'
      THEN day_bounds_table.day_start_at
      ELSE explicit_windows.window_start_at
    END,
    CASE
      WHEN explicit_modes.mode = 'FULL_DAY'
      THEN day_bounds_table.day_end_at
      ELSE explicit_windows.window_end_at
    END
  FROM (
    SELECT DISTINCT ON (
      raw_modes.competition_key,
      raw_modes.event_date
    )
      raw_modes.competition_key,
      raw_modes.event_date,
      raw_modes.mode,
      raw_modes.availability_record
    FROM (
      SELECT
        COALESCE(
          availability_item.value ->> 'competition_key',
          ''
        ) AS competition_key,
        NULLIF(
          availability_item.value ->> 'date',
          ''
        )::date AS event_date,
        COALESCE(
          availability_item.value ->> 'mode',
          'FULL_DAY'
        ) AS mode,
        availability_item.value AS availability_record,
        availability_item.ordinality
      FROM jsonb_array_elements(
        COALESCE(
          bracket_edition_record.payload_snapshot
            -> 'competition_date_availability',
          '[]'::jsonb
        )
      )
      WITH ORDINALITY AS availability_item(
        value,
        ordinality
      )
    ) AS raw_modes
    WHERE raw_modes.competition_key <> ''
      AND raw_modes.event_date IS NOT NULL
    ORDER BY
      raw_modes.competition_key ASC,
      raw_modes.event_date ASC,
      raw_modes.ordinality DESC
  ) AS explicit_modes
  JOIN temp_schedule_day_bounds AS day_bounds_table
    ON day_bounds_table.event_date = explicit_modes.event_date
  LEFT JOIN LATERAL (
    SELECT
      public.combine_bracket_schedule_timestamp(
        explicit_modes.event_date,
        NULLIF(
          window_item.value ->> 'start_time',
          ''
        )::time
      ) AS window_start_at,
      public.combine_bracket_schedule_timestamp(
        explicit_modes.event_date,
        NULLIF(
          window_item.value ->> 'end_time',
          ''
        )::time
      ) AS window_end_at
    FROM jsonb_array_elements(
      COALESCE(
        explicit_modes.availability_record -> 'windows',
        '[]'::jsonb
      )
    ) AS window_item(value)
    WHERE NULLIF(
        window_item.value ->> 'start_time',
        ''
      ) IS NOT NULL
      AND NULLIF(
        window_item.value ->> 'end_time',
        ''
      ) IS NOT NULL
  ) AS explicit_windows
    ON explicit_modes.mode = 'CUSTOM'
  WHERE explicit_modes.mode = 'FULL_DAY'
    OR (
      explicit_modes.mode = 'CUSTOM'
      AND explicit_windows.window_end_at >
        explicit_windows.window_start_at
      AND explicit_windows.window_start_at >=
        day_bounds_table.day_start_at
      AND explicit_windows.window_end_at <=
        day_bounds_table.day_end_at
    );

  DROP TABLE IF EXISTS temp_team_competition_date_availability_modes;

  CREATE TEMP TABLE temp_team_competition_date_availability_modes (
    team_id UUID NOT NULL,
    competition_key TEXT NOT NULL,
    event_date DATE NOT NULL,
    mode TEXT NOT NULL,
    PRIMARY KEY (
      team_id,
      competition_key,
      event_date
    )
  ) ON COMMIT DROP;

  INSERT INTO temp_team_competition_date_availability_modes (
    team_id,
    competition_key,
    event_date,
    mode
  )
  SELECT DISTINCT ON (
    explicit_modes.team_id,
    explicit_modes.competition_key,
    explicit_modes.event_date
  )
    explicit_modes.team_id,
    explicit_modes.competition_key,
    explicit_modes.event_date,
    explicit_modes.mode
  FROM (
    SELECT
      NULLIF(
        availability_item.value ->> 'team_id',
        ''
      )::uuid AS team_id,
      COALESCE(
        availability_item.value ->> 'competition_key',
        ''
      ) AS competition_key,
      NULLIF(
        availability_item.value ->> 'date',
        ''
      )::date AS event_date,
      COALESCE(
        availability_item.value ->> 'mode',
        'FULL_DAY'
      ) AS mode,
      availability_item.ordinality
    FROM jsonb_array_elements(
      COALESCE(
        bracket_edition_record.payload_snapshot
          -> 'team_competition_date_availability',
        '[]'::jsonb
      )
    )
    WITH ORDINALITY AS availability_item(
      value,
      ordinality
    )
  ) AS explicit_modes
  WHERE explicit_modes.team_id IS NOT NULL
    AND explicit_modes.competition_key <> ''
    AND explicit_modes.event_date IS NOT NULL
  ORDER BY
    explicit_modes.team_id ASC,
    explicit_modes.competition_key ASC,
    explicit_modes.event_date ASC,
    explicit_modes.ordinality DESC;

  DROP TABLE IF EXISTS temp_team_competition_date_availability_windows;

  CREATE TEMP TABLE temp_team_competition_date_availability_windows (
    team_id UUID NOT NULL,
    competition_key TEXT NOT NULL,
    event_date DATE NOT NULL,
    window_start_at TIMESTAMPTZ NOT NULL,
    window_end_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (
      team_id,
      competition_key,
      event_date,
      window_start_at,
      window_end_at
    )
  ) ON COMMIT DROP;

  INSERT INTO temp_team_competition_date_availability_windows (
    team_id,
    competition_key,
    event_date,
    window_start_at,
    window_end_at
  )
  SELECT
    explicit_modes.team_id,
    explicit_modes.competition_key,
    explicit_modes.event_date,
    CASE
      WHEN explicit_modes.mode = 'FULL_DAY'
      THEN day_bounds_table.day_start_at
      ELSE explicit_windows.window_start_at
    END,
    CASE
      WHEN explicit_modes.mode = 'FULL_DAY'
      THEN day_bounds_table.day_end_at
      ELSE explicit_windows.window_end_at
    END
  FROM (
    SELECT DISTINCT ON (
      raw_modes.team_id,
      raw_modes.competition_key,
      raw_modes.event_date
    )
      raw_modes.team_id,
      raw_modes.competition_key,
      raw_modes.event_date,
      raw_modes.mode,
      raw_modes.availability_record
    FROM (
      SELECT
        NULLIF(
          availability_item.value ->> 'team_id',
          ''
        )::uuid AS team_id,
        COALESCE(
          availability_item.value ->> 'competition_key',
          ''
        ) AS competition_key,
        NULLIF(
          availability_item.value ->> 'date',
          ''
        )::date AS event_date,
        COALESCE(
          availability_item.value ->> 'mode',
          'FULL_DAY'
        ) AS mode,
        availability_item.value AS availability_record,
        availability_item.ordinality
      FROM jsonb_array_elements(
        COALESCE(
          bracket_edition_record.payload_snapshot
            -> 'team_competition_date_availability',
          '[]'::jsonb
        )
      )
      WITH ORDINALITY AS availability_item(
        value,
        ordinality
      )
    ) AS raw_modes
    WHERE raw_modes.team_id IS NOT NULL
      AND raw_modes.competition_key <> ''
      AND raw_modes.event_date IS NOT NULL
    ORDER BY
      raw_modes.team_id ASC,
      raw_modes.competition_key ASC,
      raw_modes.event_date ASC,
      raw_modes.ordinality DESC
  ) AS explicit_modes
  JOIN temp_schedule_day_bounds AS day_bounds_table
    ON day_bounds_table.event_date = explicit_modes.event_date
  LEFT JOIN LATERAL (
    SELECT
      public.combine_bracket_schedule_timestamp(
        explicit_modes.event_date,
        NULLIF(
          window_item.value ->> 'start_time',
          ''
        )::time
      ) AS window_start_at,
      public.combine_bracket_schedule_timestamp(
        explicit_modes.event_date,
        NULLIF(
          window_item.value ->> 'end_time',
          ''
        )::time
      ) AS window_end_at
    FROM jsonb_array_elements(
      COALESCE(
        explicit_modes.availability_record -> 'windows',
        '[]'::jsonb
      )
    ) AS window_item(value)
    WHERE NULLIF(
        window_item.value ->> 'start_time',
        ''
      ) IS NOT NULL
      AND NULLIF(
        window_item.value ->> 'end_time',
        ''
      ) IS NOT NULL
  ) AS explicit_windows
    ON explicit_modes.mode = 'CUSTOM'
  WHERE explicit_modes.mode = 'FULL_DAY'
    OR (
      explicit_modes.mode = 'CUSTOM'
      AND explicit_windows.window_end_at >
        explicit_windows.window_start_at
      AND explicit_windows.window_start_at >=
        day_bounds_table.day_start_at
      AND explicit_windows.window_end_at <=
        day_bounds_table.day_end_at
    );

  DROP TABLE IF EXISTS tmp_payload_explicit_target_courts;

  CREATE TEMP TABLE
    tmp_payload_explicit_target_courts (
      event_date DATE NOT NULL,
      court_group_id TEXT NOT NULL,
      PRIMARY KEY (
        event_date,
        court_group_id
      )
    )
  ON COMMIT DROP;

  INSERT INTO
    tmp_payload_explicit_target_courts (
      event_date,
      court_group_id
    )
  SELECT DISTINCT
    NULLIF(
      schedule_day_record.value ->> 'date',
      ''
    )::date,

    COALESCE(
      court_record.value ->> 'court_key',
      ''
    )

  FROM jsonb_array_elements(
    COALESCE(
      bracket_edition_record.payload_snapshot
        -> 'schedule_days',
      '[]'::jsonb
    )
  ) AS schedule_day_record(value)

  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(
      schedule_day_record.value -> 'locations',
      '[]'::jsonb
    )
  ) AS location_record(value)

  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(
      location_record.value -> 'courts',
      '[]'::jsonb
    )
  ) AS court_record(value)

  WHERE jsonb_typeof(
      court_record.value -> 'sport_match_targets'
    ) = 'array'

    AND NULLIF(
      schedule_day_record.value ->> 'date',
      ''
    ) IS NOT NULL

    AND COALESCE(
      court_record.value ->> 'court_key',
      ''
    ) <> '';


  DROP TABLE IF EXISTS
    tmp_payload_court_match_targets;

  CREATE TEMP TABLE
    tmp_payload_court_match_targets (
      event_date DATE NOT NULL,
      court_group_id TEXT NOT NULL,
      sport_id UUID NOT NULL,
      planned_match_count INTEGER NOT NULL,
      PRIMARY KEY (
        event_date,
        court_group_id,
        sport_id
      )
    )
  ON COMMIT DROP;

  INSERT INTO
    tmp_payload_court_match_targets (
      event_date,
      court_group_id,
      sport_id,
      planned_match_count
    )
  SELECT
    NULLIF(
      schedule_day_record.value ->> 'date',
      ''
    )::date,

    COALESCE(
      court_record.value ->> 'court_key',
      ''
    ),

    NULLIF(
      target_record.value ->> 'sport_id',
      ''
    )::uuid,

    (
      target_record.value ->> 'planned_match_count'
    )::integer

  FROM jsonb_array_elements(
    COALESCE(
      bracket_edition_record.payload_snapshot
        -> 'schedule_days',
      '[]'::jsonb
    )
  ) AS schedule_day_record(value)

  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(
      schedule_day_record.value -> 'locations',
      '[]'::jsonb
    )
  ) AS location_record(value)

  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(
      location_record.value -> 'courts',
      '[]'::jsonb
    )
  ) AS court_record(value)

  CROSS JOIN LATERAL jsonb_array_elements(
    COALESCE(
      court_record.value -> 'sport_match_targets',
      '[]'::jsonb
    )
  ) AS target_record(value)

  WHERE NULLIF(
      schedule_day_record.value ->> 'date',
      ''
    ) IS NOT NULL

    AND COALESCE(
      court_record.value ->> 'court_key',
      ''
    ) <> ''

    AND NULLIF(
      target_record.value ->> 'sport_id',
      ''
    ) IS NOT NULL

    AND COALESCE(
      target_record.value ->> 'planned_match_count',
      ''
    ) ~ '^[0-9]+$'

    AND (
      target_record.value ->> 'planned_match_count'
    )::integer > 0;


  DROP TABLE IF EXISTS tmp_global_day_courts;
  CREATE TEMP TABLE tmp_global_day_courts (
    bracket_day_id UUID NOT NULL,
    event_date DATE NOT NULL,
    sport_id UUID NOT NULL,
    duration_minutes INTEGER NOT NULL,
    location_id UUID NOT NULL,
    location_group_id UUID NOT NULL,
    location_name TEXT NOT NULL,
    location_position INTEGER NOT NULL,
    court_id UUID NOT NULL,
    court_group_id UUID NOT NULL,
    court_name TEXT NOT NULL,
    court_position INTEGER NOT NULL,
    is_primary_sport BOOLEAN NOT NULL,

    priority_mode
      public.bracket_court_priority_mode
      NOT NULL,

    sequence_mode
      public.bracket_court_sequence_mode
      NOT NULL,

    primary_naipe public.match_naipe NULL,
    primary_division public.team_division NULL,

    active_sequence_naipe
      public.match_naipe NULL,

    active_sequence_division
      public.team_division NULL,

    completed_sequence_naipes
      public.match_naipe[]
      NOT NULL
      DEFAULT ARRAY[]::public.match_naipe[],

    completed_sequence_divisions
      public.team_division[]
      NOT NULL
      DEFAULT ARRAY[]::public.team_division[],

    planned_match_count INTEGER NULL,

    next_available_at TIMESTAMPTZ NOT NULL,
    assigned_count INTEGER NOT NULL DEFAULT 0,
    last_naipe public.match_naipe NULL,
    last_division public.team_division NULL,

    PRIMARY KEY (
      court_id,
      sport_id,
      bracket_day_id
    )
  ) ON COMMIT DROP;

  INSERT INTO tmp_global_day_courts (
    bracket_day_id,
    event_date,
    sport_id,
    duration_minutes,
    location_id,
    location_group_id,
    location_name,
    location_position,
    court_id,
    court_group_id,
    court_name,
    court_position,
    is_primary_sport,
    priority_mode,
    sequence_mode,
    primary_naipe,
    primary_division,
    active_sequence_naipe,
    active_sequence_division,
    planned_match_count,
    next_available_at
  )
  SELECT
    days_table.id,
    days_table.event_date,
    court_sports_table.sport_id,
    GREATEST(championship_sports_table.default_match_duration_minutes, 1),
    locations_table.id,
    locations_table.location_group_id,
    locations_table.name,
    locations_table.position,
    courts_table.id,
    courts_table.court_group_id,
    courts_table.name,
    courts_table.position,
    (
      courts_table.preferred_sport_id IS NOT NULL
      AND courts_table.preferred_sport_id =
        court_sports_table.sport_id
    ) AS is_primary_sport,
    CASE
      WHEN court_sports_table.sequence_mode =
        'FLEXIBLE'::public.bracket_court_sequence_mode
      THEN COALESCE(
        location_priorities_table.priority_mode,
        'NONE'::public.bracket_court_priority_mode
      )
      ELSE
        'NONE'::public.bracket_court_priority_mode
    END,

    court_sports_table.sequence_mode,
    court_sports_table.preferred_naipe,
    court_sports_table.preferred_division,

    CASE
      WHEN court_sports_table.sequence_mode IN (
        'GROUP_NAIPE'
          ::public.bracket_court_sequence_mode,
        'ALTERNATE_NAIPE'
          ::public.bracket_court_sequence_mode
      )
      THEN court_sports_table.preferred_naipe
      ELSE NULL
    END,

    CASE
      WHEN court_sports_table.sequence_mode =
        'GROUP_DIVISION'
          ::public.bracket_court_sequence_mode
      THEN court_sports_table.preferred_division
      ELSE NULL
    END,

    court_match_targets_table.planned_match_count,

    public.combine_bracket_schedule_timestamp(
      days_table.event_date,
      days_table.start_time
    )
  FROM public.championship_bracket_days AS days_table
  JOIN public.championship_bracket_locations AS locations_table
    ON locations_table.bracket_day_id = days_table.id
  JOIN public.championship_bracket_courts AS courts_table
    ON courts_table.bracket_location_id = locations_table.id
  JOIN public.championship_bracket_court_sports AS court_sports_table
    ON court_sports_table.bracket_court_id = courts_table.id
  JOIN public.championship_sports AS championship_sports_table
    ON championship_sports_table.championship_id = bracket_edition_record.championship_id
    AND championship_sports_table.sport_id = court_sports_table.sport_id
  LEFT JOIN public.championship_bracket_location_sport_priorities AS location_priorities_table
    ON location_priorities_table.bracket_edition_id = days_table.bracket_edition_id
    AND location_priorities_table.location_group_id = locations_table.location_group_id
    AND location_priorities_table.sport_id = court_sports_table.sport_id
  LEFT JOIN tmp_payload_explicit_target_courts AS explicit_target_courts_table
    ON explicit_target_courts_table.event_date = days_table.event_date
    AND explicit_target_courts_table.court_group_id = courts_table.court_group_id::text
  LEFT JOIN tmp_payload_court_match_targets AS court_match_targets_table
    ON court_match_targets_table.event_date = days_table.event_date
    AND court_match_targets_table.court_group_id = courts_table.court_group_id::text
    AND court_match_targets_table.sport_id = court_sports_table.sport_id
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND (
      explicit_target_courts_table.court_group_id IS NULL
      OR court_match_targets_table.sport_id IS NOT NULL
    );

  DROP TABLE IF EXISTS
    tmp_global_manual_final_matches;

  CREATE TEMP TABLE
    tmp_global_manual_final_matches (
      match_id UUID PRIMARY KEY,
      event_date DATE NOT NULL,
      location_name TEXT NOT NULL,
      court_name TEXT NOT NULL,
      start_time TIMESTAMPTZ NOT NULL,
      end_time TIMESTAMPTZ NOT NULL
    )
  ON COMMIT DROP;

  INSERT INTO
    tmp_global_manual_final_matches (
      match_id,
      event_date,
      location_name,
      court_name,
      start_time,
      end_time
    )
  SELECT
    matches_table.id,
    matches_table.scheduled_date,
    matches_table.location,
    matches_table.court_name,

    COALESCE(
      matches_table.start_time,

      public.combine_bracket_schedule_timestamp(
        matches_table.scheduled_date,
        bracket_matches_table.planned_start_time
      )
    ),

    COALESCE(
      matches_table.end_time,

      public.combine_bracket_schedule_timestamp(
        matches_table.scheduled_date,
        bracket_matches_table.planned_end_time
      )
    )

  FROM public.matches AS matches_table

  JOIN public.championship_bracket_matches
    AS bracket_matches_table
    ON bracket_matches_table.match_id =
      matches_table.id

  WHERE bracket_matches_table.bracket_edition_id =
      _bracket_edition_id

    AND matches_table.status =
      'SCHEDULED'::public.match_status
    AND COALESCE(matches_table.is_pending_manual_relocation, false) = false

    AND bracket_matches_table.phase =
      'KNOCKOUT'::public.bracket_phase

    AND bracket_matches_table.is_third_place =
      false

    AND bracket_matches_table.planned_period
      IS NOT NULL

    AND bracket_matches_table
      .planned_court_group_id IS NOT NULL

    AND bracket_matches_table
      .planned_start_time IS NOT NULL

    AND bracket_matches_table
      .planned_end_time IS NOT NULL

    AND matches_table.scheduled_date
      IS NOT NULL

    AND NULLIF(
      trim(COALESCE(matches_table.location, '')),
      ''
    ) IS NOT NULL

    AND NULLIF(
      trim(COALESCE(matches_table.court_name, '')),
      ''
    ) IS NOT NULL;


  /*
   * manual_final_payload_reservation
   *
   * Durante a geração inicial ainda não existem partidas reais das
   * finais.
   *
   * Mesmo assim os blocos configurados na Etapa 11 precisam reservar
   * seus intervalos antes que os jogos de grupos sejam redistribuídos.
   *
   * get_championship_knockout_final_program_schedule() resolve:
   *
   * - data;
   * - período;
   * - local;
   * - quadra;
   * - sequência dos naipes;
   * - duração padrão ou duração especial;
   * - conflitos entre os próprios blocos manuais.
   *
   * O UUID abaixo existe apenas dentro da tabela temporária.
   */
  INSERT INTO
    tmp_global_manual_final_matches (
      match_id,
      event_date,
      location_name,
      court_name,
      start_time,
      end_time
    )
  SELECT
    gen_random_uuid(),

    final_schedule.scheduled_date,

    final_schedule.location_name,
    final_schedule.court_name,

    final_schedule.planned_start_at,
    final_schedule.planned_end_at

  FROM
    public.get_championship_knockout_final_program_schedule(
      _bracket_edition_id
    ) AS final_schedule

  WHERE final_schedule.planned_start_at
      IS NOT NULL

    AND final_schedule.planned_end_at
      IS NOT NULL

    /*
     * Quando uma final já tiver sido materializada como partida real,
     * ela já estará presente na primeira carga da tabela temporária.
     *
     * Não duplicamos a ocupação.
     */
    AND NOT EXISTS (
      SELECT 1

      FROM tmp_global_manual_final_matches
        AS existing_manual_final

      WHERE existing_manual_final.event_date =
          final_schedule.scheduled_date

        AND public.normalize_bracket_entity_name(
          existing_manual_final.location_name
        ) =
          public.normalize_bracket_entity_name(
            final_schedule.location_name
          )

        AND public.normalize_bracket_entity_name(
          existing_manual_final.court_name
        ) =
          public.normalize_bracket_entity_name(
            final_schedule.court_name
          )

        AND existing_manual_final.start_time =
          final_schedule.planned_start_at

        AND existing_manual_final.end_time =
          final_schedule.planned_end_at
    );


  DROP TABLE IF EXISTS tmp_global_locked_matches;
  CREATE TEMP TABLE tmp_global_locked_matches (
    match_id UUID PRIMARY KEY,
    event_date DATE NOT NULL,
    sport_id UUID NOT NULL,
    naipe public.match_naipe NOT NULL,
    division public.team_division NULL,
    location_name TEXT NOT NULL,
    court_name TEXT NOT NULL,
    start_time TIMESTAMPTZ NULL,
    end_time TIMESTAMPTZ NULL
  ) ON COMMIT DROP;

  INSERT INTO tmp_global_locked_matches (
    match_id,
    event_date,
    sport_id,
    naipe,
    division,
    location_name,
    court_name,
    start_time,
    end_time
  )
  SELECT
    matches_table.id,
    matches_table.scheduled_date,
    matches_table.sport_id,
    matches_table.naipe,
    matches_table.division,
    matches_table.location,
    matches_table.court_name,
    matches_table.start_time,
    matches_table.end_time
  FROM public.matches AS matches_table
  JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.match_id = matches_table.id
  WHERE bracket_matches_table.bracket_edition_id = _bracket_edition_id
    AND matches_table.status <> 'SCHEDULED'::public.match_status
    AND matches_table.scheduled_date IS NOT NULL
    AND NULLIF(trim(COALESCE(matches_table.location, '')), '') IS NOT NULL
    AND NULLIF(trim(COALESCE(matches_table.court_name, '')), '') IS NOT NULL;

  WITH locked_match_availability AS (
    SELECT
      day_courts_table.bracket_day_id,
      day_courts_table.sport_id,
      day_courts_table.court_id,
      MAX(
        COALESCE(
          locked_matches_table.end_time,
          CASE
            WHEN locked_matches_table.start_time IS NOT NULL THEN
              locked_matches_table.start_time + make_interval(mins => day_courts_table.duration_minutes)
            ELSE NULL
          END,
          day_courts_table.next_available_at
        )
      ) AS next_available_at
    FROM tmp_global_day_courts AS day_courts_table
    JOIN tmp_global_locked_matches AS locked_matches_table
      ON locked_matches_table.event_date = day_courts_table.event_date
      AND locked_matches_table.sport_id = day_courts_table.sport_id
      AND public.normalize_bracket_entity_name(locked_matches_table.location_name) = public.normalize_bracket_entity_name(day_courts_table.location_name)
      AND public.normalize_bracket_entity_name(locked_matches_table.court_name) = public.normalize_bracket_entity_name(day_courts_table.court_name)
    GROUP BY
      day_courts_table.bracket_day_id,
      day_courts_table.sport_id,
      day_courts_table.court_id
  ),
  locked_match_last_context AS (
    SELECT DISTINCT ON (
      day_courts_table.bracket_day_id,
      day_courts_table.sport_id,
      day_courts_table.court_id
    )
      day_courts_table.bracket_day_id,
      day_courts_table.sport_id,
      day_courts_table.court_id,
      locked_matches_table.naipe,
      locked_matches_table.division
    FROM tmp_global_day_courts AS day_courts_table
    JOIN tmp_global_locked_matches AS locked_matches_table
      ON locked_matches_table.event_date = day_courts_table.event_date
      AND locked_matches_table.sport_id = day_courts_table.sport_id
      AND public.normalize_bracket_entity_name(locked_matches_table.location_name) = public.normalize_bracket_entity_name(day_courts_table.location_name)
      AND public.normalize_bracket_entity_name(locked_matches_table.court_name) = public.normalize_bracket_entity_name(day_courts_table.court_name)
    ORDER BY
      day_courts_table.bracket_day_id,
      day_courts_table.sport_id,
      day_courts_table.court_id,
      COALESCE(
        locked_matches_table.end_time,
        CASE
          WHEN locked_matches_table.start_time IS NOT NULL THEN
            locked_matches_table.start_time + make_interval(mins => day_courts_table.duration_minutes)
          ELSE NULL
        END,
        day_courts_table.next_available_at
      ) DESC,
      COALESCE(locked_matches_table.start_time, locked_matches_table.end_time, day_courts_table.next_available_at) DESC,
      locked_matches_table.match_id DESC
  )
  UPDATE tmp_global_day_courts AS day_courts_table
  SET
    next_available_at = GREATEST(day_courts_table.next_available_at, locked_match_availability.next_available_at),
    last_naipe = locked_match_last_context.naipe,
    last_division = locked_match_last_context.division
  FROM locked_match_availability
  LEFT JOIN locked_match_last_context
    ON locked_match_last_context.bracket_day_id = locked_match_availability.bracket_day_id
    AND locked_match_last_context.sport_id = locked_match_availability.sport_id
    AND locked_match_last_context.court_id = locked_match_availability.court_id
  WHERE day_courts_table.bracket_day_id = locked_match_availability.bracket_day_id
    AND day_courts_table.sport_id = locked_match_availability.sport_id
    AND day_courts_table.court_id = locked_match_availability.court_id;

  DROP TABLE IF EXISTS tmp_global_pending_matches;
  CREATE TEMP TABLE tmp_global_pending_matches (
    order_index BIGINT PRIMARY KEY,
    match_id UUID NOT NULL,
    original_scheduled_date DATE NULL,
    sport_id UUID NOT NULL,
    naipe public.match_naipe NOT NULL,
    division public.team_division NULL,
    home_team_id UUID NOT NULL,
    away_team_id UUID NOT NULL,
    duration_minutes INTEGER NOT NULL,
    group_id UUID NULL,
    created_at TIMESTAMPTZ NOT NULL,
    is_knockout BOOLEAN NOT NULL,
    knockout_round_number INTEGER NULL,
    preferred_knockout_court_group_id UUID NULL
  ) ON COMMIT DROP;

  INSERT INTO tmp_global_pending_matches (
    order_index,
    match_id,
    original_scheduled_date,
    sport_id,
    naipe,
    division,
    home_team_id,
    away_team_id,
    duration_minutes,
    group_id,
    created_at,
    is_knockout,
    knockout_round_number,
    preferred_knockout_court_group_id
  )
  SELECT
    ROW_NUMBER() OVER (
      ORDER BY
        matches_table.scheduled_date ASC NULLS FIRST,
        COALESCE(matches_table.start_time, public.combine_bracket_schedule_timestamp(matches_table.scheduled_date, time '23:59')) ASC NULLS LAST,
        COALESCE(matches_table.scheduled_slot, matches_table.queue_position) ASC NULLS LAST,
        COALESCE(matches_table.queue_position, matches_table.scheduled_slot) ASC NULLS LAST,
        matches_table.created_at ASC,
        matches_table.id ASC
    ) AS order_index,
    matches_table.id,
    matches_table.scheduled_date,
    matches_table.sport_id,
    matches_table.naipe,
    matches_table.division,
    matches_table.home_team_id,
    matches_table.away_team_id,
    GREATEST(championship_sports_table.default_match_duration_minutes, 1),
    bracket_matches_table.group_id,
    matches_table.created_at,
    (
      bracket_matches_table.id IS NOT NULL
      AND bracket_matches_table.group_id IS NULL
    ) AS is_knockout,
    CASE
      WHEN bracket_matches_table.id IS NOT NULL
        AND bracket_matches_table.group_id IS NULL
      THEN bracket_matches_table.round_number
      ELSE NULL
    END AS knockout_round_number,
    CASE
      WHEN bracket_matches_table.id IS NULL
        OR bracket_matches_table.group_id IS NOT NULL THEN NULL
      ELSE public.resolve_bracket_knockout_priority_court_group_id(
        _bracket_edition_id,
        matches_table.sport_id,
        public.resolve_bracket_knockout_match_phase(
          bracket_matches_table.round_number,
          COALESCE(competition_rounds_table.total_round_number, bracket_matches_table.round_number),
          bracket_matches_table.is_third_place
        ),
        public.resolve_bracket_knockout_division_scope(matches_table.division)
      )
    END AS preferred_knockout_court_group_id
  FROM public.matches AS matches_table
  JOIN public.championship_bracket_matches AS bracket_matches_table
    ON bracket_matches_table.match_id = matches_table.id
  JOIN public.championship_sports AS championship_sports_table
    ON championship_sports_table.championship_id = matches_table.championship_id
    AND championship_sports_table.sport_id = matches_table.sport_id
  LEFT JOIN (
    SELECT
      competition_id,
      MAX(round_number) FILTER (WHERE is_third_place = false) AS total_round_number
    FROM public.championship_bracket_matches
    WHERE bracket_edition_id = _bracket_edition_id
    GROUP BY competition_id
  ) AS competition_rounds_table
    ON competition_rounds_table.competition_id = bracket_matches_table.competition_id
  WHERE bracket_matches_table.bracket_edition_id =
      _bracket_edition_id

    AND matches_table.status =
      'SCHEDULED'::public.match_status
    AND COALESCE(matches_table.is_pending_manual_relocation, false) = false

    AND NOT (
      bracket_matches_table.phase =
        'KNOCKOUT'::public.bracket_phase

      AND bracket_matches_table.is_third_place =
        false

      AND bracket_matches_table.planned_period
        IS NOT NULL

      AND bracket_matches_table
        .planned_court_group_id IS NOT NULL

      AND bracket_matches_table
        .planned_start_time IS NOT NULL

      AND bracket_matches_table
        .planned_end_time IS NOT NULL
    );

  DROP TABLE IF EXISTS tmp_global_court_slots;
  CREATE TEMP TABLE tmp_global_court_slots (
    slot_id BIGSERIAL PRIMARY KEY,
    bracket_day_id UUID NOT NULL,
    event_date DATE NOT NULL,
    sport_id UUID NOT NULL,
    duration_minutes INTEGER NOT NULL,
    location_name TEXT NOT NULL,
    location_group_id UUID NOT NULL,
    location_position INTEGER NOT NULL,
    court_id UUID NOT NULL,
    court_group_id UUID NOT NULL,
    court_name TEXT NOT NULL,
    court_position INTEGER NOT NULL,
    is_primary_sport BOOLEAN NOT NULL,

    priority_mode
      public.bracket_court_priority_mode
      NOT NULL,

    sequence_mode
      public.bracket_court_sequence_mode
      NOT NULL,

    primary_naipe public.match_naipe NULL,
    primary_division public.team_division NULL,
    slot_start_at TIMESTAMPTZ NOT NULL,
    slot_end_at TIMESTAMPTZ NOT NULL,
    court_sequence_index INTEGER NOT NULL
  ) ON COMMIT DROP;

  FOR day_court_record IN
    SELECT *
    FROM tmp_global_day_courts
    ORDER BY event_date ASC, location_position ASC, court_position ASC, court_name ASC
  LOOP
    slot_probe_at := day_court_record.next_available_at;
    slot_sequence_index := 0;

    LOOP
      slot_start_at := public.resolve_bracket_court_next_available_start(
        day_court_record.bracket_day_id,
        day_court_record.court_id,
        slot_probe_at,
        day_court_record.duration_minutes
      );

      EXIT WHEN slot_start_at IS NULL;

      slot_sequence_index := slot_sequence_index + 1;

      IF day_court_record.planned_match_count IS NOT NULL
        AND slot_sequence_index > day_court_record.planned_match_count
      THEN
        EXIT;
      END IF;

      slot_end_at := slot_start_at + make_interval(mins => day_court_record.duration_minutes);

      INSERT INTO tmp_global_court_slots (
        bracket_day_id,
        event_date,
        sport_id,
        duration_minutes,
        location_name,
        location_group_id,
        location_position,
        court_id,
        court_group_id,
        court_name,
        court_position,
        is_primary_sport,
        priority_mode,
        sequence_mode,
        primary_naipe,
        primary_division,
        slot_start_at,
        slot_end_at,
        court_sequence_index
      )
      VALUES (
        day_court_record.bracket_day_id,
        day_court_record.event_date,
        day_court_record.sport_id,
        day_court_record.duration_minutes,
        day_court_record.location_name,
        day_court_record.location_group_id,
        day_court_record.location_position,
        day_court_record.court_id,
        day_court_record.court_group_id,
        day_court_record.court_name,
        day_court_record.court_position,
        day_court_record.is_primary_sport,
        day_court_record.priority_mode,
        day_court_record.sequence_mode,
        day_court_record.primary_naipe,
        day_court_record.primary_division,
        slot_start_at,
        slot_end_at,
        slot_sequence_index
      );

      slot_probe_at := slot_end_at;
    END LOOP;
  END LOOP;

  DROP TABLE IF EXISTS tmp_global_assignments;
  CREATE TEMP TABLE tmp_global_assignments (
    match_id UUID PRIMARY KEY,
    order_index BIGINT NOT NULL,
    sport_id UUID NOT NULL,
    naipe public.match_naipe NOT NULL,
    division public.team_division NULL,
    home_team_id UUID NOT NULL,
    away_team_id UUID NOT NULL,
    duration_minutes INTEGER NOT NULL,
    court_sequence_index INTEGER NOT NULL,
    new_scheduled_date DATE NOT NULL,
    location_name TEXT NOT NULL,
    location_position INTEGER NOT NULL,
    court_name TEXT NOT NULL,
    court_position INTEGER NOT NULL,
    planned_start_at TIMESTAMPTZ NOT NULL,
    planned_end_at TIMESTAMPTZ NOT NULL
  ) ON COMMIT DROP;

  DROP TABLE IF EXISTS
    tmp_global_strict_blocked_slots;

  CREATE TEMP TABLE
    tmp_global_strict_blocked_slots (
      event_date DATE NOT NULL,
      location_name TEXT NOT NULL,
      court_name TEXT NOT NULL,
      slot_start_at TIMESTAMPTZ NOT NULL,
      slot_end_at TIMESTAMPTZ NOT NULL,

      PRIMARY KEY (
        event_date,
        location_name,
        court_name,
        slot_start_at,
        slot_end_at
      )
    )
  ON COMMIT DROP;

  FOR slot_record IN
    SELECT *
    FROM tmp_global_court_slots
    ORDER BY
      event_date ASC,
      slot_start_at ASC,
      CASE WHEN is_primary_sport THEN 0 ELSE 1 END ASC,
      location_position ASC,
      court_position ASC,
      court_name ASC,
      sport_id ASC
  LOOP
    IF EXISTS (
      SELECT 1
      FROM tmp_global_manual_final_matches
        AS manual_final_matches_table
      WHERE manual_final_matches_table.event_date =
          slot_record.event_date

        AND public.normalize_bracket_entity_name(
          manual_final_matches_table.location_name
        ) =
          public.normalize_bracket_entity_name(
            slot_record.location_name
          )

        AND public.normalize_bracket_entity_name(
          manual_final_matches_table.court_name
        ) =
          public.normalize_bracket_entity_name(
            slot_record.court_name
          )

        AND manual_final_matches_table.start_time <
          slot_record.slot_end_at

        AND manual_final_matches_table.end_time >
          slot_record.slot_start_at
    )
    OR EXISTS (
      SELECT 1
      FROM tmp_global_strict_blocked_slots
        AS blocked_slots_table
      WHERE blocked_slots_table.event_date =
          slot_record.event_date

        AND blocked_slots_table.location_name =
          slot_record.location_name

        AND blocked_slots_table.court_name =
          slot_record.court_name

        AND blocked_slots_table.slot_start_at <
          slot_record.slot_end_at

        AND blocked_slots_table.slot_end_at >
          slot_record.slot_start_at
    )
    THEN
      CONTINUE;
    END IF;

    slot_match_assigned := false;

    IF EXISTS (
      SELECT 1
      FROM tmp_global_assignments
        AS existing_court_assignments
      WHERE existing_court_assignments.new_scheduled_date =
          slot_record.event_date
        AND existing_court_assignments.location_name =
          slot_record.location_name
        AND existing_court_assignments.court_name =
          slot_record.court_name
        AND existing_court_assignments.planned_start_at <
          slot_record.slot_end_at
        AND existing_court_assignments.planned_end_at >
          slot_record.slot_start_at
    ) THEN
      CONTINUE;
    END IF;

    SELECT
      day_courts_table.last_naipe,
      day_courts_table.last_division,

      day_courts_table.active_sequence_naipe,
      day_courts_table.active_sequence_division,

      day_courts_table.completed_sequence_naipes,
      day_courts_table.completed_sequence_divisions

    INTO
      slot_last_naipe,
      slot_last_division,

      strict_active_naipe,
      strict_active_division,

      strict_completed_naipes,
      strict_completed_divisions

    FROM tmp_global_day_courts AS day_courts_table
    WHERE day_courts_table.bracket_day_id = slot_record.bracket_day_id
      AND day_courts_table.court_id = slot_record.court_id
      AND day_courts_table.sport_id = slot_record.sport_id;

    has_reserved_division_pending := false;
    has_reserved_naipe_pending := false;
    strict_current_knockout_round := NULL;
    strict_alternate_naipe_after_exclusive_knockout_phase := false;
    strict_phase_naipes := ARRAY[]::public.match_naipe[];
    strict_exclusive_knockout_naipe := NULL;

    IF slot_record.sequence_mode =
        'GROUP_NAIPE'::public.bracket_court_sequence_mode
    THEN
      SELECT court_sports_table.alternate_naipe_after_exclusive_knockout_phase
      INTO strict_alternate_naipe_after_exclusive_knockout_phase
      FROM public.championship_bracket_court_sports AS court_sports_table
      WHERE court_sports_table.bracket_court_id = slot_record.court_id
        AND court_sports_table.sport_id = slot_record.sport_id
      LIMIT 1;

      IF COALESCE(strict_alternate_naipe_after_exclusive_knockout_phase, false) THEN
        SELECT MIN(pending_matches_table.knockout_round_number)
        INTO strict_current_knockout_round
        FROM tmp_global_pending_matches AS pending_matches_table
        WHERE pending_matches_table.sport_id = slot_record.sport_id
          AND pending_matches_table.is_knockout
          AND (
            pending_matches_table.preferred_knockout_court_group_id IS NULL
            OR public.is_bracket_knockout_priority_court_match(_bracket_edition_id, pending_matches_table.preferred_knockout_court_group_id, slot_record.court_group_id)
          );

        IF strict_current_knockout_round IS NOT NULL THEN
          SELECT ARRAY_AGG(DISTINCT pending_matches_table.naipe)
          INTO strict_phase_naipes
          FROM tmp_global_pending_matches AS pending_matches_table
          WHERE pending_matches_table.sport_id = slot_record.sport_id
            AND pending_matches_table.knockout_round_number = strict_current_knockout_round
            AND (
              pending_matches_table.preferred_knockout_court_group_id IS NULL
              OR public.is_bracket_knockout_priority_court_match(_bracket_edition_id, pending_matches_table.preferred_knockout_court_group_id, slot_record.court_group_id)
            );

          IF COALESCE(array_length(strict_phase_naipes, 1), 0) = 1 THEN
            strict_active_naipe := strict_phase_naipes[1];
          ELSIF COALESCE(array_length(strict_phase_naipes, 1), 0) = 2 THEN
            SELECT phase_summary.naipe
            INTO strict_exclusive_knockout_naipe
            FROM (
              SELECT
                previous_matches_table.round_number,
                MIN(previous_scheduled_matches_table.naipe)
                  AS naipe
              FROM public.championship_bracket_matches AS previous_matches_table
              JOIN public.matches AS previous_scheduled_matches_table
                ON previous_scheduled_matches_table.id = previous_matches_table.match_id
              WHERE previous_matches_table.bracket_edition_id = _bracket_edition_id
                AND previous_scheduled_matches_table.sport_id = slot_record.sport_id
                AND previous_matches_table.group_id IS NULL
                AND previous_matches_table.is_third_place = false
                AND previous_matches_table.round_number < strict_current_knockout_round
              GROUP BY previous_matches_table.round_number
              HAVING COUNT(DISTINCT previous_scheduled_matches_table.naipe) = 1
            ) AS phase_summary
            ORDER BY phase_summary.round_number DESC
            LIMIT 1;

            IF strict_exclusive_knockout_naipe IS NOT NULL THEN
              SELECT pending_matches_table.naipe
              INTO strict_active_naipe
              FROM tmp_global_pending_matches AS pending_matches_table
              WHERE pending_matches_table.sport_id = slot_record.sport_id
                AND pending_matches_table.knockout_round_number = strict_current_knockout_round
                AND pending_matches_table.naipe IS DISTINCT FROM strict_exclusive_knockout_naipe
              ORDER BY pending_matches_table.naipe
              LIMIT 1;
            END IF;
          END IF;

          strict_completed_naipes := ARRAY[]::public.match_naipe[];
        END IF;
      END IF;
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM tmp_global_pending_matches
        AS pending_matches_table

      WHERE pending_matches_table.sport_id =
          slot_record.sport_id

        AND pending_matches_table
          .original_scheduled_date =
            slot_record.event_date

        AND (
          pending_matches_table
            .preferred_knockout_court_group_id
              IS NULL

          OR public.is_bracket_knockout_priority_court_match(_bracket_edition_id, pending_matches_table.preferred_knockout_court_group_id, slot_record.court_group_id)
        )
    )
    INTO has_same_day_pending;

    strict_group_pending := false;

    IF slot_record.sequence_mode =
      'GROUP_NAIPE'
        ::public.bracket_court_sequence_mode
    THEN
      LOOP
        EXIT WHEN strict_active_naipe IS NULL;

        SELECT EXISTS (
          SELECT 1
          FROM tmp_global_pending_matches
            AS pending_matches_table

          WHERE pending_matches_table.sport_id =
              slot_record.sport_id

            AND pending_matches_table.naipe
              IS NOT DISTINCT FROM
                strict_active_naipe

            AND (
              pending_matches_table
                .preferred_knockout_court_group_id
                  IS NULL

              OR pending_matches_table
                .preferred_knockout_court_group_id =
                  slot_record.court_group_id
            )

            AND (
              NOT has_same_day_pending

              OR pending_matches_table
                .original_scheduled_date =
                  slot_record.event_date
            )
        )
        INTO strict_group_pending;

        EXIT WHEN strict_group_pending;

        strict_completed_naipes :=
          COALESCE(
            strict_completed_naipes,
            ARRAY[]::public.match_naipe[]
          );

        IF NOT (
          strict_active_naipe =
            ANY(strict_completed_naipes)
        )
        THEN
          strict_completed_naipes :=
            array_append(
              strict_completed_naipes,
              strict_active_naipe
            );
        END IF;

        SELECT pending_matches_table.naipe
        INTO strict_active_naipe
        FROM tmp_global_pending_matches
          AS pending_matches_table

        WHERE pending_matches_table.sport_id =
            slot_record.sport_id

          AND NOT (
            pending_matches_table.naipe =
              ANY(strict_completed_naipes)
          )

          AND (
            pending_matches_table
              .preferred_knockout_court_group_id
                IS NULL

            OR pending_matches_table
              .preferred_knockout_court_group_id =
                slot_record.court_group_id
          )

          AND (
            NOT has_same_day_pending

            OR pending_matches_table
              .original_scheduled_date =
                slot_record.event_date
          )

        GROUP BY pending_matches_table.naipe

        ORDER BY
          CASE pending_matches_table.naipe
            WHEN 'FEMININO'
              ::public.match_naipe
              THEN 1

            WHEN 'MASCULINO'
              ::public.match_naipe
              THEN 2

            WHEN 'MISTO'
              ::public.match_naipe
              THEN 3

            ELSE 99
          END,

          pending_matches_table.naipe

        LIMIT 1;

        UPDATE tmp_global_day_courts
          AS day_courts_table

        SET
          active_sequence_naipe =
            strict_active_naipe,

          completed_sequence_naipes =
            strict_completed_naipes

        WHERE day_courts_table.bracket_day_id =
            slot_record.bracket_day_id

          AND day_courts_table.court_id =
            slot_record.court_id

          AND day_courts_table.sport_id =
            slot_record.sport_id;
      END LOOP;

    ELSIF slot_record.sequence_mode =
      'GROUP_DIVISION'
        ::public.bracket_court_sequence_mode
    THEN
      LOOP
        EXIT WHEN strict_active_division IS NULL;

        SELECT EXISTS (
          SELECT 1
          FROM tmp_global_pending_matches
            AS pending_matches_table

          WHERE pending_matches_table.sport_id =
              slot_record.sport_id

            AND pending_matches_table.division
              IS NOT DISTINCT FROM
                strict_active_division

            AND (
              pending_matches_table
                .preferred_knockout_court_group_id
                  IS NULL

              OR pending_matches_table
                .preferred_knockout_court_group_id =
                  slot_record.court_group_id
            )

            AND (
              NOT has_same_day_pending

              OR pending_matches_table
                .original_scheduled_date =
                  slot_record.event_date
            )
        )
        INTO strict_group_pending;

        EXIT WHEN strict_group_pending;

        strict_completed_divisions :=
          COALESCE(
            strict_completed_divisions,
            ARRAY[]::public.team_division[]
          );

        IF NOT (
          strict_active_division =
            ANY(strict_completed_divisions)
        )
        THEN
          strict_completed_divisions :=
            array_append(
              strict_completed_divisions,
              strict_active_division
            );
        END IF;

        SELECT pending_matches_table.division
        INTO strict_active_division
        FROM tmp_global_pending_matches
          AS pending_matches_table

        WHERE pending_matches_table.sport_id =
            slot_record.sport_id

          AND pending_matches_table.division
            IS NOT NULL

          AND NOT (
            pending_matches_table.division =
              ANY(strict_completed_divisions)
          )

          AND (
            pending_matches_table
              .preferred_knockout_court_group_id
                IS NULL

            OR pending_matches_table
              .preferred_knockout_court_group_id =
                slot_record.court_group_id
          )

          AND (
            NOT has_same_day_pending

            OR pending_matches_table
              .original_scheduled_date =
                slot_record.event_date
          )

        GROUP BY pending_matches_table.division

        ORDER BY
          CASE pending_matches_table.division
            WHEN 'DIVISAO_PRINCIPAL'
              ::public.team_division
              THEN 1

            WHEN 'DIVISAO_ACESSO'
              ::public.team_division
              THEN 2

            ELSE 99
          END,

          pending_matches_table.division

        LIMIT 1;

        UPDATE tmp_global_day_courts
          AS day_courts_table

        SET
          active_sequence_division =
            strict_active_division,

          completed_sequence_divisions =
            strict_completed_divisions

        WHERE day_courts_table.bracket_day_id =
            slot_record.bracket_day_id

          AND day_courts_table.court_id =
            slot_record.court_id

          AND day_courts_table.sport_id =
            slot_record.sport_id;
      END LOOP;
    END IF;

    IF slot_record.priority_mode = 'DIVISION'::public.bracket_court_priority_mode
      AND slot_record.primary_division IS NOT NULL THEN
      SELECT EXISTS (
        SELECT 1
        FROM tmp_global_pending_matches AS pending_matches_table
        WHERE pending_matches_table.sport_id = slot_record.sport_id
          AND pending_matches_table.division = slot_record.primary_division
          AND (
            pending_matches_table.preferred_knockout_court_group_id IS NULL
            OR public.is_bracket_knockout_priority_court_match(_bracket_edition_id, pending_matches_table.preferred_knockout_court_group_id, slot_record.court_group_id)
          )
          AND (
            pending_matches_table.original_scheduled_date IS NULL
            OR slot_record.event_date >= pending_matches_table.original_scheduled_date
          )
          AND (
            NOT has_same_day_pending
            OR pending_matches_table.original_scheduled_date = slot_record.event_date
          )
      )
      INTO has_reserved_division_pending;
    END IF;

    IF slot_record.priority_mode = 'NAIPE'::public.bracket_court_priority_mode
      AND slot_record.primary_naipe IS NOT NULL THEN
      SELECT EXISTS (
        SELECT 1
        FROM tmp_global_pending_matches AS pending_matches_table
        WHERE pending_matches_table.sport_id = slot_record.sport_id
          AND pending_matches_table.naipe = slot_record.primary_naipe
          AND (
            pending_matches_table.preferred_knockout_court_group_id IS NULL
            OR public.is_bracket_knockout_priority_court_match(_bracket_edition_id, pending_matches_table.preferred_knockout_court_group_id, slot_record.court_group_id)
          )
          AND (
            pending_matches_table.original_scheduled_date IS NULL
            OR slot_record.event_date >= pending_matches_table.original_scheduled_date
          )
          AND (
            NOT has_same_day_pending
            OR pending_matches_table.original_scheduled_date = slot_record.event_date
          )
      )
      INTO has_reserved_naipe_pending;
    END IF;

    FOR pending_match_record IN
      SELECT
        pending_matches_table.*
      FROM tmp_global_pending_matches AS pending_matches_table
      WHERE pending_matches_table.sport_id = slot_record.sport_id

        AND (
          pending_matches_table.preferred_knockout_court_group_id IS NULL
          OR public.is_bracket_knockout_priority_court_match(_bracket_edition_id, pending_matches_table.preferred_knockout_court_group_id, slot_record.court_group_id)
        )

        AND (
          NOT has_same_day_pending
          OR pending_matches_table.original_scheduled_date = slot_record.event_date
        )

        AND public.is_championship_bracket_competition_slot_playable(
          bracket_edition_record.payload_snapshot,
          pending_matches_table.sport_id::text
            || '::'
            || pending_matches_table.naipe::text
            || '::'
            || COALESCE(
              pending_matches_table.division::text,
              'WITHOUT_DIVISION'
            ),
          slot_record.event_date,
          slot_record.slot_start_at,
          slot_record.slot_end_at
        )

        AND (
          pending_matches_table.group_id IS NULL
          OR (
            public.is_championship_bracket_team_slot_playable(
              bracket_edition_record.payload_snapshot,
              pending_matches_table.home_team_id,
              pending_matches_table.sport_id::text
                || '::'
                || pending_matches_table.naipe::text
                || '::'
                || COALESCE(
                  pending_matches_table.division::text,
                  'WITHOUT_DIVISION'
                ),
              slot_record.event_date,
              slot_record.slot_start_at,
              slot_record.slot_end_at
            )
            AND public.is_championship_bracket_team_slot_playable(
              bracket_edition_record.payload_snapshot,
              pending_matches_table.away_team_id,
              pending_matches_table.sport_id::text
                || '::'
                || pending_matches_table.naipe::text
                || '::'
                || COALESCE(
                  pending_matches_table.division::text,
                  'WITHOUT_DIVISION'
                ),
              slot_record.event_date,
              slot_record.slot_start_at,
              slot_record.slot_end_at
            )
          )
        )

        AND (
          slot_record.priority_mode <> 'DIVISION'::public.bracket_court_priority_mode
          OR slot_record.primary_division IS NULL
          OR (
            slot_record.primary_division = 'DIVISAO_PRINCIPAL'::public.team_division
            AND pending_matches_table.division IS NOT DISTINCT FROM slot_record.primary_division
          )
          OR (
            slot_record.primary_division = 'DIVISAO_ACESSO'::public.team_division
            AND (
              pending_matches_table.division IS NOT DISTINCT FROM slot_record.primary_division
              OR NOT has_reserved_division_pending
            )
          )
        )
        AND (
          NOT has_reserved_naipe_pending
          OR slot_record.priority_mode <> 'NAIPE'::public.bracket_court_priority_mode
          OR pending_matches_table.naipe IS NOT DISTINCT FROM slot_record.primary_naipe
        )
      ORDER BY
        CASE
          WHEN slot_record.is_primary_sport
            AND (
              slot_record.sequence_mode =
                'ALTERNATE_NAIPE'
                  ::public.bracket_court_sequence_mode
              OR slot_record.primary_naipe IS NULL
              OR pending_matches_table.naipe IS NOT DISTINCT FROM
                slot_record.primary_naipe
            )
            AND (
              slot_record.primary_division IS NULL
              OR pending_matches_table.division IS NOT DISTINCT FROM
                slot_record.primary_division
            )
          THEN 0
          WHEN slot_record.is_primary_sport
          THEN 1
          ELSE 0
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
            AND pending_matches_table.is_knockout
            AND pending_matches_table.knockout_round_number IS DISTINCT FROM strict_current_knockout_round THEN 1
          ELSE 0
        END ASC,
        CASE
          WHEN slot_record.sequence_mode = 'GROUP_DIVISION'::public.bracket_court_sequence_mode
            AND strict_active_division IS NOT NULL
            AND pending_matches_table.division IS DISTINCT FROM strict_active_division THEN 1
          WHEN slot_record.sequence_mode = 'GROUP_NAIPE'::public.bracket_court_sequence_mode
            AND strict_active_naipe IS NOT NULL
            AND pending_matches_table.naipe IS DISTINCT FROM strict_active_naipe THEN 1
          WHEN slot_record.priority_mode = 'DIVISION'::public.bracket_court_priority_mode
            AND slot_record.primary_division IS NOT NULL
            AND pending_matches_table.division IS DISTINCT FROM slot_record.primary_division THEN 1
          WHEN slot_record.priority_mode = 'NAIPE'::public.bracket_court_priority_mode
            AND slot_record.primary_naipe IS NOT NULL
            AND pending_matches_table.naipe IS DISTINCT FROM slot_record.primary_naipe THEN 1
          ELSE 0
        END ASC,
        CASE
          WHEN slot_last_naipe IS NULL THEN 1
          WHEN pending_matches_table.naipe IS DISTINCT FROM slot_last_naipe THEN 0
          ELSE 1
        END ASC,
        (
          SELECT count(*)
          FROM tmp_global_pending_matches AS sibling_pending_matches_table
          WHERE sibling_pending_matches_table.match_id <> pending_matches_table.match_id
            AND sibling_pending_matches_table.sport_id = pending_matches_table.sport_id
            AND sibling_pending_matches_table.naipe = pending_matches_table.naipe
            AND (
              sibling_pending_matches_table.home_team_id IN (pending_matches_table.home_team_id, pending_matches_table.away_team_id)
              OR sibling_pending_matches_table.away_team_id IN (pending_matches_table.home_team_id, pending_matches_table.away_team_id)
            )
        ) DESC,
        (
          SELECT count(*)
          FROM tmp_global_pending_matches AS sibling_pending_matches_table
          WHERE sibling_pending_matches_table.match_id <> pending_matches_table.match_id
            AND sibling_pending_matches_table.sport_id = pending_matches_table.sport_id
            AND sibling_pending_matches_table.naipe <> pending_matches_table.naipe
            AND (
              sibling_pending_matches_table.home_team_id IN (pending_matches_table.home_team_id, pending_matches_table.away_team_id)
              OR sibling_pending_matches_table.away_team_id IN (pending_matches_table.home_team_id, pending_matches_table.away_team_id)
            )
        ) DESC,
        pending_matches_table.order_index ASC
    LOOP
      SELECT EXISTS (
        SELECT 1
        FROM tmp_global_assignments AS existing_assignments_table
        WHERE existing_assignments_table.new_scheduled_date = slot_record.event_date
          AND existing_assignments_table.planned_start_at = slot_record.slot_start_at
          AND (
            existing_assignments_table.home_team_id IN (pending_match_record.home_team_id, pending_match_record.away_team_id)
            OR existing_assignments_table.away_team_id IN (pending_match_record.home_team_id, pending_match_record.away_team_id)
          )
      )
      INTO same_start_time_team_conflict;

      IF same_start_time_team_conflict THEN
        CONTINUE;
      END IF;

      SELECT EXISTS (
        SELECT 1
        FROM tmp_global_assignments AS existing_assignments_table
        WHERE existing_assignments_table.new_scheduled_date = slot_record.event_date
          AND existing_assignments_table.location_name = slot_record.location_name
          AND existing_assignments_table.court_name = slot_record.court_name
          AND (
            existing_assignments_table.home_team_id IN (pending_match_record.home_team_id, pending_match_record.away_team_id)
            OR existing_assignments_table.away_team_id IN (pending_match_record.home_team_id, pending_match_record.away_team_id)
          )
          AND public.is_championship_team_rest_gap_conflict(
            pending_match_record.naipe,
            existing_assignments_table.naipe,
            true,
            slot_record.court_sequence_index,
            existing_assignments_table.court_sequence_index,
            slot_record.slot_start_at,
            existing_assignments_table.planned_start_at,
            pending_match_record.duration_minutes,
            existing_assignments_table.duration_minutes,
            pending_match_record.is_knockout
          )
      )
      INTO same_court_same_naipe_rest_conflict;

      IF same_court_same_naipe_rest_conflict THEN
        CONTINUE;
      END IF;

      SELECT false
      INTO same_court_different_naipe_rest_conflict;

      IF same_court_different_naipe_rest_conflict THEN
        CONTINUE;
      END IF;

      SELECT EXISTS (
        SELECT 1
        FROM tmp_global_assignments AS existing_assignments_table
        WHERE existing_assignments_table.new_scheduled_date = slot_record.event_date
          AND (
            existing_assignments_table.location_name <> slot_record.location_name
            OR existing_assignments_table.court_name <> slot_record.court_name
          )
          AND (
            existing_assignments_table.home_team_id IN (pending_match_record.home_team_id, pending_match_record.away_team_id)
            OR existing_assignments_table.away_team_id IN (pending_match_record.home_team_id, pending_match_record.away_team_id)
          )
          AND public.is_championship_team_rest_gap_conflict(
            pending_match_record.naipe,
            existing_assignments_table.naipe,
            false,
            NULL,
            NULL,
            slot_record.slot_start_at,
            existing_assignments_table.planned_start_at,
            pending_match_record.duration_minutes,
            existing_assignments_table.duration_minutes,
            pending_match_record.is_knockout
          )
      )
      INTO cross_court_same_naipe_time_conflict;

      IF cross_court_same_naipe_time_conflict THEN
        CONTINUE;
      END IF;

      SELECT false
      INTO cross_court_different_naipe_time_conflict;

      IF cross_court_different_naipe_time_conflict THEN
        CONTINUE;
      END IF;

      INSERT INTO tmp_global_assignments (
        match_id,
        order_index,
        sport_id,
        naipe,
        division,
        home_team_id,
        away_team_id,
        duration_minutes,
        court_sequence_index,
        new_scheduled_date,
        location_name,
        location_position,
        court_name,
        court_position,
        planned_start_at,
        planned_end_at
      )
      VALUES (
        pending_match_record.match_id,
        pending_match_record.order_index,
        pending_match_record.sport_id,
        pending_match_record.naipe,
        pending_match_record.division,
        pending_match_record.home_team_id,
        pending_match_record.away_team_id,
        pending_match_record.duration_minutes,
        slot_record.court_sequence_index,
        slot_record.event_date,
        slot_record.location_name,
        slot_record.location_position,
        slot_record.court_name,
        slot_record.court_position,
        slot_record.slot_start_at,
        slot_record.slot_end_at
      );

      UPDATE tmp_global_day_courts AS day_courts_table
      SET
        assigned_count = day_courts_table.assigned_count + 1,
        last_naipe = pending_match_record.naipe,
        last_division = pending_match_record.division
      WHERE day_courts_table.bracket_day_id = slot_record.bracket_day_id
        AND day_courts_table.court_id = slot_record.court_id
        AND day_courts_table.sport_id = slot_record.sport_id;

      DELETE FROM tmp_global_pending_matches
      WHERE order_index = pending_match_record.order_index;

      slot_match_assigned := true;

      EXIT;
    END LOOP;

  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM tmp_global_pending_matches
  )
  THEN
    RAISE EXCEPTION
      'Não foi possível encaixar todos os jogos na grade disponível respeitando descanso e prioridade das quadras. Total pendente: %. Detalhamento dos jogos pendentes: %',
      (
        SELECT COUNT(*)::integer
        FROM tmp_global_pending_matches
      ),
      (
        SELECT COALESCE(
          jsonb_agg(
            jsonb_build_object(
              'modalidade',
                pending_summary.sport_name,

              'naipe',
                pending_summary.naipe,

              'data_original',
                pending_summary.original_scheduled_date,

              'jogos_pendentes',
                pending_summary.pending_count
            )
            ORDER BY
              pending_summary.original_scheduled_date ASC NULLS LAST,
              pending_summary.sport_name ASC,
              pending_summary.naipe ASC
          ),
          '[]'::jsonb
        )

        FROM (
          SELECT
            COALESCE(
              sports_table.name,
              pending_matches_table.sport_id::text
            ) AS sport_name,

            pending_matches_table.naipe,

            pending_matches_table.original_scheduled_date,

            COUNT(*)::integer
              AS pending_count

          FROM tmp_global_pending_matches
            AS pending_matches_table

          LEFT JOIN public.sports
            AS sports_table
            ON sports_table.id =
              pending_matches_table.sport_id

          GROUP BY
            COALESCE(
              sports_table.name,
              pending_matches_table.sport_id::text
            ),

            pending_matches_table.naipe,

            pending_matches_table.original_scheduled_date
        ) AS pending_summary
      );
  END IF;

  DROP TABLE IF EXISTS tmp_global_assignment_queue_positions;
  CREATE TEMP TABLE tmp_global_assignment_queue_positions AS
  WITH assignment_scopes AS (
    SELECT DISTINCT
      assignments_table.new_scheduled_date,
      assignments_table.sport_id,
      assignments_table.naipe,
      public.coerce_division_for_index(assignments_table.division) AS division_scope
    FROM tmp_global_assignments AS assignments_table
  ),
  assignment_queue_scope_offsets AS (
    SELECT
      assignment_scopes.new_scheduled_date,
      assignment_scopes.sport_id,
      assignment_scopes.naipe,
      assignment_scopes.division_scope,
      COUNT(matches_table.id)::INTEGER AS existing_queue_offset
    FROM assignment_scopes
    LEFT JOIN public.matches AS matches_table
      ON matches_table.championship_id = bracket_edition_record.championship_id
      AND matches_table.season_year = bracket_edition_record.season_year
      AND matches_table.scheduled_date = assignment_scopes.new_scheduled_date
      AND matches_table.sport_id = assignment_scopes.sport_id
      AND matches_table.naipe = assignment_scopes.naipe
      AND public.coerce_division_for_index(matches_table.division) IS NOT DISTINCT FROM assignment_scopes.division_scope
      AND matches_table.queue_position IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM tmp_global_assignments AS current_assignments_table
        WHERE current_assignments_table.match_id = matches_table.id
      )
    GROUP BY
      assignment_scopes.new_scheduled_date,
      assignment_scopes.sport_id,
      assignment_scopes.naipe,
      assignment_scopes.division_scope
  )
  SELECT
    assignments_table.match_id,
    DENSE_RANK() OVER (
      PARTITION BY assignments_table.new_scheduled_date
      ORDER BY assignments_table.planned_start_at ASC
    ) AS new_scheduled_slot,
    (
      COALESCE(scope_offsets.existing_queue_offset, 0)
      + ROW_NUMBER() OVER (
        PARTITION BY
          assignments_table.new_scheduled_date,
          assignments_table.sport_id,
          assignments_table.naipe,
          public.coerce_division_for_index(assignments_table.division)
        ORDER BY
          assignments_table.planned_start_at ASC,
          assignments_table.location_position ASC,
          assignments_table.court_position ASC,
          assignments_table.order_index ASC
      )
    )::INTEGER AS new_queue_position,
    assignments_table.new_scheduled_date,
    assignments_table.location_name,
    assignments_table.court_name,
    assignments_table.planned_start_at,
    assignments_table.planned_end_at
  FROM tmp_global_assignments AS assignments_table
  LEFT JOIN assignment_queue_scope_offsets AS scope_offsets
    ON scope_offsets.new_scheduled_date = assignments_table.new_scheduled_date
    AND scope_offsets.sport_id = assignments_table.sport_id
    AND scope_offsets.naipe = assignments_table.naipe
    AND scope_offsets.division_scope IS NOT DISTINCT FROM public.coerce_division_for_index(assignments_table.division);

  /*
   * A distribuição já foi integralmente validada em
   * tmp_global_assignments.
   *
   * Os triggers abaixo precisam ser ignorados somente durante a
   * materialização da mudança porque um UPDATE em massa é executado
   * linha por linha pelo PostgreSQL.
   *
   * Sem este bloco, o trigger pode comparar uma partida já movida
   * com outra que ainda está temporariamente na posição antiga.
   */
  BEGIN
    PERFORM set_config(
      'app.skip_queue_trigger',
      'true',
      true
    );

    PERFORM set_config(
      'app.skip_match_conflict_trigger',
      'true',
      true
    );


    /*
     * Libera as posições antigas antes de escrever a nova fila.
     */
    UPDATE public.matches
      AS matches_table
    SET
      queue_position = NULL

    FROM
      tmp_global_assignment_queue_positions
        AS assignment_queue_positions_table

    WHERE assignment_queue_positions_table.match_id =
      matches_table.id;


    /*
     * Materializa exatamente a distribuição calculada e validada.
     */
    UPDATE public.matches
      AS matches_table
    SET
      scheduled_date =
        assignment_queue_positions_table.new_scheduled_date,

      scheduled_slot =
        assignment_queue_positions_table.new_scheduled_slot,

      queue_position =
        assignment_queue_positions_table.new_queue_position,

      location =
        assignment_queue_positions_table.location_name,

      court_name =
        assignment_queue_positions_table.court_name,

      start_time =
        assignment_queue_positions_table.planned_start_at,

      end_time =
        assignment_queue_positions_table.planned_end_at

    FROM
      tmp_global_assignment_queue_positions
        AS assignment_queue_positions_table

    WHERE assignment_queue_positions_table.match_id =
      matches_table.id;


    PERFORM set_config(
      'app.skip_match_conflict_trigger',
      'false',
      true
    );

    PERFORM set_config(
      'app.skip_queue_trigger',
      'false',
      true
    );


  EXCEPTION
    WHEN OTHERS
    THEN
      /*
       * Nunca deixa os flags ligados caso alguma etapa da
       * materialização falhe.
       */
      PERFORM set_config(
        'app.skip_match_conflict_trigger',
        'false',
        true
      );

      PERFORM set_config(
        'app.skip_queue_trigger',
        'false',
        true
      );

      RAISE;
  END;


  /*
   * A programação especial da Society roda novamente com as
   * validações normais habilitadas.
   */
  PERFORM public.apply_society_2026_official_schedule(
    _bracket_edition_id
  );
END;
$function$;

-- Original: resolve_bracket_court_next_available_start(_bracket_day_id uuid, _bracket_court_id uuid, _candidate_start timestamp with time zone, _duration_minutes integer)
CREATE OR REPLACE FUNCTION public.resolve_bracket_court_next_available_start(_bracket_day_id uuid, _bracket_court_id uuid, _candidate_start timestamp with time zone, _duration_minutes integer)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  bracket_day_record RECORD;
  break_record RECORD;

  current_start TIMESTAMPTZ;
  current_end TIMESTAMPTZ;

  configured_day_start_at TIMESTAMPTZ;
  configured_day_end_at TIMESTAMPTZ;
  next_midnight_at TIMESTAMPTZ;

  has_conflicting_break BOOLEAN;
BEGIN
  IF _duration_minutes IS NULL
    OR _duration_minutes <= 0
  THEN
    RETURN NULL;
  END IF;


  SELECT
    event_date,
    start_time,
    end_time
  INTO bracket_day_record

  FROM public.championship_bracket_days

  WHERE id =
    _bracket_day_id

  LIMIT 1;


  IF bracket_day_record.event_date
    IS NULL
  THEN
    RETURN NULL;
  END IF;


  configured_day_start_at :=
    public.combine_bracket_schedule_timestamp(
      bracket_day_record.event_date,
      bracket_day_record.start_time
    );


  configured_day_end_at :=
    public.combine_bracket_schedule_timestamp(
      bracket_day_record.event_date,
      bracket_day_record.end_time
    );


  /*
   * A agenda nunca faz rollover automático de uma partida
   * atravessando a meia-noite.
   *
   * O próximo jogo deve ser programado explicitamente em outro dia.
   */
  next_midnight_at :=
    (
      (
        bracket_day_record.event_date
        + 1
      )::timestamp
      AT TIME ZONE 'America/Sao_Paulo'
    );


  current_start :=
    GREATEST(
      _candidate_start,
      configured_day_start_at
    );


  LOOP
    /*
     * O horário final configurado para o dia é o último limite
     * operacional para INICIAR uma nova partida.
     *
     * Ex.:
     *
     * limite = 20:00
     *
     * 19:59 → permitido
     * 20:00 → não inicia
     */
    IF current_start >=
      configured_day_end_at
    THEN
      RETURN NULL;
    END IF;


    current_end :=
      current_start
      + make_interval(
          mins => _duration_minutes
        );


    /*
     * Mesmo podendo ultrapassar o horário configurado de término
     * da agenda, uma partida automática nunca atravessa a meia-noite.
     *
     * Terminar exatamente 00:00 também é rejeitado.
     */
    IF current_end >=
      next_midnight_at
    THEN
      RETURN NULL;
    END IF;


    has_conflicting_break :=
      false;


    FOR break_record IN
      SELECT
        public.combine_bracket_schedule_timestamp(
          bracket_day_record.event_date,
          bracket_day_breaks_table.break_start_time
        ) AS break_start_at,

        public.combine_bracket_schedule_timestamp(
          bracket_day_record.event_date,
          bracket_day_breaks_table.break_end_time
        ) AS break_end_at

      FROM
        public.championship_bracket_day_breaks
          AS bracket_day_breaks_table

      WHERE bracket_day_breaks_table.bracket_day_id =
          _bracket_day_id

        AND (
          bracket_day_breaks_table.scope_type =
            'ALL_COURTS'
              ::public.bracket_day_break_scope_type

          OR (
            bracket_day_breaks_table.scope_type =
              'COURT'
                ::public.bracket_day_break_scope_type

            AND bracket_day_breaks_table.bracket_court_id =
              _bracket_court_id
          )
        )

      ORDER BY
        bracket_day_breaks_table.break_start_time ASC,
        bracket_day_breaks_table.position ASC
    LOOP
      /*
       * Continua proibido atravessar uma pausa.
       *
       * Se houver conflito, o candidato é empurrado exatamente
       * para o final da pausa.
       */
      IF current_start <
          break_record.break_end_at

        AND current_end >
          break_record.break_start_at
      THEN
        current_start :=
          break_record.break_end_at;

        has_conflicting_break :=
          true;

        EXIT;
      END IF;
    END LOOP;


    EXIT WHEN NOT
      has_conflicting_break;
  END LOOP;


  RETURN current_start;
END;
$function$;

-- Original: resolve_bracket_knockout_priority_court_group_id(_bracket_edition_id uuid, _sport_id uuid, _phase bracket_knockout_priority_phase, _division_scope bracket_knockout_division_scope)
CREATE OR REPLACE FUNCTION public.resolve_bracket_knockout_priority_court_group_id(_bracket_edition_id uuid, _sport_id uuid, _phase bracket_knockout_priority_phase, _division_scope bracket_knockout_division_scope)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  resolved_court_group_id UUID;
BEGIN
  IF _bracket_edition_id IS NULL
    OR _sport_id IS NULL
    OR _phase IS NULL
  THEN
    RETURN NULL;
  END IF;

  SELECT priorities_table.court_group_id
  INTO resolved_court_group_id
  FROM public.championship_bracket_knockout_court_priorities AS priorities_table
  WHERE priorities_table.bracket_edition_id = _bracket_edition_id
    AND priorities_table.sport_id = _sport_id
    AND priorities_table.phase = _phase
    AND priorities_table.division_scope = COALESCE(
      _division_scope,
      'ALL'::public.bracket_knockout_division_scope
    )
  LIMIT 1;

  IF resolved_court_group_id IS NULL
    AND COALESCE(
      _division_scope,
      'ALL'::public.bracket_knockout_division_scope
    ) <> 'ALL'::public.bracket_knockout_division_scope
  THEN
    SELECT priorities_table.court_group_id
    INTO resolved_court_group_id
    FROM public.championship_bracket_knockout_court_priorities AS priorities_table
    WHERE priorities_table.bracket_edition_id = _bracket_edition_id
      AND priorities_table.sport_id = _sport_id
      AND priorities_table.phase = _phase
      AND priorities_table.division_scope =
        'ALL'::public.bracket_knockout_division_scope
    LIMIT 1;
  END IF;

  IF resolved_court_group_id IS NOT NULL THEN
    RETURN resolved_court_group_id;
  END IF;

  WITH compatible_court_occurrences AS (
    SELECT
      days_table.event_date,
      locations_table.location_group_id,
      locations_table.position AS location_position,
      locations_table.name AS location_name,
      public.normalize_bracket_entity_name(locations_table.name)
        AS logical_location_name,
      courts_table.court_group_id,
      courts_table.position AS court_position,
      courts_table.name AS court_name,
      public.normalize_bracket_entity_name(courts_table.name)
        AS logical_court_name
    FROM public.championship_bracket_days AS days_table
    JOIN public.championship_bracket_locations AS locations_table
      ON locations_table.bracket_day_id = days_table.id
    JOIN public.championship_bracket_courts AS courts_table
      ON courts_table.bracket_location_id = locations_table.id
    JOIN public.championship_bracket_court_sports AS court_sports_table
      ON court_sports_table.bracket_court_id = courts_table.id
    WHERE days_table.bracket_edition_id = _bracket_edition_id
      AND court_sports_table.sport_id = _sport_id
  ),
  logical_courts AS (
    SELECT DISTINCT ON (logical_location_name, logical_court_name)
      location_group_id,
      location_position,
      location_name,
      logical_location_name,
      court_group_id,
      court_position,
      court_name,
      logical_court_name
    FROM compatible_court_occurrences
    ORDER BY
      logical_location_name ASC,
      logical_court_name ASC,
      location_position ASC,
      court_position ASC,
      event_date ASC,
      court_group_id ASC
  ),
  ordered_courts AS (
    SELECT
      logical_courts.*,
      ROW_NUMBER() OVER (
        ORDER BY
          location_position ASC,
          court_position ASC,
          location_name ASC,
          court_name ASC,
          court_group_id ASC
      ) AS overall_order
    FROM logical_courts
  )
  SELECT court_group_id
  INTO resolved_court_group_id
  FROM ordered_courts
  WHERE overall_order = CASE
    WHEN _phase = 'SEMIFINAL'::public.bracket_knockout_priority_phase
      AND COALESCE(
        _division_scope,
        'ALL'::public.bracket_knockout_division_scope
      ) = 'DIVISAO_ACESSO'::public.bracket_knockout_division_scope
      AND EXISTS (SELECT 1 FROM ordered_courts WHERE overall_order = 2)
      THEN 2
    ELSE 1
  END
  LIMIT 1;

  RETURN resolved_court_group_id;
END;
$function$;

-- Original: update_bracket_day_schedule(_bracket_edition_id uuid, _schedule_updates jsonb)
CREATE OR REPLACE FUNCTION public.update_bracket_day_schedule(_bracket_edition_id uuid, _schedule_updates jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  championship_id_value UUID;
  schedule_update_record JSONB;
  break_record JSONB;
  bracket_day_id_value UUID;
  first_general_break_start TIME;
  first_general_break_end TIME;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para atualizar agenda do chaveamento.';
  END IF;

  SELECT bracket_editions_table.championship_id
  INTO championship_id_value
  FROM public.championship_bracket_editions AS bracket_editions_table
  JOIN public.championships AS championships_table
    ON championships_table.id = bracket_editions_table.championship_id
  WHERE bracket_editions_table.id = _bracket_edition_id
    AND championships_table.status = 'REVIEW'::public.championship_status
  LIMIT 1;

  IF championship_id_value IS NULL THEN
    RAISE EXCEPTION 'Edição de chaveamento inválida ou campeonato fora do status Em revisão.';
  END IF;

  FOR schedule_update_record IN SELECT * FROM jsonb_array_elements(_schedule_updates) LOOP
    SELECT id
    INTO bracket_day_id_value
    FROM public.championship_bracket_days
    WHERE bracket_edition_id = _bracket_edition_id
      AND event_date = (schedule_update_record->>'date')::date
    LIMIT 1;

    IF bracket_day_id_value IS NULL THEN
      RAISE EXCEPTION 'Dia % não encontrado na edição do chaveamento.', schedule_update_record->>'date';
    END IF;

    IF (schedule_update_record->>'end_time')::time <= (schedule_update_record->>'start_time')::time THEN
      RAISE EXCEPTION 'Horário de fim deve ser maior que o horário de início para o dia %.', schedule_update_record->>'date';
    END IF;

    first_general_break_start := NULL;
    first_general_break_end := NULL;

    DELETE FROM public.championship_bracket_day_breaks
    WHERE bracket_day_id = bracket_day_id_value;

    FOR break_record IN SELECT * FROM jsonb_array_elements(COALESCE(schedule_update_record->'breaks', '[]'::jsonb)) LOOP
      IF NULLIF(trim(COALESCE(break_record->>'break_start_time', '')), '') IS NULL
        OR NULLIF(trim(COALESCE(break_record->>'break_end_time', '')), '') IS NULL THEN
        RAISE EXCEPTION 'Preencha início e fim de todos os intervalos.';
      END IF;

      IF (break_record->>'break_end_time')::time <= (break_record->>'break_start_time')::time THEN
        RAISE EXCEPTION 'Fim do intervalo deve ser maior que o início.';
      END IF;

      IF (break_record->>'break_start_time')::time < (schedule_update_record->>'start_time')::time
        OR (break_record->>'break_end_time')::time > (schedule_update_record->>'end_time')::time THEN
        RAISE EXCEPTION 'Intervalos devem estar dentro da janela do dia.';
      END IF;

      IF COALESCE(break_record->>'scope_type', 'ALL_COURTS') = 'COURT'
        AND (break_record->>'bracket_court_id') IS NULL THEN
        RAISE EXCEPTION 'Selecione a quadra do intervalo específico.';
      END IF;

      IF COALESCE(break_record->>'scope_type', 'ALL_COURTS') = 'COURT'
        AND NOT EXISTS (
          SELECT 1
          FROM public.championship_bracket_courts AS courts_table
          JOIN public.championship_bracket_locations AS locations_table
            ON locations_table.id = courts_table.bracket_location_id
          WHERE courts_table.id = (break_record->>'bracket_court_id')::uuid
            AND locations_table.bracket_day_id = bracket_day_id_value
        ) THEN
        RAISE EXCEPTION 'A quadra do intervalo não pertence a este dia da agenda.';
      END IF;

      INSERT INTO public.championship_bracket_day_breaks (
        bracket_day_id,
        break_start_time,
        break_end_time,
        position,
        scope_type,
        bracket_court_id
      )
      VALUES (
        bracket_day_id_value,
        (break_record->>'break_start_time')::time,
        (break_record->>'break_end_time')::time,
        COALESCE((break_record->>'position')::integer, 1),
        COALESCE((break_record->>'scope_type')::public.bracket_day_break_scope_type, 'ALL_COURTS'::public.bracket_day_break_scope_type),
        CASE
          WHEN COALESCE(break_record->>'scope_type', 'ALL_COURTS') = 'COURT'
            THEN (break_record->>'bracket_court_id')::uuid
          ELSE NULL
        END
      );

      IF first_general_break_start IS NULL
        AND COALESCE(break_record->>'scope_type', 'ALL_COURTS') = 'ALL_COURTS' THEN
        first_general_break_start := (break_record->>'break_start_time')::time;
        first_general_break_end := (break_record->>'break_end_time')::time;
      END IF;
    END LOOP;

    UPDATE public.championship_bracket_days
    SET
      start_time = (schedule_update_record->>'start_time')::time,
      end_time = (schedule_update_record->>'end_time')::time,
      break_start_time = first_general_break_start,
      break_end_time = first_general_break_end
    WHERE id = bracket_day_id_value;
  END LOOP;

  PERFORM public.redistribute_bracket_scheduled_matches(_bracket_edition_id);
END;
$function$;
