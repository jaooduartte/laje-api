-- LAJE-150 post-merge: fill missing AWS/RDS APIs for court and location sport preferences.
-- These functions are copied from the operational PostgreSQL implementation; no data is changed by installing them.

CREATE OR REPLACE FUNCTION public.sync_bracket_global_court_preferences(_bracket_edition_id uuid, _location_group_id uuid, _sport_id uuid, _priority_mode bracket_court_priority_mode)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  naipe_options public.match_naipe[];
  division_options public.team_division[];

  naipe_option_count INTEGER;
  division_option_count INTEGER;
BEGIN
  SELECT COALESCE(
    array_agg(
      ordered_naipes_table.naipe
      ORDER BY
        ordered_naipes_table.sort_order,
        ordered_naipes_table.naipe
    ),
    ARRAY[]::public.match_naipe[]
  )
  INTO naipe_options
  FROM (
    SELECT
      matches_table.naipe,

      MIN(
        CASE matches_table.naipe
          WHEN 'FEMININO'::public.match_naipe
            THEN 1

          WHEN 'MASCULINO'::public.match_naipe
            THEN 2

          ELSE 3
        END
      ) AS sort_order

    FROM public.matches AS matches_table

    JOIN public.championship_bracket_matches
      AS bracket_matches_table
      ON bracket_matches_table.match_id =
        matches_table.id

    WHERE bracket_matches_table.bracket_edition_id =
        _bracket_edition_id

      AND matches_table.sport_id =
        _sport_id

    GROUP BY matches_table.naipe
  ) AS ordered_naipes_table;

  SELECT COALESCE(
    array_agg(
      ordered_divisions_table.division
      ORDER BY
        ordered_divisions_table.sort_order,
        ordered_divisions_table.division
    ),
    ARRAY[]::public.team_division[]
  )
  INTO division_options
  FROM (
    SELECT
      matches_table.division,

      MIN(
        CASE matches_table.division
          WHEN 'DIVISAO_PRINCIPAL'
            ::public.team_division
            THEN 1

          WHEN 'DIVISAO_ACESSO'
            ::public.team_division
            THEN 2

          ELSE 99
        END
      ) AS sort_order

    FROM public.matches AS matches_table

    JOIN public.championship_bracket_matches
      AS bracket_matches_table
      ON bracket_matches_table.match_id =
        matches_table.id

    WHERE bracket_matches_table.bracket_edition_id =
        _bracket_edition_id

      AND matches_table.sport_id =
        _sport_id

      AND matches_table.division IS NOT NULL

    GROUP BY matches_table.division
  ) AS ordered_divisions_table;

  naipe_option_count :=
    COALESCE(
      array_length(naipe_options, 1),
      0
    );

  division_option_count :=
    COALESCE(
      array_length(division_options, 1),
      0
    );

  WITH ordered_courts AS (
    SELECT
      court_sports_table.id
        AS court_sport_id,

      ROW_NUMBER() OVER (
        PARTITION BY days_table.id
        ORDER BY
          courts_table.position ASC,
          courts_table.name ASC,
          courts_table.id ASC
      ) AS day_court_order

    FROM public.championship_bracket_days
      AS days_table

    JOIN public.championship_bracket_locations
      AS locations_table
      ON locations_table.bracket_day_id =
        days_table.id

    JOIN public.championship_bracket_courts
      AS courts_table
      ON courts_table.bracket_location_id =
        locations_table.id

    JOIN public.championship_bracket_court_sports
      AS court_sports_table
      ON court_sports_table.bracket_court_id =
        courts_table.id

    WHERE days_table.bracket_edition_id =
        _bracket_edition_id

      AND locations_table.location_group_id =
        _location_group_id

      AND court_sports_table.sport_id =
        _sport_id

      AND court_sports_table.sequence_mode =
        'FLEXIBLE'
          ::public.bracket_court_sequence_mode
  )

  UPDATE public.championship_bracket_court_sports
    AS court_sports_table

  SET
    preferred_naipe = CASE
      WHEN _priority_mode =
          'NAIPE'
            ::public.bracket_court_priority_mode

        AND naipe_option_count > 0

      THEN naipe_options[
        (
          (
            ordered_courts.day_court_order - 1
          ) % naipe_option_count
        ) + 1
      ]

      ELSE NULL
    END,

    preferred_division = CASE
      WHEN _priority_mode =
          'DIVISION'
            ::public.bracket_court_priority_mode

        AND division_option_count > 0

      THEN division_options[
        (
          (
            ordered_courts.day_court_order - 1
          ) % division_option_count
        ) + 1
      ]

      ELSE NULL
    END

  FROM ordered_courts

  WHERE ordered_courts.court_sport_id =
    court_sports_table.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_bracket_court_priorities(_bracket_edition_id uuid, _court_priorities jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_championship_id UUID;
  v_item JSONB;
  v_court_id UUID;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para editar prioridades de quadras.';
  END IF;

  SELECT cbe.championship_id
  INTO v_championship_id
  FROM public.championship_bracket_editions AS cbe
  JOIN public.championships AS c ON c.id = cbe.championship_id
  WHERE cbe.id = _bracket_edition_id
    AND c.status = 'UPCOMING'::public.championship_status
  LIMIT 1;

  IF v_championship_id IS NULL THEN
    RAISE EXCEPTION 'Edição inválida ou campeonato fora do status Configurando campeonato.';
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(COALESCE(_court_priorities, '[]'::jsonb)) LOOP
    v_court_id := (v_item->>'bracket_court_id')::uuid;

    IF NOT EXISTS (
      SELECT 1
      FROM public.championship_bracket_courts AS courts_table
      JOIN public.championship_bracket_locations AS locations_table
        ON locations_table.id = courts_table.bracket_location_id
      JOIN public.championship_bracket_days AS days_table
        ON days_table.id = locations_table.bracket_day_id
      WHERE courts_table.id = v_court_id
        AND days_table.bracket_edition_id = _bracket_edition_id
    ) THEN
      RAISE EXCEPTION 'Quadra não pertence a esta edição do chaveamento.';
    END IF;

    UPDATE public.championship_bracket_court_sports
    SET
      preferred_naipe = NULLIF(trim(COALESCE(v_item->>'preferred_naipe', '')), '')::public.match_naipe,
      preferred_division = NULLIF(trim(COALESCE(v_item->>'preferred_division', '')), '')::public.team_division
    WHERE bracket_court_id = v_court_id
      AND sport_id = (v_item->>'sport_id')::uuid;
  END LOOP;

  PERFORM public.redistribute_bracket_scheduled_matches(_bracket_edition_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.update_bracket_location_sport_priorities(_bracket_edition_id uuid, _priority_updates jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  championship_id_value UUID;
  priority_update_record JSONB;
  normalized_priority_mode public.bracket_court_priority_mode;
BEGIN
  IF NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para editar prioridades globais de quadras.';
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
    normalized_priority_mode := COALESCE(
      NULLIF(trim(COALESCE(priority_update_record->>'priority_mode', '')), '')::public.bracket_court_priority_mode,
      'NONE'::public.bracket_court_priority_mode
    );

    IF NOT EXISTS (
      SELECT 1
      FROM public.championship_bracket_locations AS locations_table
      JOIN public.championship_bracket_days AS days_table
        ON days_table.id = locations_table.bracket_day_id
      WHERE days_table.bracket_edition_id = _bracket_edition_id
        AND locations_table.location_group_id = (priority_update_record->>'location_group_id')::uuid
    ) THEN
      RAISE EXCEPTION 'Local informado não pertence a esta edição do chaveamento.';
    END IF;

    INSERT INTO public.championship_bracket_location_sport_priorities (
      bracket_edition_id,
      location_group_id,
      sport_id,
      priority_mode
    )
    VALUES (
      _bracket_edition_id,
      (priority_update_record->>'location_group_id')::uuid,
      (priority_update_record->>'sport_id')::uuid,
      normalized_priority_mode
    )
    ON CONFLICT (bracket_edition_id, location_group_id, sport_id)
    DO UPDATE SET
      priority_mode = EXCLUDED.priority_mode,
      updated_at = now();

    PERFORM public.sync_bracket_global_court_preferences(
      _bracket_edition_id,
      (priority_update_record->>'location_group_id')::uuid,
      (priority_update_record->>'sport_id')::uuid,
      normalized_priority_mode
    );
  END LOOP;

  PERFORM public.redistribute_bracket_scheduled_matches(_bracket_edition_id);
END;
$function$;

