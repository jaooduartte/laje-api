CREATE OR REPLACE FUNCTION
  public.sync_bracket_court_sport_preferences_base_v8(
    _bracket_edition_id UUID,
    _payload JSONB
  )
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  edition_record RECORD;
  schedule_day_record JSONB;
  location_record JSONB;
  court_record JSONB;
  resolved_bracket_court_id UUID;
  normalized_location_name TEXT;
  normalized_court_name TEXT;
  configured_sport_id UUID;
  resolved_preferred_sport_id UUID;
  resolved_preferred_naipe public.match_naipe;
  resolved_preferred_division public.team_division;
  uses_divisions BOOLEAN;
BEGIN
  SELECT
    editions_table.id,
    championships_table.uses_divisions
  INTO edition_record
  FROM public.championship_bracket_editions
    AS editions_table
  JOIN public.championships AS championships_table
    ON championships_table.id =
      editions_table.championship_id
  WHERE editions_table.id = _bracket_edition_id
  LIMIT 1;

  IF edition_record.id IS NULL THEN
    RAISE EXCEPTION
      'Edição de chaveamento inválida para sincronizar preferências de quadra.';
  END IF;

  uses_divisions := CASE
    WHEN NULLIF(
      trim(
        COALESCE(
          _payload
            -> 'season_settings'
            ->> 'division_format',
          ''
        )
      ),
      ''
    ) = 'SEPARATED'
      THEN true

    WHEN NULLIF(
      trim(
        COALESCE(
          _payload
            -> 'season_settings'
            ->> 'division_format',
          ''
        )
      ),
      ''
    ) = 'UNIFIED'
      THEN false

    ELSE COALESCE(
      edition_record.uses_divisions,
      false
    )
  END;

  UPDATE public.championship_bracket_courts
    AS courts_table
  SET preferred_sport_id = NULL
  FROM
    public.championship_bracket_locations
      AS locations_table,
    public.championship_bracket_days
      AS days_table
  WHERE locations_table.id =
      courts_table.bracket_location_id
    AND days_table.id =
      locations_table.bracket_day_id
    AND days_table.bracket_edition_id =
      _bracket_edition_id;

  UPDATE public.championship_bracket_court_sports
    AS court_sports_table
  SET
    preferred_naipe = NULL,
    preferred_division = NULL
  FROM
    public.championship_bracket_courts
      AS courts_table,
    public.championship_bracket_locations
      AS locations_table,
    public.championship_bracket_days
      AS days_table
  WHERE courts_table.id =
      court_sports_table.bracket_court_id
    AND locations_table.id =
      courts_table.bracket_location_id
    AND days_table.id =
      locations_table.bracket_day_id
    AND days_table.bracket_edition_id =
      _bracket_edition_id;

  FOR schedule_day_record IN
    SELECT value
    FROM jsonb_array_elements(
      CASE
        WHEN jsonb_typeof(
          _payload -> 'schedule_days'
        ) = 'array'
          THEN _payload -> 'schedule_days'
        ELSE '[]'::jsonb
      END
    )
  LOOP
    FOR location_record IN
      SELECT value
      FROM jsonb_array_elements(
        CASE
          WHEN jsonb_typeof(
            schedule_day_record -> 'locations'
          ) = 'array'
            THEN schedule_day_record -> 'locations'
          ELSE '[]'::jsonb
        END
      )
    LOOP
      normalized_location_name := NULLIF(
        trim(
          COALESCE(
            location_record ->> 'name',
            ''
          )
        ),
        ''
      );

      FOR court_record IN
        SELECT value
        FROM jsonb_array_elements(
          CASE
            WHEN jsonb_typeof(
              location_record -> 'courts'
            ) = 'array'
              THEN location_record -> 'courts'
            ELSE '[]'::jsonb
          END
        )
      LOOP
        normalized_court_name := NULLIF(
          trim(
            COALESCE(
              court_record ->> 'name',
              ''
            )
          ),
          ''
        );

        SELECT courts_table.id
        INTO resolved_bracket_court_id
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
        WHERE days_table.bracket_edition_id =
            _bracket_edition_id
          AND days_table.event_date =
            (
              schedule_day_record ->> 'date'
            )::date
          AND public.normalize_bracket_entity_name(
            locations_table.name
          ) =
            public.normalize_bracket_entity_name(
              normalized_location_name
            )
          AND public.normalize_bracket_entity_name(
            courts_table.name
          ) =
            public.normalize_bracket_entity_name(
              normalized_court_name
            )
        LIMIT 1;

        IF resolved_bracket_court_id IS NULL THEN
          RAISE EXCEPTION
            'Não foi possível localizar a quadra % • % em % para sincronizar a preferência.',
            normalized_location_name,
            normalized_court_name,
            schedule_day_record ->> 'date';
        END IF;

        resolved_preferred_sport_id := CASE
          WHEN jsonb_typeof(
            court_record -> 'sport_preference'
          ) = 'object'
            AND NULLIF(
              trim(
                COALESCE(
                  court_record
                    -> 'sport_preference'
                    ->> 'preferred_sport_id',
                  ''
                )
              ),
              ''
            ) IS NOT NULL
          THEN (
            court_record
              -> 'sport_preference'
              ->> 'preferred_sport_id'
          )::uuid
          ELSE NULL
        END;

        resolved_preferred_naipe := CASE
          WHEN resolved_preferred_sport_id
            IS NOT NULL
            AND NULLIF(
              trim(
                COALESCE(
                  court_record
                    -> 'sport_preference'
                    ->> 'preferred_naipe',
                  ''
                )
              ),
              ''
            ) IS NOT NULL
          THEN (
            court_record
              -> 'sport_preference'
              ->> 'preferred_naipe'
          )::public.match_naipe
          ELSE NULL
        END;

        resolved_preferred_division := CASE
          WHEN uses_divisions
            AND resolved_preferred_sport_id
              IS NOT NULL
            AND NULLIF(
              trim(
                COALESCE(
                  court_record
                    -> 'sport_preference'
                    ->> 'preferred_division',
                  ''
                )
              ),
              ''
            ) IS NOT NULL
          THEN (
            court_record
              -> 'sport_preference'
              ->> 'preferred_division'
          )::public.team_division
          ELSE NULL
        END;

        IF resolved_preferred_sport_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM jsonb_array_elements_text(
              CASE
                WHEN jsonb_typeof(
                  court_record -> 'sport_ids'
                ) = 'array'
                  THEN court_record -> 'sport_ids'
                ELSE '[]'::jsonb
              END
            ) AS configured_sport(value)
            WHERE configured_sport.value::uuid =
              resolved_preferred_sport_id
          )
        THEN
          RAISE EXCEPTION
            'A modalidade preferencial da quadra % não está vinculada à quadra.',
            normalized_court_name;
        END IF;

        IF resolved_preferred_sport_id IS NOT NULL
          AND NOT EXISTS (
            SELECT 1
            FROM
              public.championship_bracket_competitions
                AS competitions_table
            WHERE competitions_table
                .bracket_edition_id =
                  _bracket_edition_id
              AND competitions_table.sport_id =
                resolved_preferred_sport_id
              AND (
                resolved_preferred_naipe IS NULL
                OR competitions_table.naipe =
                  resolved_preferred_naipe
              )
              AND (
                resolved_preferred_division IS NULL
                OR competitions_table.division =
                  resolved_preferred_division
              )
          )
        THEN
          RAISE EXCEPTION
            'A preferência configurada para a quadra % não possui competição ativa correspondente.',
            normalized_court_name;
        END IF;

        UPDATE public.championship_bracket_courts
          AS courts_table
        SET
          preferred_sport_id =
            resolved_preferred_sport_id
        WHERE courts_table.id =
          resolved_bracket_court_id;

        DELETE FROM
          public.championship_bracket_court_sports
            AS court_sports_table
        WHERE court_sports_table.bracket_court_id =
            resolved_bracket_court_id
          AND NOT EXISTS (
            SELECT 1
            FROM jsonb_array_elements_text(
              CASE
                WHEN jsonb_typeof(
                  court_record -> 'sport_ids'
                ) = 'array'
                  THEN court_record -> 'sport_ids'
                ELSE '[]'::jsonb
              END
            ) AS configured_sport(value)
            WHERE configured_sport.value::uuid =
              court_sports_table.sport_id
          );

        FOR configured_sport_id IN
          SELECT configured_sport.value::uuid
          FROM jsonb_array_elements_text(
            CASE
              WHEN jsonb_typeof(
                court_record -> 'sport_ids'
              ) = 'array'
                THEN court_record -> 'sport_ids'
              ELSE '[]'::jsonb
            END
          ) AS configured_sport(value)
        LOOP
          INSERT INTO
            public.championship_bracket_court_sports (
              bracket_court_id,
              sport_id,
              preferred_naipe,
              preferred_division
            )
          VALUES (
            resolved_bracket_court_id,
            configured_sport_id,

            CASE
              WHEN configured_sport_id =
                resolved_preferred_sport_id
              THEN resolved_preferred_naipe
              ELSE NULL
            END,

            CASE
              WHEN configured_sport_id =
                resolved_preferred_sport_id
              THEN resolved_preferred_division
              ELSE NULL
            END
          )
          ON CONFLICT ON CONSTRAINT
            championship_bracket_court_sports_upsert_unique
          DO UPDATE SET
            preferred_naipe =
              EXCLUDED.preferred_naipe,
            preferred_division =
              EXCLUDED.preferred_division;
        END LOOP;
      END LOOP;
    END LOOP;
  END LOOP;
END;
$function$;


REVOKE ALL ON FUNCTION public.sync_bracket_court_sport_preferences_base_v8(UUID, JSONB) FROM PUBLIC;

DO $migration$
DECLARE
  current_function_definition TEXT;
  old_helper_call TEXT := 'sync_championship_bracket_court_sport_preferences_before_structure_fix_v8(';
  new_helper_call TEXT := 'sync_bracket_court_sport_preferences_base_v8(';
BEGIN
  SELECT pg_get_functiondef(
    'public.sync_championship_bracket_court_sport_preferences(uuid,jsonb)'::regprocedure
  )
  INTO current_function_definition;

  IF strpos(current_function_definition, old_helper_call) > 0 THEN
    EXECUTE replace(
      current_function_definition,
      old_helper_call,
      new_helper_call
    );
  ELSIF strpos(current_function_definition, new_helper_call) = 0 THEN
    RAISE EXCEPTION 'The court preference synchronization function has an unexpected helper call.';
  END IF;
END;
$migration$;

NOTIFY pgrst, 'reload schema';
