-- LAJE-150: Supabase TCC feature parity for manual tie-break resolution and bracket administration.
-- Only exact-v8 automatic qualification is enabled; legacy v7 is intentionally unsupported.

-- save_championship_bracket_tie_break_resolution(_payload jsonb)
CREATE OR REPLACE FUNCTION public.save_championship_bracket_tie_break_resolution(_payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  competition_record RECORD;
  context_record RECORD;
  team_id_record JSONB;
  team_id_value UUID;
  ordered_team_ids UUID[] := ARRAY[]::UUID[];
  sorted_signature TEXT;
  resolution_id_value UUID;
  team_position INTEGER := 0;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para salvar sorteio manual.';
  END IF;

  IF jsonb_typeof(COALESCE(_payload->'team_ids', '[]'::jsonb)) != 'array'
    OR jsonb_array_length(COALESCE(_payload->'team_ids', '[]'::jsonb)) < 2 THEN
    RAISE EXCEPTION 'Informe ao menos duas atléticas para o sorteio manual.';
  END IF;

  SELECT
    competitions_table.id,
    competitions_table.bracket_edition_id,
    editions_table.championship_id
  INTO competition_record
  FROM public.championship_bracket_competitions AS competitions_table
  JOIN public.championship_bracket_editions AS editions_table
    ON editions_table.id = competitions_table.bracket_edition_id
  WHERE competitions_table.id = (_payload->>'competition_id')::uuid
  LIMIT 1;

  IF competition_record.id IS NULL THEN
    RAISE EXCEPTION 'Competição de chaveamento não encontrada para salvar o sorteio.';
  END IF;

  FOR team_id_record IN
    SELECT value
    FROM jsonb_array_elements(COALESCE(_payload->'team_ids', '[]'::jsonb))
  LOOP
    ordered_team_ids := array_append(ordered_team_ids, trim(both '"' from team_id_record::text)::uuid);
  END LOOP;

  SELECT string_agg(ordered_team_id_value::text, '|' ORDER BY ordered_team_id_value::text)
  INTO sorted_signature
  FROM unnest(ordered_team_ids) AS ordered_team_id_value;

  SELECT contexts_table.*
  INTO context_record
  FROM public.get_championship_bracket_tie_break_contexts(
    competition_record.championship_id,
    competition_record.id,
    competition_record.bracket_edition_id
  ) AS contexts_table
  WHERE contexts_table.context_key = trim(COALESCE(_payload->>'context_key', ''))
  LIMIT 1;

  IF context_record.context_key IS NULL THEN
    RAISE EXCEPTION 'Contexto de sorteio não encontrado ou não está mais pendente.';
  END IF;

  IF context_record.tied_team_signature <> sorted_signature THEN
    RAISE EXCEPTION 'As atléticas informadas não correspondem ao empate atual deste sorteio.';
  END IF;

  INSERT INTO public.championship_bracket_tie_break_resolutions (
    bracket_edition_id,
    competition_id,
    group_id,
    context_type,
    qualification_rank,
    context_key,
    tied_team_signature,
    created_by
  ) VALUES (
    competition_record.bracket_edition_id,
    competition_record.id,
    context_record.group_id,
    context_record.context_type,
    context_record.qualification_rank,
    context_record.context_key,
    context_record.tied_team_signature,
    auth.uid()
  )
  ON CONFLICT (context_key)
  DO UPDATE SET
    tied_team_signature = EXCLUDED.tied_team_signature,
    group_id = EXCLUDED.group_id,
    qualification_rank = EXCLUDED.qualification_rank,
    updated_at = now()
  RETURNING id INTO resolution_id_value;

  DELETE FROM public.championship_bracket_tie_break_resolution_teams AS resolution_teams_table
  WHERE resolution_teams_table.resolution_id = resolution_id_value;

  FOREACH team_id_value IN ARRAY ordered_team_ids
  LOOP
    team_position := team_position + 1;

    INSERT INTO public.championship_bracket_tie_break_resolution_teams (
      resolution_id,
      team_id,
      draw_order
    ) VALUES (
      resolution_id_value,
      team_id_value,
      team_position
    );
  END LOOP;

  PERFORM public.generate_championship_knockout_for_competition(
    competition_record.championship_id,
    competition_record.id,
    competition_record.bracket_edition_id
  );

  RETURN resolution_id_value;
END;
$function$;

-- generate_championship_knockout_for_competition(_championship_id uuid, _competition_id uuid, _bracket_edition_id uuid)
CREATE OR REPLACE FUNCTION public.generate_championship_knockout_for_competition(_championship_id uuid, _competition_id uuid, _bracket_edition_id uuid DEFAULT NULL::uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  resolved_edition_id UUID;
BEGIN
  SELECT competitions_table.bracket_edition_id
  INTO resolved_edition_id
  FROM public.championship_bracket_competitions AS competitions_table
  WHERE competitions_table.id = _competition_id
    AND (_bracket_edition_id IS NULL OR competitions_table.bracket_edition_id = _bracket_edition_id)
  LIMIT 1;

  IF resolved_edition_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.championship_bracket_editions AS editions_table
      WHERE editions_table.id = resolved_edition_id
        AND editions_table.payload_snapshot ->> 'exact_preview_algorithm_version' = 'async-exact-v8'
    )
  THEN
    RETURN public.hydrate_championship_bracket_preview_v8_knockout(
      _championship_id,
      _competition_id,
      resolved_edition_id
    );
  END IF;

  RAISE EXCEPTION 'O LAJE na AWS suporta geração eliminatória somente via prévia exata v8.';
END;
$function$;

-- update_bracket_competition_settings(_competition_id uuid, _qualifiers_per_group integer, _should_complete_knockout_with_best_second_placed_teams boolean, _knockout_pairing_mode text)
CREATE OR REPLACE FUNCTION public.update_bracket_competition_settings(_competition_id uuid, _qualifiers_per_group integer, _should_complete_knockout_with_best_second_placed_teams boolean, _knockout_pairing_mode text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_edition_id UUID;
  v_sport_id UUID;
  v_naipe public.match_naipe;
  v_division public.team_division;
  v_flag BOOLEAN;
  v_knockout_pairing_mode TEXT;
  v_current_qualifiers_per_group INTEGER;
  v_current_flag BOOLEAN;
  v_current_knockout_pairing_mode TEXT;
  v_has_knockout_structure BOOLEAN;
  v_has_materialized_knockout BOOLEAN;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para editar a classificação.';
  END IF;

  IF _qualifiers_per_group NOT IN (1, 2) THEN
    RAISE EXCEPTION 'Classificados por grupo deve ser 1 ou 2.';
  END IF;

  v_knockout_pairing_mode :=
    public.resolve_championship_knockout_pairing_mode(
      _knockout_pairing_mode
    );

  v_flag := CASE
    WHEN _qualifiers_per_group = 2 THEN false
    ELSE COALESCE(
      _should_complete_knockout_with_best_second_placed_teams,
      false
    )
  END;

  SELECT
    comp.bracket_edition_id,
    comp.sport_id,
    comp.naipe,
    comp.division,
    comp.qualifiers_per_group,
    comp.should_complete_knockout_with_best_second_placed_teams,
    comp.knockout_pairing_mode
  INTO
    v_edition_id,
    v_sport_id,
    v_naipe,
    v_division,
    v_current_qualifiers_per_group,
    v_current_flag,
    v_current_knockout_pairing_mode
  FROM public.championship_bracket_competitions AS comp
  JOIN public.championship_bracket_editions AS cbe
    ON cbe.id = comp.bracket_edition_id
  JOIN public.championships AS c
    ON c.id = cbe.championship_id
  WHERE comp.id = _competition_id
    AND c.status = 'REVIEW'::public.championship_status
  LIMIT 1;

  IF v_edition_id IS NULL THEN
    RAISE EXCEPTION
      'Competição inválida ou campeonato fora do status Em revisão.';
  END IF;

  SELECT
    EXISTS (
      SELECT 1
      FROM public.championship_bracket_matches AS bracket_matches
      WHERE bracket_matches.competition_id = _competition_id
        AND bracket_matches.phase = 'KNOCKOUT'::public.bracket_phase
    ),
    EXISTS (
      SELECT 1
      FROM public.championship_bracket_matches AS bracket_matches
      WHERE bracket_matches.competition_id = _competition_id
        AND bracket_matches.phase = 'KNOCKOUT'::public.bracket_phase
        AND (
          bracket_matches.match_id IS NOT NULL
          OR bracket_matches.home_team_id IS NOT NULL
          OR bracket_matches.away_team_id IS NOT NULL
          OR bracket_matches.winner_team_id IS NOT NULL
        )
    )
  INTO
    v_has_knockout_structure,
    v_has_materialized_knockout;

  IF v_has_knockout_structure
    AND (
      _qualifiers_per_group IS DISTINCT FROM
        v_current_qualifiers_per_group
      OR v_flag IS DISTINCT FROM v_current_flag
    )
  THEN
    RAISE EXCEPTION
      'O mata-mata desta competição já foi estruturado. Não é possível alterar a quantidade de classificados.';
  END IF;

  IF v_has_materialized_knockout
    AND v_knockout_pairing_mode IS DISTINCT FROM
      v_current_knockout_pairing_mode
  THEN
    RAISE EXCEPTION
      'O mata-mata desta competição já possui confrontos materializados. Não é possível alterar o pareamento.';
  END IF;

  UPDATE public.championship_bracket_competitions
  SET
    qualifiers_per_group = _qualifiers_per_group,
    should_complete_knockout_with_best_second_placed_teams = v_flag,
    knockout_pairing_mode = v_knockout_pairing_mode
  WHERE id = _competition_id;

  UPDATE public.championship_bracket_editions AS cbe
  SET
    payload_snapshot = jsonb_set(
      cbe.payload_snapshot,
      '{competitions}',
      (
        SELECT COALESCE(
          jsonb_agg(
            CASE
              WHEN (elem->>'sport_id') = v_sport_id::text
                AND (elem->>'naipe') = v_naipe::text
                AND NULLIF(
                  trim(COALESCE(elem->>'division', '')),
                  ''
                ) IS NOT DISTINCT FROM v_division::text
              THEN elem || jsonb_build_object(
                'qualifiers_per_group',
                _qualifiers_per_group,
                'should_complete_knockout_with_best_second_placed_teams',
                v_flag,
                'knockout_pairing_mode',
                v_knockout_pairing_mode
              )
              ELSE elem
            END
          ),
          '[]'::jsonb
        )
        FROM jsonb_array_elements(
          cbe.payload_snapshot->'competitions'
        ) AS elem
      )
    ),
    updated_at = now(),
    updated_by = auth.uid()
  WHERE cbe.id = v_edition_id
    AND jsonb_typeof(
      cbe.payload_snapshot->'competitions'
    ) = 'array';
END;
$function$;

-- update_bracket_knockout_court_priorities(_bracket_edition_id uuid, _priority_updates jsonb)
CREATE OR REPLACE FUNCTION public.update_bracket_knockout_court_priorities(_bracket_edition_id uuid, _priority_updates jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  championship_id_value UUID;
  priority_update_record JSONB;
  normalized_phase public.bracket_knockout_priority_phase;
  normalized_division_scope public.bracket_knockout_division_scope;
  resolved_location_group_id UUID;
  resolved_court_group_id UUID;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para editar prioridades do mata-mata.';
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
    RAISE EXCEPTION 'Edição inválida ou campeonato fora do status Em revisão.';
  END IF;

  FOR priority_update_record IN SELECT * FROM jsonb_array_elements(COALESCE(_priority_updates, '[]'::jsonb)) LOOP
    normalized_phase := NULLIF(trim(COALESCE(priority_update_record->>'phase', '')), '')::public.bracket_knockout_priority_phase;
    normalized_division_scope := COALESCE(
      NULLIF(trim(COALESCE(priority_update_record->>'division_scope', '')), '')::public.bracket_knockout_division_scope,
      'ALL'::public.bracket_knockout_division_scope
    );
    resolved_location_group_id := NULLIF(trim(COALESCE(priority_update_record->>'location_group_id', '')), '')::uuid;
    resolved_court_group_id := NULLIF(trim(COALESCE(priority_update_record->>'court_group_id', '')), '')::uuid;

    IF normalized_phase IS NULL THEN
      RAISE EXCEPTION 'Informe a fase do mata-mata para salvar a prioridade.';
    END IF;

    IF resolved_location_group_id IS NULL OR resolved_court_group_id IS NULL THEN
      DELETE FROM public.championship_bracket_knockout_court_priorities AS priorities_table
      WHERE priorities_table.bracket_edition_id = _bracket_edition_id
        AND priorities_table.sport_id = (priority_update_record->>'sport_id')::uuid
        AND priorities_table.phase = normalized_phase
        AND priorities_table.division_scope = normalized_division_scope;

      CONTINUE;
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.championship_bracket_days AS days_table
      JOIN public.championship_bracket_locations AS locations_table
        ON locations_table.bracket_day_id = days_table.id
      JOIN public.championship_bracket_courts AS courts_table
        ON courts_table.bracket_location_id = locations_table.id
      JOIN public.championship_bracket_court_sports AS court_sports_table
        ON court_sports_table.bracket_court_id = courts_table.id
      WHERE days_table.bracket_edition_id = _bracket_edition_id
        AND locations_table.location_group_id = resolved_location_group_id
        AND courts_table.court_group_id = resolved_court_group_id
        AND court_sports_table.sport_id = (priority_update_record->>'sport_id')::uuid
    ) THEN
      RAISE EXCEPTION 'A quadra informada não pertence a esta modalidade na edição atual.';
    END IF;

    INSERT INTO public.championship_bracket_knockout_court_priorities (
      bracket_edition_id,
      sport_id,
      phase,
      division_scope,
      location_group_id,
      court_group_id
    )
    VALUES (
      _bracket_edition_id,
      (priority_update_record->>'sport_id')::uuid,
      normalized_phase,
      normalized_division_scope,
      resolved_location_group_id,
      resolved_court_group_id
    )
    ON CONFLICT (bracket_edition_id, sport_id, phase, division_scope)
    DO UPDATE SET
      location_group_id = EXCLUDED.location_group_id,
      court_group_id = EXCLUDED.court_group_id,
      updated_at = now();
  END LOOP;

  PERFORM public.redistribute_bracket_scheduled_matches(_bracket_edition_id);
END;
$function$;

-- update_bracket_generated_location_group(_bracket_edition_id uuid, _payload jsonb)
CREATE OR REPLACE FUNCTION public.update_bracket_generated_location_group(_bracket_edition_id uuid, _payload jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  championship_id_value UUID;
  championship_season_year INTEGER;
  source_location_name TEXT;
  source_court_name TEXT;
  source_court_position INTEGER;
  court_record JSONB;
BEGIN
  IF auth.uid() IS NULL
    OR NOT public.has_admin_tab_access('championship_schedule'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para editar locais e quadras da agenda.';
  END IF;

  SELECT bracket_editions_table.championship_id, bracket_editions_table.season_year
  INTO championship_id_value, championship_season_year
  FROM public.championship_bracket_editions AS bracket_editions_table
  JOIN public.championships AS championships_table
    ON championships_table.id = bracket_editions_table.championship_id
  WHERE bracket_editions_table.id = _bracket_edition_id
    AND championships_table.status = 'REVIEW'::public.championship_status
  LIMIT 1;

  IF championship_id_value IS NULL THEN
    RAISE EXCEPTION 'Edição inválida ou campeonato fora do status Em revisão.';
  END IF;

  SELECT locations_table.name
  INTO source_location_name
  FROM public.championship_bracket_locations AS locations_table
  JOIN public.championship_bracket_days AS days_table
    ON days_table.id = locations_table.bracket_day_id
  WHERE days_table.bracket_edition_id = _bracket_edition_id
    AND locations_table.location_group_id = (_payload->>'location_group_id')::uuid
  ORDER BY days_table.event_date ASC, locations_table.position ASC, locations_table.id ASC
  LIMIT 1;

  IF source_location_name IS NULL THEN
    RAISE EXCEPTION 'Local informado não pertence a esta edição do chaveamento.';
  END IF;

  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  FOR court_record IN SELECT * FROM jsonb_array_elements(COALESCE(_payload->'courts', '[]'::jsonb)) LOOP
    source_court_position := NULL;
    source_court_name := NULL;

    SELECT courts_table.position, courts_table.name
    INTO source_court_position, source_court_name
    FROM public.championship_bracket_courts AS courts_table
    JOIN public.championship_bracket_locations AS locations_table
      ON locations_table.id = courts_table.bracket_location_id
    JOIN public.championship_bracket_days AS days_table
      ON days_table.id = locations_table.bracket_day_id
    WHERE days_table.bracket_edition_id = _bracket_edition_id
      AND locations_table.location_group_id = (_payload->>'location_group_id')::uuid
      AND courts_table.court_group_id = (court_record->>'court_group_id')::uuid
    ORDER BY days_table.event_date ASC, courts_table.position ASC, courts_table.id ASC
    LIMIT 1;

    IF source_court_position IS NULL THEN
      RAISE EXCEPTION 'Quadra informada não pertence ao local desta edição do chaveamento.';
    END IF;

    UPDATE public.matches AS matches_table
    SET court_name = trim(court_record->>'court_name')
    WHERE matches_table.championship_id = championship_id_value
      AND matches_table.season_year = championship_season_year
      AND EXISTS (
        SELECT 1
        FROM public.championship_bracket_matches AS bracket_matches_table
        WHERE bracket_matches_table.match_id = matches_table.id
          AND bracket_matches_table.bracket_edition_id = _bracket_edition_id
      )
      AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(source_location_name)
      AND public.normalize_bracket_entity_name(matches_table.court_name) = public.normalize_bracket_entity_name(source_court_name)
      AND matches_table.court_name IS DISTINCT FROM trim(court_record->>'court_name');

    UPDATE public.championship_bracket_knockout_schedule_reservations AS reservations_table
    SET court_name = trim(court_record->>'court_name')
    WHERE reservations_table.bracket_edition_id = _bracket_edition_id
      AND public.normalize_bracket_entity_name(reservations_table.location_name) = public.normalize_bracket_entity_name(source_location_name)
      AND public.normalize_bracket_entity_name(reservations_table.court_name) = public.normalize_bracket_entity_name(source_court_name)
      AND reservations_table.court_name IS DISTINCT FROM trim(court_record->>'court_name');

    UPDATE public.championship_bracket_matches AS bracket_matches_table
    SET planned_court_name = trim(court_record->>'court_name')
    WHERE bracket_matches_table.bracket_edition_id = _bracket_edition_id
      AND public.normalize_bracket_entity_name(bracket_matches_table.planned_location_name) = public.normalize_bracket_entity_name(source_location_name)
      AND public.normalize_bracket_entity_name(bracket_matches_table.planned_court_name) = public.normalize_bracket_entity_name(source_court_name)
      AND bracket_matches_table.planned_court_name IS DISTINCT FROM trim(court_record->>'court_name');

    UPDATE public.championship_bracket_courts AS courts_table
    SET name = trim(court_record->>'court_name')
    FROM public.championship_bracket_locations AS locations_table
    JOIN public.championship_bracket_days AS days_table
      ON days_table.id = locations_table.bracket_day_id
    WHERE locations_table.id = courts_table.bracket_location_id
      AND days_table.bracket_edition_id = _bracket_edition_id
      AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(source_location_name)
      AND courts_table.position = source_court_position
      AND courts_table.name IS DISTINCT FROM trim(court_record->>'court_name');
  END LOOP;

  UPDATE public.matches AS matches_table
  SET location = trim(_payload->>'location_name')
  WHERE matches_table.championship_id = championship_id_value
    AND matches_table.season_year = championship_season_year
    AND EXISTS (
      SELECT 1
      FROM public.championship_bracket_matches AS bracket_matches_table
      WHERE bracket_matches_table.match_id = matches_table.id
        AND bracket_matches_table.bracket_edition_id = _bracket_edition_id
    )
    AND public.normalize_bracket_entity_name(matches_table.location) = public.normalize_bracket_entity_name(source_location_name)
    AND matches_table.location IS DISTINCT FROM trim(_payload->>'location_name');

  UPDATE public.championship_bracket_knockout_schedule_reservations AS reservations_table
  SET location_name = trim(_payload->>'location_name')
  WHERE reservations_table.bracket_edition_id = _bracket_edition_id
    AND public.normalize_bracket_entity_name(reservations_table.location_name) = public.normalize_bracket_entity_name(source_location_name)
    AND reservations_table.location_name IS DISTINCT FROM trim(_payload->>'location_name');

  UPDATE public.championship_bracket_matches AS bracket_matches_table
  SET planned_location_name = trim(_payload->>'location_name')
  WHERE bracket_matches_table.bracket_edition_id = _bracket_edition_id
    AND public.normalize_bracket_entity_name(bracket_matches_table.planned_location_name) = public.normalize_bracket_entity_name(source_location_name)
    AND bracket_matches_table.planned_location_name IS DISTINCT FROM trim(_payload->>'location_name');

  UPDATE public.championship_bracket_locations AS locations_table
  SET name = trim(_payload->>'location_name')
  FROM public.championship_bracket_days AS days_table
  WHERE days_table.id = locations_table.bracket_day_id
    AND days_table.bracket_edition_id = _bracket_edition_id
    AND public.normalize_bracket_entity_name(locations_table.name) = public.normalize_bracket_entity_name(source_location_name)
    AND locations_table.name IS DISTINCT FROM trim(_payload->>'location_name');

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  RAISE;
END;
$function$;

-- swap_championship_knockout_bracket_teams(_competition_id uuid, _team_a_id uuid, _team_b_id uuid)
CREATE OR REPLACE FUNCTION public.swap_championship_knockout_bracket_teams(_competition_id uuid, _team_a_id uuid, _team_b_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  _max_round_number INTEGER;
BEGIN
  IF _team_a_id = _team_b_id THEN
    RETURN;
  END IF;

  SELECT MAX(round_number) INTO _max_round_number
  FROM public.championship_bracket_matches
  WHERE competition_id = _competition_id
    AND phase = 'KNOCKOUT';

  IF _max_round_number IS NULL THEN
    RAISE EXCEPTION 'Competição sem mata-mata gerado.';
  END IF;

  -- Swap em championship_bracket_matches (CASE atômico, sem conflito de constraints)
  UPDATE public.championship_bracket_matches
  SET
    home_team_id = CASE
      WHEN home_team_id = _team_a_id THEN _team_b_id
      WHEN home_team_id = _team_b_id THEN _team_a_id
      ELSE home_team_id
    END,
    away_team_id = CASE
      WHEN away_team_id = _team_a_id THEN _team_b_id
      WHEN away_team_id = _team_b_id THEN _team_a_id
      ELSE away_team_id
    END
  WHERE competition_id = _competition_id
    AND phase = 'KNOCKOUT'
    AND round_number = _max_round_number
    AND (
      home_team_id IN (_team_a_id, _team_b_id)
      OR away_team_id IN (_team_a_id, _team_b_id)
    );

  -- Swap nos matches associados
  UPDATE public.matches m
  SET
    home_team_id = CASE
      WHEN m.home_team_id = _team_a_id THEN _team_b_id
      WHEN m.home_team_id = _team_b_id THEN _team_a_id
      ELSE m.home_team_id
    END,
    away_team_id = CASE
      WHEN m.away_team_id = _team_a_id THEN _team_b_id
      WHEN m.away_team_id = _team_b_id THEN _team_a_id
      ELSE m.away_team_id
    END
  FROM public.championship_bracket_matches cbm
  WHERE cbm.competition_id = _competition_id
    AND cbm.phase = 'KNOCKOUT'
    AND cbm.round_number = _max_round_number
    AND cbm.match_id = m.id
    AND (
      m.home_team_id IN (_team_a_id, _team_b_id)
      OR m.away_team_id IN (_team_a_id, _team_b_id)
    );
END;
$function$;

