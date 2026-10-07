-- LAJE-126: helpers públicos determinísticos usados pelo motor exato v8.
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.combine_bracket_schedule_timestamp(_event_date date, _event_time time without time zone)
 RETURNS timestamp with time zone
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT make_timestamptz(
    EXTRACT(YEAR FROM _event_date)::integer,
    EXTRACT(MONTH FROM _event_date)::integer,
    EXTRACT(DAY FROM _event_date)::integer,
    EXTRACT(HOUR FROM _event_time)::integer,
    EXTRACT(MINUTE FROM _event_time)::integer,
    FLOOR(EXTRACT(SECOND FROM _event_time))::integer,
    'America/Sao_Paulo'
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_championship_bracket_competition_slot_playable(_payload jsonb, _competition_key text, _event_date date, _slot_start_at timestamp with time zone, _slot_end_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  availability_record JSONB;
  day_bounds RECORD;
  availability_mode TEXT;
BEGIN
  SELECT *
  INTO day_bounds
  FROM public.resolve_championship_bracket_schedule_day_bounds(
    _payload,
    _event_date
  )
  LIMIT 1;


  IF day_bounds.day_start_at IS NULL
    OR day_bounds.day_end_at IS NULL
  THEN
    RETURN false;
  END IF;


  IF to_regclass('pg_temp.temp_competition_date_availability_modes') IS NOT NULL THEN
    SELECT
      availability_modes_table.mode
    INTO availability_mode
    FROM pg_temp.temp_competition_date_availability_modes
      AS availability_modes_table
    WHERE availability_modes_table.competition_key = _competition_key
      AND availability_modes_table.event_date = _event_date
    LIMIT 1;

    IF availability_mode IS NOT NULL THEN
      CASE availability_mode
        WHEN 'UNAVAILABLE' THEN
          RETURN false;

        WHEN 'FULL_DAY' THEN
          RETURN
            _slot_start_at >= day_bounds.day_start_at
            AND _slot_start_at < day_bounds.day_end_at;

        WHEN 'CUSTOM' THEN
          RETURN EXISTS (
            SELECT 1
            FROM pg_temp.temp_competition_date_availability_windows
              AS availability_windows_table
            WHERE availability_windows_table.competition_key = _competition_key
              AND availability_windows_table.event_date = _event_date
              AND _slot_start_at >= availability_windows_table.window_start_at
              AND _slot_end_at <= availability_windows_table.window_end_at
          );

        ELSE
          RETURN false;
      END CASE;
    END IF;

    RETURN EXISTS (
      SELECT 1
      FROM public.resolve_championship_bracket_competition_schedule_windows(
        _payload,
        _competition_key,
        _event_date
      ) AS availability_windows
      WHERE _slot_start_at >= availability_windows.window_start_at
        AND _slot_end_at <= availability_windows.window_end_at
    );
  END IF;


  SELECT
    availability_item.value
  INTO availability_record
  FROM jsonb_array_elements(
    COALESCE(
      _payload -> 'competition_date_availability',
      '[]'::jsonb
    )
  ) AS availability_item(value)
  WHERE availability_item.value ->> 'competition_key' =
      _competition_key

    AND NULLIF(
      availability_item.value ->> 'date',
      ''
    )::date =
      _event_date
  LIMIT 1;


  IF availability_record IS NOT NULL THEN
    CASE COALESCE(
      availability_record ->> 'mode',
      'FULL_DAY'
    )
      WHEN 'UNAVAILABLE' THEN
        RETURN false;

      WHEN 'FULL_DAY' THEN
        RETURN
          _slot_start_at >= day_bounds.day_start_at
          AND _slot_start_at < day_bounds.day_end_at;

      WHEN 'CUSTOM' THEN
        RETURN EXISTS (
          SELECT 1
          FROM public.resolve_championship_bracket_competition_schedule_windows(
            _payload,
            _competition_key,
            _event_date
          ) AS availability_windows
          WHERE _slot_start_at >= availability_windows.window_start_at
            AND _slot_end_at <= availability_windows.window_end_at
        );

      ELSE
        RETURN false;
    END CASE;
  END IF;


  RETURN EXISTS (
    SELECT 1
    FROM public.resolve_championship_bracket_competition_schedule_windows(
      _payload,
      _competition_key,
      _event_date
    ) AS availability_windows
    WHERE _slot_start_at >= availability_windows.window_start_at
      AND _slot_end_at <= availability_windows.window_end_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_championship_bracket_team_slot_playable(_payload jsonb, _team_id uuid, _competition_key text, _event_date date, _slot_start_at timestamp with time zone, _slot_end_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  availability_record JSONB;
  day_bounds RECORD;
  availability_mode TEXT;
BEGIN
  SELECT *
  INTO day_bounds
  FROM public.resolve_championship_bracket_schedule_day_bounds(
    _payload,
    _event_date
  )
  LIMIT 1;


  IF day_bounds.day_start_at IS NULL
    OR day_bounds.day_end_at IS NULL
  THEN
    RETURN false;
  END IF;


  IF to_regclass('pg_temp.temp_team_competition_date_availability_modes') IS NOT NULL THEN
    SELECT
      availability_modes_table.mode
    INTO availability_mode
    FROM pg_temp.temp_team_competition_date_availability_modes
      AS availability_modes_table
    WHERE availability_modes_table.team_id = _team_id
      AND availability_modes_table.competition_key = _competition_key
      AND availability_modes_table.event_date = _event_date
    LIMIT 1;

    IF availability_mode IS NOT NULL THEN
      CASE availability_mode
        WHEN 'UNAVAILABLE' THEN
          RETURN false;

        WHEN 'FULL_DAY' THEN
          RETURN
            _slot_start_at >= day_bounds.day_start_at
            AND _slot_start_at < day_bounds.day_end_at;

        WHEN 'CUSTOM' THEN
          RETURN EXISTS (
            SELECT 1
            FROM pg_temp.temp_team_competition_date_availability_windows
              AS availability_windows_table
            WHERE availability_windows_table.team_id = _team_id
              AND availability_windows_table.competition_key = _competition_key
              AND availability_windows_table.event_date = _event_date
              AND _slot_start_at >= availability_windows_table.window_start_at
              AND _slot_end_at <= availability_windows_table.window_end_at
          );

        ELSE
          RETURN false;
      END CASE;
    END IF;

    RETURN EXISTS (
      SELECT 1
      FROM public.resolve_championship_bracket_team_schedule_windows(
        _payload,
        _team_id,
        _competition_key,
        _event_date
      ) AS availability_windows
      WHERE _slot_start_at >= availability_windows.window_start_at
        AND _slot_end_at <= availability_windows.window_end_at
    );
  END IF;


  SELECT
    availability_item.value
  INTO availability_record
  FROM jsonb_array_elements(
    COALESCE(
      _payload -> 'team_competition_date_availability',
      '[]'::jsonb
    )
  ) AS availability_item(value)
  WHERE NULLIF(
      availability_item.value ->> 'team_id',
      ''
    )::uuid =
      _team_id

    AND availability_item.value ->> 'competition_key' =
      _competition_key

    AND NULLIF(
      availability_item.value ->> 'date',
      ''
    )::date =
      _event_date
  LIMIT 1;


  IF availability_record IS NOT NULL THEN
    CASE COALESCE(
      availability_record ->> 'mode',
      'FULL_DAY'
    )
      WHEN 'UNAVAILABLE' THEN
        RETURN false;

      WHEN 'FULL_DAY' THEN
        RETURN
          _slot_start_at >= day_bounds.day_start_at
          AND _slot_start_at < day_bounds.day_end_at;

      WHEN 'CUSTOM' THEN
        RETURN EXISTS (
          SELECT 1
          FROM public.resolve_championship_bracket_team_schedule_windows(
            _payload,
            _team_id,
            _competition_key,
            _event_date
          ) AS availability_windows
          WHERE _slot_start_at >= availability_windows.window_start_at
            AND _slot_end_at <= availability_windows.window_end_at
        );

      ELSE
        RETURN false;
    END CASE;
  END IF;


  RETURN EXISTS (
    SELECT 1
    FROM public.resolve_championship_bracket_team_schedule_windows(
      _payload,
      _team_id,
      _competition_key,
      _event_date
    ) AS availability_windows
    WHERE _slot_start_at >= availability_windows.window_start_at
      AND _slot_end_at <= availability_windows.window_end_at
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.is_competition_period_enabled_by_payload(_payload jsonb, _competition_key text, _event_date date, _period championship_schedule_period)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (
      SELECT (item.value->>'enabled')::boolean
      FROM jsonb_array_elements(COALESCE(_payload->'competition_period_availability', '[]'::jsonb)) AS item(value)
      WHERE item.value->>'competition_key' = _competition_key
        AND (item.value->>'date')::date = _event_date
        AND item.value->>'period' = _period::text
      LIMIT 1
    ),
    true
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_schedule_period_enabled_by_payload(_payload jsonb, _event_date date, _period championship_schedule_period)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (
      SELECT (item.value->>'enabled')::boolean
      FROM jsonb_array_elements(COALESCE(_payload->'schedule_periods', '[]'::jsonb)) AS item(value)
      WHERE (item.value->>'date')::date = _event_date
        AND item.value->>'period' = _period::text
      LIMIT 1
    ),
    true
  );
$function$;

CREATE OR REPLACE FUNCTION public.is_team_competition_period_enabled_by_payload(_payload jsonb, _team_id uuid, _competition_key text, _event_date date, _period championship_schedule_period)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (
      SELECT (item.value->>'enabled')::boolean
      FROM jsonb_array_elements(COALESCE(_payload->'team_competition_availability', '[]'::jsonb)) AS item(value)
      WHERE (item.value->>'team_id')::uuid = _team_id
        AND item.value->>'competition_key' = _competition_key
        AND (item.value->>'date')::date = _event_date
        AND item.value->>'period' = _period::text
      LIMIT 1
    ),
    true
  );
$function$;

CREATE OR REPLACE FUNCTION public.resolve_bracket_schedule_period_bounds_from_payload(_payload jsonb, _event_date date, _period championship_schedule_period)
 RETURNS TABLE(period_start_at timestamp with time zone, period_end_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  day_bounds RECORD;
  day_middle_at TIMESTAMPTZ;
BEGIN
  SELECT *
  INTO day_bounds
  FROM public.resolve_championship_bracket_schedule_day_bounds(
    _payload,
    _event_date
  )
  LIMIT 1;


  IF day_bounds.day_start_at IS NULL
    OR day_bounds.day_end_at IS NULL
  THEN
    RETURN;
  END IF;


  day_middle_at :=
    day_bounds.day_start_at
    + (
      (
        day_bounds.day_end_at
        - day_bounds.day_start_at
      ) / 2.0
    );


  IF _period =
    'MATUTINO'::public.championship_schedule_period
  THEN
    period_start_at :=
      day_bounds.day_start_at;

    period_end_at :=
      CASE
        WHEN day_bounds.break_start_time IS NOT NULL
          AND day_bounds.break_start_time >
            day_bounds.day_start_time
        THEN
          public.combine_bracket_schedule_timestamp(
            _event_date,
            day_bounds.break_start_time
          )

        ELSE
          day_middle_at
      END;
  ELSE
    period_start_at :=
      CASE
        WHEN day_bounds.break_end_time IS NOT NULL
          AND day_bounds.break_end_time <
            day_bounds.day_end_time
        THEN
          public.combine_bracket_schedule_timestamp(
            _event_date,
            day_bounds.break_end_time
          )

        ELSE
          day_middle_at
      END;

    period_end_at :=
      day_bounds.day_end_at;
  END IF;


  IF period_start_at >= period_end_at THEN
    RETURN;
  END IF;


  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_championship_bracket_competition_schedule_windows(_payload jsonb, _competition_key text, _event_date date)
 RETURNS TABLE(window_start_at timestamp with time zone, window_end_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  availability_record JSONB;
  window_record JSONB;
  legacy_period public.championship_schedule_period;

  day_bounds RECORD;

  availability_mode TEXT;

  previous_window_end_at TIMESTAMPTZ;
BEGIN
  SELECT *
  INTO day_bounds
  FROM public.resolve_championship_bracket_schedule_day_bounds(
    _payload,
    _event_date
  )
  LIMIT 1;


  IF day_bounds.day_start_at IS NULL
    OR day_bounds.day_end_at IS NULL
  THEN
    RETURN;
  END IF;


  IF to_regclass('pg_temp.temp_competition_date_availability_modes') IS NOT NULL THEN
    SELECT
      availability_modes_table.mode
    INTO availability_mode
    FROM pg_temp.temp_competition_date_availability_modes
      AS availability_modes_table
    WHERE availability_modes_table.competition_key = _competition_key
      AND availability_modes_table.event_date = _event_date
    LIMIT 1;

    IF availability_mode IS NOT NULL THEN
      IF availability_mode = 'UNAVAILABLE' THEN
        RETURN;
      END IF;

      IF availability_mode NOT IN ('FULL_DAY', 'CUSTOM') THEN
        RETURN;
      END IF;

      RETURN QUERY
      SELECT
        availability_windows_table.window_start_at,
        availability_windows_table.window_end_at
      FROM pg_temp.temp_competition_date_availability_windows
        AS availability_windows_table
      WHERE availability_windows_table.competition_key = _competition_key
        AND availability_windows_table.event_date = _event_date
      ORDER BY
        availability_windows_table.window_start_at ASC,
        availability_windows_table.window_end_at ASC;

      RETURN;
    END IF;

    FOR legacy_period IN
      SELECT
        'MATUTINO'::public.championship_schedule_period
      UNION ALL
      SELECT
        'VESPERTINO'::public.championship_schedule_period
    LOOP
      IF NOT public.is_schedule_period_enabled_by_payload(
        _payload,
        _event_date,
        legacy_period
      )
      THEN
        CONTINUE;
      END IF;

      IF NOT public.is_competition_period_enabled_by_payload(
        _payload,
        _competition_key,
        _event_date,
        legacy_period
      )
      THEN
        CONTINUE;
      END IF;

      RETURN QUERY
      SELECT
        period_bounds.period_start_at,
        period_bounds.period_end_at
      FROM public.resolve_bracket_schedule_period_bounds_from_payload(
        _payload,
        _event_date,
        legacy_period
      ) AS period_bounds;
    END LOOP;

    RETURN;
  END IF;


  SELECT
    availability_item.value
  INTO availability_record
  FROM jsonb_array_elements(
    COALESCE(
      _payload -> 'competition_date_availability',
      '[]'::jsonb
    )
  ) AS availability_item(value)
  WHERE availability_item.value ->> 'competition_key' =
      _competition_key

    AND NULLIF(
      availability_item.value ->> 'date',
      ''
    )::date =
      _event_date
  LIMIT 1;


  IF availability_record IS NOT NULL THEN
    availability_mode :=
      COALESCE(
        availability_record ->> 'mode',
        'FULL_DAY'
      );

    IF availability_mode = 'UNAVAILABLE' THEN
      RETURN;
    END IF;

    IF availability_mode = 'FULL_DAY' THEN
      window_start_at := day_bounds.day_start_at;
      window_end_at := day_bounds.day_end_at;
      RETURN NEXT;
      RETURN;
    END IF;

    IF availability_mode <> 'CUSTOM' THEN
      RETURN;
    END IF;

    previous_window_end_at := NULL;

    FOR window_record IN
      SELECT
        window_item.value
      FROM jsonb_array_elements(
        COALESCE(
          availability_record -> 'windows',
          '[]'::jsonb
        )
      ) AS window_item(value)
      ORDER BY
        COALESCE(
          window_item.value ->> 'start_time',
          ''
        ) ASC,
        COALESCE(
          window_item.value ->> 'end_time',
          ''
        ) ASC
    LOOP
      IF NULLIF(
          window_record ->> 'start_time',
          ''
        ) IS NULL
        OR NULLIF(
          window_record ->> 'end_time',
          ''
        ) IS NULL
      THEN
        RETURN;
      END IF;

      window_start_at :=
        public.combine_bracket_schedule_timestamp(
          _event_date,
          (window_record ->> 'start_time')::time
        );

      window_end_at :=
        public.combine_bracket_schedule_timestamp(
          _event_date,
          (window_record ->> 'end_time')::time
        );

      IF window_end_at <= window_start_at
        OR window_start_at < day_bounds.day_start_at
        OR window_end_at > day_bounds.day_end_at
      THEN
        RETURN;
      END IF;

      IF previous_window_end_at IS NOT NULL
        AND window_start_at < previous_window_end_at
      THEN
        RETURN;
      END IF;

      previous_window_end_at := window_end_at;
      RETURN NEXT;
    END LOOP;

    RETURN;
  END IF;


  FOR legacy_period IN
    SELECT
      'MATUTINO'::public.championship_schedule_period
    UNION ALL
    SELECT
      'VESPERTINO'::public.championship_schedule_period
  LOOP
    IF NOT public.is_schedule_period_enabled_by_payload(
      _payload,
      _event_date,
      legacy_period
    )
    THEN
      CONTINUE;
    END IF;

    IF NOT public.is_competition_period_enabled_by_payload(
      _payload,
      _competition_key,
      _event_date,
      legacy_period
    )
    THEN
      CONTINUE;
    END IF;

    RETURN QUERY
    SELECT
      period_bounds.period_start_at,
      period_bounds.period_end_at
    FROM public.resolve_bracket_schedule_period_bounds_from_payload(
      _payload,
      _event_date,
      legacy_period
    ) AS period_bounds;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_championship_bracket_schedule_day_bounds(_payload jsonb, _event_date date)
 RETURNS TABLE(day_start_at timestamp with time zone, day_end_at timestamp with time zone, day_start_time time without time zone, day_end_time time without time zone, break_start_time time without time zone, break_end_time time without time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  schedule_day_record JSONB;
BEGIN
  IF to_regclass('pg_temp.temp_schedule_day_bounds') IS NOT NULL THEN
    SELECT
      day_bounds_table.day_start_at,
      day_bounds_table.day_end_at,
      day_bounds_table.day_start_time,
      day_bounds_table.day_end_time,
      day_bounds_table.break_start_time,
      day_bounds_table.break_end_time
    INTO
      day_start_at,
      day_end_at,
      day_start_time,
      day_end_time,
      break_start_time,
      break_end_time
    FROM pg_temp.temp_schedule_day_bounds AS day_bounds_table
    WHERE day_bounds_table.event_date = _event_date
    LIMIT 1;

    IF day_start_at IS NOT NULL
      AND day_end_at IS NOT NULL
    THEN
      RETURN NEXT;
    END IF;

    RETURN;
  END IF;


  SELECT
    schedule_day_item.value
  INTO schedule_day_record
  FROM jsonb_array_elements(
    COALESCE(
      _payload -> 'schedule_days',
      '[]'::jsonb
    )
  ) AS schedule_day_item(value)
  WHERE NULLIF(
      schedule_day_item.value ->> 'date',
      ''
    )::date =
      _event_date
  LIMIT 1;


  IF schedule_day_record IS NULL THEN
    RETURN;
  END IF;


  day_start_time :=
    NULLIF(
      schedule_day_record ->> 'start_time',
      ''
    )::time;

  day_end_time :=
    NULLIF(
      schedule_day_record ->> 'end_time',
      ''
    )::time;

  break_start_time :=
    NULLIF(
      schedule_day_record ->> 'break_start_time',
      ''
    )::time;

  break_end_time :=
    NULLIF(
      schedule_day_record ->> 'break_end_time',
      ''
    )::time;


  IF day_start_time IS NULL
    OR day_end_time IS NULL
    OR day_end_time <= day_start_time
  THEN
    RETURN;
  END IF;


  day_start_at :=
    public.combine_bracket_schedule_timestamp(
      _event_date,
      day_start_time
    );

  day_end_at :=
    public.combine_bracket_schedule_timestamp(
      _event_date,
      day_end_time
    );


  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_championship_bracket_team_schedule_windows(_payload jsonb, _team_id uuid, _competition_key text, _event_date date)
 RETURNS TABLE(window_start_at timestamp with time zone, window_end_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  availability_record JSONB;
  window_record JSONB;
  legacy_period public.championship_schedule_period;

  day_bounds RECORD;

  availability_mode TEXT;

  previous_window_end_at TIMESTAMPTZ;
BEGIN
  SELECT *
  INTO day_bounds
  FROM public.resolve_championship_bracket_schedule_day_bounds(
    _payload,
    _event_date
  )
  LIMIT 1;


  IF day_bounds.day_start_at IS NULL
    OR day_bounds.day_end_at IS NULL
  THEN
    RETURN;
  END IF;


  IF to_regclass('pg_temp.temp_team_competition_date_availability_modes') IS NOT NULL THEN
    SELECT
      availability_modes_table.mode
    INTO availability_mode
    FROM pg_temp.temp_team_competition_date_availability_modes
      AS availability_modes_table
    WHERE availability_modes_table.team_id = _team_id
      AND availability_modes_table.competition_key = _competition_key
      AND availability_modes_table.event_date = _event_date
    LIMIT 1;

    IF availability_mode IS NOT NULL THEN
      IF availability_mode = 'UNAVAILABLE' THEN
        RETURN;
      END IF;

      IF availability_mode NOT IN ('FULL_DAY', 'CUSTOM') THEN
        RETURN;
      END IF;

      RETURN QUERY
      SELECT
        availability_windows_table.window_start_at,
        availability_windows_table.window_end_at
      FROM pg_temp.temp_team_competition_date_availability_windows
        AS availability_windows_table
      WHERE availability_windows_table.team_id = _team_id
        AND availability_windows_table.competition_key = _competition_key
        AND availability_windows_table.event_date = _event_date
      ORDER BY
        availability_windows_table.window_start_at ASC,
        availability_windows_table.window_end_at ASC;

      RETURN;
    END IF;

    FOR legacy_period IN
      SELECT
        'MATUTINO'::public.championship_schedule_period
      UNION ALL
      SELECT
        'VESPERTINO'::public.championship_schedule_period
    LOOP
      IF NOT public.is_schedule_period_enabled_by_payload(
        _payload,
        _event_date,
        legacy_period
      )
      THEN
        CONTINUE;
      END IF;

      IF NOT public.is_team_competition_period_enabled_by_payload(
        _payload,
        _team_id,
        _competition_key,
        _event_date,
        legacy_period
      )
      THEN
        CONTINUE;
      END IF;

      RETURN QUERY
      SELECT
        period_bounds.period_start_at,
        period_bounds.period_end_at
      FROM public.resolve_bracket_schedule_period_bounds_from_payload(
        _payload,
        _event_date,
        legacy_period
      ) AS period_bounds;
    END LOOP;

    RETURN;
  END IF;


  SELECT
    availability_item.value
  INTO availability_record
  FROM jsonb_array_elements(
    COALESCE(
      _payload -> 'team_competition_date_availability',
      '[]'::jsonb
    )
  ) AS availability_item(value)
  WHERE NULLIF(
      availability_item.value ->> 'team_id',
      ''
    )::uuid =
      _team_id

    AND availability_item.value ->> 'competition_key' =
      _competition_key

    AND NULLIF(
      availability_item.value ->> 'date',
      ''
    )::date =
      _event_date
  LIMIT 1;


  IF availability_record IS NOT NULL THEN
    availability_mode :=
      COALESCE(
        availability_record ->> 'mode',
        'FULL_DAY'
      );

    IF availability_mode = 'UNAVAILABLE' THEN
      RETURN;
    END IF;

    IF availability_mode = 'FULL_DAY' THEN
      window_start_at := day_bounds.day_start_at;
      window_end_at := day_bounds.day_end_at;
      RETURN NEXT;
      RETURN;
    END IF;

    IF availability_mode <> 'CUSTOM' THEN
      RETURN;
    END IF;

    previous_window_end_at := NULL;

    FOR window_record IN
      SELECT
        window_item.value
      FROM jsonb_array_elements(
        COALESCE(
          availability_record -> 'windows',
          '[]'::jsonb
        )
      ) AS window_item(value)
      ORDER BY
        COALESCE(
          window_item.value ->> 'start_time',
          ''
        ) ASC,
        COALESCE(
          window_item.value ->> 'end_time',
          ''
        ) ASC
    LOOP
      IF NULLIF(
          window_record ->> 'start_time',
          ''
        ) IS NULL
        OR NULLIF(
          window_record ->> 'end_time',
          ''
        ) IS NULL
      THEN
        RETURN;
      END IF;

      window_start_at :=
        public.combine_bracket_schedule_timestamp(
          _event_date,
          (window_record ->> 'start_time')::time
        );

      window_end_at :=
        public.combine_bracket_schedule_timestamp(
          _event_date,
          (window_record ->> 'end_time')::time
        );

      IF window_end_at <= window_start_at
        OR window_start_at < day_bounds.day_start_at
        OR window_end_at > day_bounds.day_end_at
      THEN
        RETURN;
      END IF;

      IF previous_window_end_at IS NOT NULL
        AND window_start_at < previous_window_end_at
      THEN
        RETURN;
      END IF;

      previous_window_end_at := window_end_at;
      RETURN NEXT;
    END LOOP;

    RETURN;
  END IF;


  FOR legacy_period IN
    SELECT
      'MATUTINO'::public.championship_schedule_period
    UNION ALL
    SELECT
      'VESPERTINO'::public.championship_schedule_period
  LOOP
    IF NOT public.is_schedule_period_enabled_by_payload(
      _payload,
      _event_date,
      legacy_period
    )
    THEN
      CONTINUE;
    END IF;

    IF NOT public.is_team_competition_period_enabled_by_payload(
      _payload,
      _team_id,
      _competition_key,
      _event_date,
      legacy_period
    )
    THEN
      CONTINUE;
    END IF;

    RETURN QUERY
    SELECT
      period_bounds.period_start_at,
      period_bounds.period_end_at
    FROM public.resolve_bracket_schedule_period_bounds_from_payload(
      _payload,
      _event_date,
      legacy_period
    ) AS period_bounds;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_championship_knockout_pairing_mode(_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN upper(trim(COALESCE(_value, ''))) IN (
      'LINEAR',
      'RANKING_ALTERNATING',
      'CLASSIC_SEEDED'
    )
      THEN upper(trim(_value))
    WHEN upper(trim(COALESCE(_value, ''))) IN (
      'FUTEVOLEI_FEM_INVERTED',
      'BEACH_SOCCER_FEM_DIRECT_SEMI',
      'FUTEBOL_SOCIETY_FEM_ACCESS_CROSS_GROUPS'
    )
      THEN 'LINEAR'
    ELSE 'LINEAR'
  END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_championship_knockout_seed_order(input_mode text, bracket_size integer)
 RETURNS integer[]
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  pairing_mode text;
  seed_order integer[] := ARRAY[]::integer[];
  next_seed_order integer[] := ARRAY[]::integer[];

  half_size integer;
  current_size integer;
  leader_seed integer;
  seed_value integer;
BEGIN
  -- Apenas chaves de potência de 2 são válidas.
  IF bracket_size IS NULL
    OR bracket_size < 2
    OR (bracket_size & (bracket_size - 1)) <> 0
  THEN
    RETURN ARRAY[]::integer[];
  END IF;

  pairing_mode :=
    public.resolve_championship_knockout_pairing_mode(input_mode);

  half_size := bracket_size / 2;

  ---------------------------------------------------------------------------
  -- LINEAR
  --
  -- 8 participantes:
  -- 1 x 8
  -- 2 x 7
  -- 3 x 6
  -- 4 x 5
  ---------------------------------------------------------------------------
  IF pairing_mode = 'LINEAR' THEN
    FOR leader_seed IN 1..half_size LOOP
      seed_order :=
        seed_order
        || ARRAY[
          leader_seed,
          bracket_size + 1 - leader_seed
        ];
    END LOOP;

    RETURN seed_order;
  END IF;

  ---------------------------------------------------------------------------
  -- RANKING_ALTERNATING
  --
  -- Primeiro líderes ímpares, depois líderes pares.
  --
  -- 8 participantes:
  -- 1 x 8
  -- 3 x 6
  -- 2 x 7
  -- 4 x 5
  ---------------------------------------------------------------------------
  IF pairing_mode = 'RANKING_ALTERNATING' THEN
    FOR leader_seed IN 1..half_size BY 2 LOOP
      seed_order :=
        seed_order
        || ARRAY[
          leader_seed,
          bracket_size + 1 - leader_seed
        ];
    END LOOP;

    FOR leader_seed IN 2..half_size BY 2 LOOP
      seed_order :=
        seed_order
        || ARRAY[
          leader_seed,
          bracket_size + 1 - leader_seed
        ];
    END LOOP;

    RETURN seed_order;
  END IF;

  ---------------------------------------------------------------------------
  -- CLASSIC_SEEDED
  --
  -- Montagem recursiva clássica de chaveamento.
  --
  -- 2:
  -- [1,2]
  --
  -- 4:
  -- [1,4,2,3]
  --
  -- 8:
  -- [1,8,4,5,2,7,3,6]
  --
  -- 16:
  -- [1,16,8,9,4,13,5,12,2,15,7,10,3,14,6,11]
  ---------------------------------------------------------------------------
  seed_order := ARRAY[1, 2];
  current_size := 2;

  WHILE current_size < bracket_size LOOP
    next_seed_order := ARRAY[]::integer[];

    FOREACH seed_value IN ARRAY seed_order LOOP
      next_seed_order :=
        next_seed_order
        || ARRAY[
          seed_value,
          (current_size * 2) + 1 - seed_value
        ];
    END LOOP;

    seed_order := next_seed_order;
    current_size := current_size * 2;
  END LOOP;

  RETURN seed_order;
END;
$function$;

SET check_function_bodies = on;
