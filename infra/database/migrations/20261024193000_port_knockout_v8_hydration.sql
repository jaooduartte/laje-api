-- LAJE-150 — Restores EXACT original qualification and knockout hydration for async-exact-v8 only.
-- Read from operational Supabase pg_get_functiondef; never changes operational Supabase.
-- Legacy v7 paths fail closed: intentionally not migrated for AWS TCC.
-- Postgres 17, idempotent CREATE OR REPLACE, no direct DML on existing data on installation.

-- resolve_championship_knockout_pairing_mode(_value text)
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

-- resolve_championship_knockout_seed_order(input_mode text, bracket_size integer)
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

-- resolve_championship_bracket_match_loser_team_id(_bracket_match_id uuid)
CREATE OR REPLACE FUNCTION public.resolve_championship_bracket_match_loser_team_id(_bracket_match_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  loser_team_id UUID;
BEGIN
  SELECT
    CASE
      WHEN bracket_matches_table.winner_team_id = bracket_matches_table.home_team_id THEN bracket_matches_table.away_team_id
      WHEN bracket_matches_table.winner_team_id = bracket_matches_table.away_team_id THEN bracket_matches_table.home_team_id
      ELSE NULL
    END
  INTO loser_team_id
  FROM public.championship_bracket_matches AS bracket_matches_table
  WHERE bracket_matches_table.id = _bracket_match_id
  LIMIT 1;

  RETURN loser_team_id;
END;
$function$;

-- sync_championship_bracket_edition_status(_bracket_edition_id uuid)
CREATE OR REPLACE FUNCTION public.sync_championship_bracket_edition_status(_bracket_edition_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE public.championship_bracket_editions AS editions_table
  SET
    status = CASE
      WHEN EXISTS (
        SELECT 1
        FROM public.championship_bracket_matches AS bracket_matches_table
        WHERE bracket_matches_table.bracket_edition_id = editions_table.id
          AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      ) THEN 'KNOCKOUT_GENERATED'::public.bracket_edition_status
      WHEN EXISTS (
        SELECT 1
        FROM public.championship_bracket_matches AS bracket_matches_table
        JOIN public.matches AS matches_table
          ON matches_table.id = bracket_matches_table.match_id
        WHERE bracket_matches_table.bracket_edition_id = editions_table.id
          AND bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
      ) THEN 'GROUPS_GENERATED'::public.bracket_edition_status
      ELSE 'DRAFT'::public.bracket_edition_status
    END,
    updated_at = now()
  WHERE editions_table.id = _bracket_edition_id;
END;
$function$;

-- create_championship_knockout_match_schedule(_championship_id uuid, _bracket_match_id uuid)
CREATE OR REPLACE FUNCTION public.create_championship_knockout_match_schedule(_championship_id uuid, _bracket_match_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  bracket_match_record RECORD;
  new_match_id UUID;
BEGIN
  SELECT
    bracket_matches_table.id,
    bracket_matches_table.bracket_edition_id,
    bracket_matches_table.competition_id,
    bracket_matches_table.match_id,
    bracket_matches_table.home_team_id,
    bracket_matches_table.away_team_id,
    bracket_matches_table.round_number,
    bracket_matches_table.slot_number,
    bracket_matches_table.is_third_place,
    bracket_matches_table.planned_scheduled_date,
    bracket_matches_table.planned_scheduled_slot,
    bracket_matches_table.planned_queue_position,
    bracket_matches_table.planned_start_time,
    bracket_matches_table.planned_end_time,
    bracket_matches_table.planned_location_name,
    bracket_matches_table.planned_court_name,
    competitions_table.division,
    competitions_table.naipe,
    competitions_table.sport_id,
    editions_table.season_year,
    editions_table.championship_id,
    editions_table.payload_snapshot ->> 'exact_preview_algorithm_version'
      AS exact_preview_algorithm_version
  INTO bracket_match_record
  FROM public.championship_bracket_matches AS bracket_matches_table
  JOIN public.championship_bracket_competitions AS competitions_table
    ON competitions_table.id = bracket_matches_table.competition_id
  JOIN public.championship_bracket_editions AS editions_table
    ON editions_table.id = bracket_matches_table.bracket_edition_id
  WHERE bracket_matches_table.id = _bracket_match_id
  LIMIT 1;

  IF bracket_match_record.id IS NULL THEN
    RETURN NULL;
  END IF;

  IF bracket_match_record.exact_preview_algorithm_version
    IS DISTINCT FROM 'async-exact-v8'
  THEN
    RAISE EXCEPTION 'A API AWS LAJE-150 suporta apenas o mata-mata criado pela prévia exata v8.';
  END IF;

  IF bracket_match_record.championship_id <> _championship_id THEN
    RAISE EXCEPTION
      'A partida eliminatória % não pertence ao campeonato informado.',
      _bracket_match_id;
  END IF;

  IF bracket_match_record.match_id IS NOT NULL THEN
    RETURN bracket_match_record.match_id;
  END IF;

  IF bracket_match_record.home_team_id IS NULL
    OR bracket_match_record.away_team_id IS NULL
  THEN
    RETURN NULL;
  END IF;

  IF bracket_match_record.planned_scheduled_date IS NULL
    OR bracket_match_record.planned_scheduled_slot IS NULL
    OR bracket_match_record.planned_queue_position IS NULL
    OR bracket_match_record.planned_start_time IS NULL
    OR bracket_match_record.planned_end_time IS NULL
    OR bracket_match_record.planned_location_name IS NULL
    OR bracket_match_record.planned_court_name IS NULL
  THEN
    RAISE EXCEPTION
      'A partida eliminatória v8 % não possui programação estrutural completa.',
      _bracket_match_id;
  END IF;

  PERFORM set_config('app.skip_queue_trigger', 'true', true);
  PERFORM set_config('app.skip_match_conflict_trigger', 'true', true);

  INSERT INTO public.matches (
    championship_id,
    division,
    naipe,
    sport_id,
    home_team_id,
    away_team_id,
    location,
    court_name,
    scheduled_date,
    queue_position,
    scheduled_slot,
    scheduled_start_time,
    start_time,
    end_time,
    season_year,
    status
  )
  VALUES (
    _championship_id,
    bracket_match_record.division,
    bracket_match_record.naipe,
    bracket_match_record.sport_id,
    bracket_match_record.home_team_id,
    bracket_match_record.away_team_id,
    bracket_match_record.planned_location_name,
    bracket_match_record.planned_court_name,
    bracket_match_record.planned_scheduled_date,
    bracket_match_record.planned_queue_position,
    bracket_match_record.planned_scheduled_slot,
    public.combine_bracket_schedule_timestamp(
      bracket_match_record.planned_scheduled_date,
      bracket_match_record.planned_start_time
    ),
    public.combine_bracket_schedule_timestamp(
      bracket_match_record.planned_scheduled_date,
      bracket_match_record.planned_start_time
    ),
    public.combine_bracket_schedule_timestamp(
      bracket_match_record.planned_scheduled_date,
      bracket_match_record.planned_end_time
    ),
    bracket_match_record.season_year,
    'SCHEDULED'::public.match_status
  )
  RETURNING id
  INTO new_match_id;

  UPDATE public.championship_bracket_matches
  SET match_id = new_match_id
  WHERE id = _bracket_match_id;

  PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
  PERFORM set_config('app.skip_queue_trigger', 'false', true);

  RETURN new_match_id;
EXCEPTION
  WHEN OTHERS THEN
    PERFORM set_config('app.skip_match_conflict_trigger', 'false', true);
    PERFORM set_config('app.skip_queue_trigger', 'false', true);
    RAISE;
END;
$function$;

-- ensure_championship_knockout_next_round_match(_championship_id uuid, _competition_id uuid, _source_round_number integer, _next_slot_number integer)
CREATE OR REPLACE FUNCTION public.ensure_championship_knockout_next_round_match(_championship_id uuid, _competition_id uuid, _source_round_number integer, _next_slot_number integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  competition_record RECORD;
  source_home_bracket_match RECORD;
  source_away_bracket_match RECORD;
  target_bracket_match RECORD;
  existing_public_match RECORD;
  next_round_number INTEGER;
  resolved_home_team_id UUID;
  resolved_away_team_id UUID;
BEGIN
  IF _next_slot_number < 1
    OR _source_round_number < 1
  THEN
    RETURN NULL;
  END IF;

  SELECT
    competitions_table.id,
    competitions_table.bracket_edition_id,
    editions_table.championship_id,
    editions_table.payload_snapshot ->> 'exact_preview_algorithm_version'
      AS exact_preview_algorithm_version
  INTO competition_record
  FROM public.championship_bracket_competitions AS competitions_table
  JOIN public.championship_bracket_editions AS editions_table
    ON editions_table.id = competitions_table.bracket_edition_id
  WHERE competitions_table.id = _competition_id
  LIMIT 1;

  IF competition_record.id IS NULL THEN
    RETURN NULL;
  END IF;

  IF competition_record.exact_preview_algorithm_version
    IS DISTINCT FROM 'async-exact-v8'
  THEN
    RAISE EXCEPTION 'A API AWS LAJE-150 suporta apenas o mata-mata criado pela prévia exata v8.';
  END IF;

  IF competition_record.championship_id <> _championship_id THEN
    RAISE EXCEPTION
      'A competição % não pertence ao campeonato informado.',
      _competition_id;
  END IF;

  SELECT
    bracket_matches_table.id,
    bracket_matches_table.winner_team_id,
    bracket_matches_table.next_bracket_match_id
  INTO source_home_bracket_match
  FROM public.championship_bracket_matches AS bracket_matches_table
  WHERE bracket_matches_table.competition_id = _competition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_third_place = false
    AND bracket_matches_table.round_number = _source_round_number
    AND bracket_matches_table.slot_number =
      ((_next_slot_number * 2) - 1)
  LIMIT 1;

  SELECT
    bracket_matches_table.id,
    bracket_matches_table.winner_team_id,
    bracket_matches_table.next_bracket_match_id
  INTO source_away_bracket_match
  FROM public.championship_bracket_matches AS bracket_matches_table
  WHERE bracket_matches_table.competition_id = _competition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_third_place = false
    AND bracket_matches_table.round_number = _source_round_number
    AND bracket_matches_table.slot_number =
      (_next_slot_number * 2)
  LIMIT 1;

  IF source_home_bracket_match.id IS NULL
    OR source_away_bracket_match.id IS NULL
  THEN
    RAISE EXCEPTION
      'As partidas predecessoras da rodada %, slot %, não existem na estrutura eliminatória v8.',
      _source_round_number,
      _next_slot_number;
  END IF;

  next_round_number := _source_round_number + 1;

  resolved_home_team_id :=
    source_home_bracket_match.winner_team_id;

  resolved_away_team_id :=
    source_away_bracket_match.winner_team_id;

  SELECT
    bracket_matches_table.id,
    bracket_matches_table.match_id,
    bracket_matches_table.home_team_id,
    bracket_matches_table.away_team_id,
    bracket_matches_table.is_bye,
    bracket_matches_table.source_home_bracket_match_id,
    bracket_matches_table.source_away_bracket_match_id,
    bracket_matches_table.planned_scheduled_date,
    bracket_matches_table.planned_start_time,
    bracket_matches_table.planned_end_time,
    bracket_matches_table.planned_location_group_id,
    bracket_matches_table.planned_court_group_id,
    bracket_matches_table.planned_location_name,
    bracket_matches_table.planned_court_name
  INTO target_bracket_match
  FROM public.championship_bracket_matches AS bracket_matches_table
  WHERE bracket_matches_table.competition_id = _competition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_third_place = false
    AND bracket_matches_table.round_number = next_round_number
    AND bracket_matches_table.slot_number = _next_slot_number
  LIMIT 1;

  IF target_bracket_match.id IS NULL THEN
    RAISE EXCEPTION
      'A próxima partida da rodada %, slot %, não existe na estrutura aprovada pela prévia v8.',
      next_round_number,
      _next_slot_number;
  END IF;

  IF target_bracket_match.source_home_bracket_match_id
      IS DISTINCT FROM source_home_bracket_match.id
    OR target_bracket_match.source_away_bracket_match_id
      IS DISTINCT FROM source_away_bracket_match.id
  THEN
    RAISE EXCEPTION
      'As dependências da rodada %, slot %, divergem da estrutura eliminatória aprovada na prévia v8.',
      next_round_number,
      _next_slot_number;
  END IF;

  IF source_home_bracket_match.next_bracket_match_id
      IS DISTINCT FROM target_bracket_match.id
    OR source_away_bracket_match.next_bracket_match_id
      IS DISTINCT FROM target_bracket_match.id
  THEN
    RAISE EXCEPTION
      'O encadeamento da rodada %, slot %, diverge da estrutura eliminatória aprovada na prévia v8.',
      next_round_number,
      _next_slot_number;
  END IF;

  IF target_bracket_match.is_bye THEN
    RAISE EXCEPTION
      'Uma partida posterior à primeira rodada foi marcada como BYE na estrutura eliminatória v8: rodada %, slot %.',
      next_round_number,
      _next_slot_number;
  END IF;

  IF target_bracket_match.match_id IS NOT NULL THEN
    SELECT
      matches_table.id,
      matches_table.home_team_id,
      matches_table.away_team_id
    INTO existing_public_match
    FROM public.matches AS matches_table
    WHERE matches_table.id = target_bracket_match.match_id
    LIMIT 1;

    IF existing_public_match.id IS NULL THEN
      RAISE EXCEPTION
        'A partida eliminatória v8 % referencia um jogo inexistente.',
        target_bracket_match.id;
    END IF;

    IF resolved_home_team_id IS NOT NULL
      AND resolved_away_team_id IS NOT NULL
      AND (
        existing_public_match.home_team_id
          IS DISTINCT FROM resolved_home_team_id
        OR existing_public_match.away_team_id
          IS DISTINCT FROM resolved_away_team_id
      )
    THEN
      RAISE EXCEPTION
        'Os participantes da partida eliminatória v8 % divergem dos vencedores das partidas predecessoras.',
        target_bracket_match.id;
    END IF;

    RETURN target_bracket_match.id;
  END IF;

  UPDATE public.championship_bracket_matches AS bracket_matches_table
  SET
    home_team_id = resolved_home_team_id,
    away_team_id = resolved_away_team_id,
    winner_team_id = NULL
  WHERE bracket_matches_table.id = target_bracket_match.id;

  IF resolved_home_team_id IS NULL
    OR resolved_away_team_id IS NULL
  THEN
    RETURN target_bracket_match.id;
  END IF;

  IF target_bracket_match.planned_scheduled_date IS NULL
    OR target_bracket_match.planned_start_time IS NULL
    OR target_bracket_match.planned_end_time IS NULL
    OR target_bracket_match.planned_location_group_id IS NULL
    OR target_bracket_match.planned_court_group_id IS NULL
    OR target_bracket_match.planned_location_name IS NULL
    OR target_bracket_match.planned_court_name IS NULL
  THEN
    RAISE EXCEPTION
      'A partida eliminatória v8 da rodada %, slot %, não possui programação estrutural completa.',
      next_round_number,
      _next_slot_number;
  END IF;

  PERFORM public.create_championship_knockout_match_schedule(
    _championship_id,
    target_bracket_match.id
  );

  RETURN target_bracket_match.id;
END;
$function$;

-- ensure_championship_knockout_third_place_match(_championship_id uuid, _competition_id uuid, _semifinal_round_number integer)
CREATE OR REPLACE FUNCTION public.ensure_championship_knockout_third_place_match(_championship_id uuid, _competition_id uuid, _semifinal_round_number integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  competition_record RECORD;
  semifinal_home_match RECORD;
  semifinal_away_match RECORD;
  third_place_match RECORD;
  existing_public_match RECORD;
  third_place_home_team_id UUID;
  third_place_away_team_id UUID;
BEGIN
  SELECT
    competitions_table.id,
    competitions_table.bracket_edition_id,
    competitions_table.third_place_mode,
    editions_table.championship_id,
    editions_table.payload_snapshot ->> 'exact_preview_algorithm_version'
      AS exact_preview_algorithm_version
  INTO competition_record
  FROM public.championship_bracket_competitions AS competitions_table
  JOIN public.championship_bracket_editions AS editions_table
    ON editions_table.id = competitions_table.bracket_edition_id
  WHERE competitions_table.id = _competition_id
  LIMIT 1;

  IF competition_record.id IS NULL
    OR competition_record.third_place_mode
      <> 'MATCH'::public.bracket_third_place_mode
    OR _semifinal_round_number < 1
  THEN
    RETURN NULL;
  END IF;

  IF competition_record.exact_preview_algorithm_version
    IS DISTINCT FROM 'async-exact-v8'
  THEN
    RAISE EXCEPTION 'A API AWS LAJE-150 suporta apenas o mata-mata criado pela prévia exata v8.';
  END IF;

  IF competition_record.championship_id <> _championship_id THEN
    RAISE EXCEPTION
      'A competição % não pertence ao campeonato informado.',
      _competition_id;
  END IF;

  SELECT
    bracket_matches_table.id
  INTO semifinal_home_match
  FROM public.championship_bracket_matches AS bracket_matches_table
  WHERE bracket_matches_table.competition_id = _competition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_third_place = false
    AND bracket_matches_table.round_number = _semifinal_round_number
    AND bracket_matches_table.slot_number = 1
  LIMIT 1;

  SELECT
    bracket_matches_table.id
  INTO semifinal_away_match
  FROM public.championship_bracket_matches AS bracket_matches_table
  WHERE bracket_matches_table.competition_id = _competition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_third_place = false
    AND bracket_matches_table.round_number = _semifinal_round_number
    AND bracket_matches_table.slot_number = 2
  LIMIT 1;

  IF semifinal_home_match.id IS NULL
    OR semifinal_away_match.id IS NULL
  THEN
    RAISE EXCEPTION
      'As semifinais necessárias para o terceiro lugar não existem na estrutura v8 da competição %.',
      _competition_id;
  END IF;

  third_place_home_team_id :=
    public.resolve_championship_bracket_match_loser_team_id(
      semifinal_home_match.id
    );

  third_place_away_team_id :=
    public.resolve_championship_bracket_match_loser_team_id(
      semifinal_away_match.id
    );

  SELECT
    bracket_matches_table.id,
    bracket_matches_table.match_id,
    bracket_matches_table.home_team_id,
    bracket_matches_table.away_team_id,
    bracket_matches_table.source_home_bracket_match_id,
    bracket_matches_table.source_away_bracket_match_id,
    bracket_matches_table.is_bye,
    bracket_matches_table.planned_scheduled_date,
    bracket_matches_table.planned_start_time,
    bracket_matches_table.planned_end_time,
    bracket_matches_table.planned_location_group_id,
    bracket_matches_table.planned_court_group_id,
    bracket_matches_table.planned_location_name,
    bracket_matches_table.planned_court_name
  INTO third_place_match
  FROM public.championship_bracket_matches AS bracket_matches_table
  WHERE bracket_matches_table.competition_id = _competition_id
    AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
    AND bracket_matches_table.is_third_place = true
  LIMIT 1;

  IF third_place_match.id IS NULL THEN
    RAISE EXCEPTION
      'A disputa de terceiro lugar não existe na estrutura aprovada pela prévia v8 da competição %.',
      _competition_id;
  END IF;

  IF third_place_match.source_home_bracket_match_id
      IS DISTINCT FROM semifinal_home_match.id
    OR third_place_match.source_away_bracket_match_id
      IS DISTINCT FROM semifinal_away_match.id
  THEN
    RAISE EXCEPTION
      'As dependências da disputa de terceiro lugar divergem da estrutura aprovada pela prévia v8.';
  END IF;

  IF third_place_match.is_bye THEN
    RAISE EXCEPTION
      'A disputa de terceiro lugar foi marcada incorretamente como BYE na estrutura v8.';
  END IF;

  IF third_place_match.match_id IS NOT NULL THEN
    SELECT
      matches_table.id,
      matches_table.home_team_id,
      matches_table.away_team_id
    INTO existing_public_match
    FROM public.matches AS matches_table
    WHERE matches_table.id = third_place_match.match_id
    LIMIT 1;

    IF existing_public_match.id IS NULL THEN
      RAISE EXCEPTION
        'A disputa de terceiro lugar v8 referencia um jogo inexistente.';
    END IF;

    IF third_place_home_team_id IS NOT NULL
      AND third_place_away_team_id IS NOT NULL
      AND (
        existing_public_match.home_team_id
          IS DISTINCT FROM third_place_home_team_id
        OR existing_public_match.away_team_id
          IS DISTINCT FROM third_place_away_team_id
      )
    THEN
      RAISE EXCEPTION
        'Os participantes da disputa de terceiro lugar divergem dos perdedores das semifinais.';
    END IF;

    RETURN third_place_match.id;
  END IF;

  UPDATE public.championship_bracket_matches AS bracket_matches_table
  SET
    home_team_id = third_place_home_team_id,
    away_team_id = third_place_away_team_id,
    winner_team_id = NULL,
    is_bye = false
  WHERE bracket_matches_table.id = third_place_match.id;

  IF third_place_home_team_id IS NULL
    OR third_place_away_team_id IS NULL
  THEN
    RETURN third_place_match.id;
  END IF;

  IF third_place_match.planned_scheduled_date IS NULL
    OR third_place_match.planned_start_time IS NULL
    OR third_place_match.planned_end_time IS NULL
    OR third_place_match.planned_location_group_id IS NULL
    OR third_place_match.planned_court_group_id IS NULL
    OR third_place_match.planned_location_name IS NULL
    OR third_place_match.planned_court_name IS NULL
  THEN
    RAISE EXCEPTION
      'A disputa de terceiro lugar v8 não possui programação estrutural completa aprovada.';
  END IF;

  PERFORM public.create_championship_knockout_match_schedule(
    _championship_id,
    third_place_match.id
  );

  RETURN third_place_match.id;
END;
$function$;

-- hydrate_championship_bracket_preview_v8_knockout(_championship_id uuid, _competition_id uuid, _bracket_edition_id uuid)
CREATE OR REPLACE FUNCTION public.hydrate_championship_bracket_preview_v8_knockout(_championship_id uuid, _competition_id uuid, _bracket_edition_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
#variable_conflict use_variable
DECLARE
  competition_record RECORD;
  ranking_record RECORD;
  qualified_team_ids UUID[] := ARRAY[]::UUID[];
  group_count_value INTEGER;
  all_groups_finished BOOLEAN := false;
  direct_qualified_team_count INTEGER;
  target_bracket_size INTEGER := 1;
  total_rounds INTEGER := 0;
  should_expand_with_best_second_placed_teams BOOLEAN;
  should_include_best_second_placed_teams BOOLEAN;
  should_use_cross_groups_pairing BOOLEAN := false;
  additional_qualification_rank INTEGER;
  pending_tie_breaks_count INTEGER;
  standard_seed_order INTEGER[] := ARRAY[]::INTEGER[];
  slot_index INTEGER;
  source_round_number INTEGER;
  next_slot_number INTEGER;
  home_seed_index INTEGER;
  away_seed_index INTEGER;
  home_team_id UUID;
  away_team_id UUID;
  first_round_match_id UUID;
  first_round_match_record RECORD;
  expected_is_bye BOOLEAN;
BEGIN
  SELECT
    competitions_table.id,
    competitions_table.bracket_edition_id,
    competitions_table.qualifiers_per_group,
    competitions_table.should_complete_knockout_with_best_second_placed_teams,
    competitions_table.third_place_mode,
    competitions_table.knockout_pairing_mode,
    competitions_table.naipe,
    competitions_table.division,
    sports_table.code AS sport_code
  INTO competition_record
  FROM public.championship_bracket_competitions AS competitions_table
  JOIN public.sports AS sports_table ON sports_table.id = competitions_table.sport_id
  WHERE competitions_table.id = _competition_id
    AND competitions_table.bracket_edition_id = _bracket_edition_id
  LIMIT 1;

  IF competition_record.id IS NULL
    OR NOT EXISTS (
      SELECT 1
      FROM public.championship_bracket_editions AS editions_table
      WHERE editions_table.id = _bracket_edition_id
        AND editions_table.payload_snapshot ->> 'exact_preview_algorithm_version' = 'async-exact-v8'
    )
  THEN
    RETURN NULL;
  END IF;

  SELECT
    count(*)::integer,
    bool_and(group_statuses.is_group_finished)
  INTO group_count_value, all_groups_finished
  FROM (
    SELECT
      groups_table.id,
      (
        count(bracket_matches_table.match_id) > 0
        AND count(*) FILTER (
          WHERE matches_table.status = 'FINISHED'::public.match_status
        ) = count(bracket_matches_table.match_id)
      ) AS is_group_finished
    FROM public.championship_bracket_groups AS groups_table
    LEFT JOIN public.championship_bracket_matches AS bracket_matches_table
      ON bracket_matches_table.group_id = groups_table.id
      AND bracket_matches_table.phase = 'GROUP_STAGE'::public.bracket_phase
    LEFT JOIN public.matches AS matches_table
      ON matches_table.id = bracket_matches_table.match_id
    WHERE groups_table.competition_id = _competition_id
    GROUP BY groups_table.id
  ) AS group_statuses;

  IF group_count_value < 1 OR all_groups_finished IS NOT TRUE THEN
    RETURN _competition_id;
  END IF;

  direct_qualified_team_count := group_count_value * competition_record.qualifiers_per_group;
  should_expand_with_best_second_placed_teams :=
    competition_record.qualifiers_per_group = 1
    AND competition_record.should_complete_knockout_with_best_second_placed_teams = true;

  IF should_expand_with_best_second_placed_teams THEN
    WHILE target_bracket_size <= direct_qualified_team_count LOOP
      target_bracket_size := target_bracket_size * 2;
    END LOOP;
  ELSE
    WHILE target_bracket_size < direct_qualified_team_count LOOP
      target_bracket_size := target_bracket_size * 2;
    END LOOP;
  END IF;

  IF target_bracket_size < 2 THEN
    RETURN _competition_id;
  END IF;

  WHILE power(2, total_rounds)::integer < target_bracket_size LOOP
    total_rounds := total_rounds + 1;
  END LOOP;

  should_include_best_second_placed_teams :=
    competition_record.qualifiers_per_group = 1
    AND target_bracket_size > direct_qualified_team_count;
  should_use_cross_groups_pairing := false;
  additional_qualification_rank := CASE
    WHEN target_bracket_size <= direct_qualified_team_count THEN NULL
    WHEN competition_record.qualifiers_per_group = 1 THEN 2
    WHEN competition_record.qualifiers_per_group = 2 THEN 3
    ELSE NULL
  END;

  SELECT count(*)
  INTO pending_tie_breaks_count
  FROM jsonb_array_elements(
    public.get_championship_bracket_pending_tie_breaks(_championship_id, _bracket_edition_id)
  ) AS tie_break
  WHERE (tie_break ->> 'competition_id')::uuid = _competition_id
    AND (
      tie_break ->> 'context_type' <> 'QUALIFICATION_POOL'
      OR (
        competition_record.qualifiers_per_group = 1
        AND (tie_break ->> 'qualification_rank')::integer = 1
      )
      OR (
        additional_qualification_rank IS NOT NULL
        AND (tie_break ->> 'qualification_rank')::integer = additional_qualification_rank
      )
    );

  IF pending_tie_breaks_count > 0 THEN
    RETURN _competition_id;
  END IF;

  IF should_use_cross_groups_pairing THEN
    FOR ranking_record IN
      WITH ordered_groups AS (
        SELECT groups_table.id AS group_id, groups_table.group_number
        FROM public.championship_bracket_groups AS groups_table
        WHERE groups_table.competition_id = _competition_id
      )
      SELECT rankings_table.team_id
      FROM ordered_groups
      CROSS JOIN generate_series(1, 2) AS qualifiers(rank_number)
      LEFT JOIN public.get_championship_bracket_competition_group_rankings(
        _championship_id,
        _competition_id
      ) AS rankings_table
        ON rankings_table.group_id = ordered_groups.group_id
        AND rankings_table.team_rank = qualifiers.rank_number
      ORDER BY ordered_groups.group_number, qualifiers.rank_number
    LOOP
      qualified_team_ids := array_append(qualified_team_ids, ranking_record.team_id);
    END LOOP;
  ELSE
    FOR ranking_record IN
      WITH ordered_groups AS (
      SELECT groups_table.id AS group_id, groups_table.group_number
      FROM public.championship_bracket_groups AS groups_table
      WHERE groups_table.competition_id = _competition_id
    )
    SELECT rankings_table.team_id
    FROM ordered_groups
    CROSS JOIN generate_series(1, competition_record.qualifiers_per_group) AS qualifiers(rank_number)
    LEFT JOIN public.get_championship_bracket_competition_group_rankings(
      _championship_id,
      _competition_id
    ) AS rankings_table
      ON rankings_table.group_id = ordered_groups.group_id
      AND rankings_table.team_rank = qualifiers.rank_number
    LEFT JOIN public.get_championship_bracket_competition_qualification_pool_rankings(
      _championship_id,
      _competition_id
    ) AS pool_rankings
      ON pool_rankings.team_id = rankings_table.team_id
      AND pool_rankings.qualification_rank = qualifiers.rank_number
    ORDER BY
      qualifiers.rank_number ASC,
      CASE
        WHEN competition_record.qualifiers_per_group = 1
          THEN COALESCE(pool_rankings.pool_rank, ordered_groups.group_number + 1000)
        ELSE ordered_groups.group_number
      END ASC
    LOOP
      qualified_team_ids := array_append(qualified_team_ids, ranking_record.team_id);
    END LOOP;
  END IF;

  IF additional_qualification_rank IS NOT NULL THEN
    FOR ranking_record IN
      SELECT qualification_pool_rankings.team_id
      FROM public.get_championship_bracket_competition_qualification_pool_rankings(
        _championship_id,
        _competition_id
      ) AS qualification_pool_rankings
      WHERE qualification_pool_rankings.qualification_rank = additional_qualification_rank
      ORDER BY qualification_pool_rankings.pool_rank ASC
    LOOP
      EXIT WHEN COALESCE(cardinality(qualified_team_ids), 0) >= target_bracket_size;

      IF ranking_record.team_id IS NOT NULL
        AND NOT ranking_record.team_id = ANY(qualified_team_ids) THEN
        qualified_team_ids := array_append(qualified_team_ids, ranking_record.team_id);
      END IF;
    END LOOP;
  END IF;

  WHILE COALESCE(cardinality(qualified_team_ids), 0) < target_bracket_size LOOP
    qualified_team_ids := array_append(qualified_team_ids, NULL);
  END LOOP;
  qualified_team_ids := qualified_team_ids[1:target_bracket_size];

  standard_seed_order :=
    public.resolve_championship_knockout_seed_order(
      competition_record.knockout_pairing_mode,
      target_bracket_size
    );

  IF COALESCE(cardinality(standard_seed_order), 0) <> target_bracket_size THEN
    RAISE EXCEPTION
      'Invalid knockout seed order for competition %, mode %, bracket size %',
      competition_record.id,
      competition_record.knockout_pairing_mode,
      target_bracket_size;
  END IF;

  IF (
    SELECT count(*)
    FROM public.championship_bracket_matches AS bracket_matches_table
    WHERE bracket_matches_table.competition_id = _competition_id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND bracket_matches_table.is_third_place = false
      AND bracket_matches_table.round_number = 1
  ) <> target_bracket_size / 2 THEN
    RAISE EXCEPTION 'A estrutura eliminatória persistida diverge do chaveamento exato aprovado.';
  END IF;

  FOR slot_index IN 1..(target_bracket_size / 2) LOOP
    home_seed_index := standard_seed_order[((slot_index - 1) * 2) + 1];
    away_seed_index := standard_seed_order[((slot_index - 1) * 2) + 2];
    home_team_id := qualified_team_ids[home_seed_index];
    away_team_id := qualified_team_ids[away_seed_index];

    SELECT
  bracket_matches_table.id,
  bracket_matches_table.is_bye,
  bracket_matches_table.planned_scheduled_date,
  bracket_matches_table.planned_start_time,
  bracket_matches_table.planned_end_time,
  bracket_matches_table.planned_location_group_id,
  bracket_matches_table.planned_court_group_id,
  bracket_matches_table.planned_location_name,
  bracket_matches_table.planned_court_name
INTO first_round_match_record
FROM public.championship_bracket_matches AS bracket_matches_table
WHERE bracket_matches_table.competition_id = _competition_id
  AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
  AND bracket_matches_table.is_third_place = false
  AND bracket_matches_table.round_number = 1
  AND bracket_matches_table.slot_number = slot_index
LIMIT 1;

IF first_round_match_record.id IS NULL THEN
  RAISE EXCEPTION
    'A partida estrutural da primeira rodada, slot %, não existe na programação exata v8.',
    slot_index;
END IF;

expected_is_bye :=
  (home_team_id IS NULL) <> (away_team_id IS NULL);

IF home_team_id IS NULL
  AND away_team_id IS NULL
THEN
  RAISE EXCEPTION
    'A classificação real não resolveu nenhum participante para a primeira rodada, slot %, da competição %.',
    slot_index,
    _competition_id;
END IF;

IF NOT expected_is_bye
  AND (
    first_round_match_record.planned_scheduled_date IS NULL
    OR first_round_match_record.planned_start_time IS NULL
    OR first_round_match_record.planned_end_time IS NULL
    OR first_round_match_record.planned_location_group_id IS NULL
    OR first_round_match_record.planned_court_group_id IS NULL
    OR first_round_match_record.planned_location_name IS NULL
    OR first_round_match_record.planned_court_name IS NULL
  )
THEN
  RAISE EXCEPTION
    'A partida real da primeira rodada, slot %, não possui programação estrutural completa aprovada na prévia v8.',
    slot_index;
END IF;

    UPDATE public.championship_bracket_matches AS bracket_matches_table
    SET
      home_team_id = home_team_id,
      away_team_id = away_team_id,
      winner_team_id = CASE
        WHEN home_team_id IS NULL AND away_team_id IS NOT NULL THEN away_team_id
        WHEN away_team_id IS NULL AND home_team_id IS NOT NULL THEN home_team_id
        ELSE NULL
      END,
      is_bye = first_round_match_record.is_bye
    WHERE bracket_matches_table.competition_id = _competition_id
      AND bracket_matches_table.phase = 'KNOCKOUT'::public.bracket_phase
      AND bracket_matches_table.is_third_place = false
      AND bracket_matches_table.round_number = 1
      AND bracket_matches_table.slot_number = slot_index
    RETURNING bracket_matches_table.id INTO first_round_match_id;

    IF home_team_id IS NOT NULL AND away_team_id IS NOT NULL THEN
      PERFORM public.create_championship_knockout_match_schedule(
        _championship_id,
        first_round_match_id
      );
    END IF;
  END LOOP;

  FOR source_round_number IN 1..(total_rounds - 1) LOOP
    FOR next_slot_number IN 1..power(2, total_rounds - source_round_number - 1)::integer LOOP
      PERFORM public.ensure_championship_knockout_next_round_match(
        _championship_id,
        _competition_id,
        source_round_number,
        next_slot_number
      );
    END LOOP;
  END LOOP;

  IF competition_record.third_place_mode =
    'MATCH'::public.bracket_third_place_mode
  AND total_rounds > 1
THEN
  PERFORM public.ensure_championship_knockout_third_place_match(
    _championship_id,
    _competition_id,
    total_rounds - 1
  );
END IF;

  PERFORM public.sync_championship_bracket_edition_status(_bracket_edition_id);
  RETURN _competition_id;
END;
$function$;

