-- LAJE-126: compatibilidade mínima de identidade para RPCs internas do motor migrado.
CREATE SCHEMA IF NOT EXISTS auth;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
AS $function$
  SELECT NULLIF(current_setting('laje.request_user_id', true), '')::uuid;
$function$;

CREATE OR REPLACE FUNCTION championship_bracket_preview_private.enqueue(
  _job_id uuid,
  _delay integer DEFAULT 0
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = championship_bracket_preview_private
AS $function$
BEGIN
  -- A fila real é Amazon SQS. A laje-api publica a mensagem após a RPC de start.
  RETURN;
END;
$function$;

SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.cancel_championship_bracket_preview_job(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
BEGIN
  UPDATE championship_bracket_preview_private.jobs SET status='CANCELLED',stage='Cancelada',expires_at=now()+interval '24 hours',updated_at=now()
  WHERE id=_job_id AND requested_by=auth.uid() AND status IN('QUEUED','INITIALIZING','SCHEDULING','FINALIZING');
  RETURN public.get_championship_bracket_preview_job_status(_job_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.coerce_division_for_index(d team_division)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$
  SELECT d::text;
$function$;

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

CREATE OR REPLACE FUNCTION public.create_championship_bracket_from_preview_job(_job_id uuid, _championship_id uuid, _payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '30s'
AS $function$
DECLARE
  job_record RECORD;
  edition_id UUID := gen_random_uuid();
  actual_dependency TEXT;
  persisted_manifest JSONB;
  persisted_signature TEXT;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_admin_tab_access('matches'::public.admin_panel_tab,true) THEN
    RAISE EXCEPTION 'Usuário sem permissão para criar o campeonato.';
  END IF;
  SELECT * INTO job_record FROM championship_bracket_preview_private.jobs WHERE id = _job_id FOR UPDATE;
  IF job_record.status = 'CONSUMED' AND job_record.result_edition_id IS NOT NULL THEN
    RETURN job_record.result_edition_id;
  END IF;
  IF job_record.status <> 'COMPLETED'
    OR job_record.algorithm_version <> 'async-exact-v8'
    OR job_record.championship_id <> _championship_id
    OR job_record.requested_by <> auth.uid()
    OR job_record.expires_at <= now()
    OR job_record.generation_signature IS NULL
    OR jsonb_array_length(job_record.diagnostics) > 0
  THEN
    RAISE EXCEPTION 'A prévia exata v8 não está concluída, pertence a outra configuração ou expirou.';
  END IF;
  IF public.resolve_championship_bracket_preview_payload_signature(COALESCE(_payload, '{}'::jsonb)) <> job_record.payload_signature THEN
    RAISE EXCEPTION 'A configuração foi alterada desde a prévia. Calcule novamente.';
  END IF;
  actual_dependency := championship_bracket_preview_private.resolve_dependency_signature(_championship_id, COALESCE(_payload, '{}'::jsonb));
  IF actual_dependency <> job_record.dependency_signature THEN
    RAISE EXCEPTION 'Dados externos usados no cálculo foram alterados. Calcule novamente.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.matches WHERE championship_id = _championship_id AND season_year = job_record.season_year) THEN
    RAISE EXCEPTION 'Este campeonato já possui jogos cadastrados.';
  END IF;

  PERFORM set_config('app.skip_queue_trigger','true',true);
  PERFORM set_config('app.skip_match_conflict_trigger','true',true);
  INSERT INTO public.championship_bracket_editions(id,championship_id,season_year,status,payload_snapshot,created_by,updated_by)
  VALUES(edition_id,_championship_id,job_record.season_year,'GROUPS_GENERATED',_payload || jsonb_build_object('exact_preview_algorithm_version','async-exact-v8'),auth.uid(),auth.uid());
  INSERT INTO public.championship_bracket_team_registrations(bracket_edition_id,team_id)
    SELECT DISTINCT edition_id,group_teams.team_id FROM championship_bracket_preview_private.group_teams group_teams WHERE group_teams.job_id=_job_id;
  INSERT INTO public.championship_bracket_team_modalities(bracket_edition_id,team_id,sport_id,naipe,division)
    SELECT DISTINCT edition_id,group_teams.team_id,competitions.sport_id,competitions.naipe,competitions.division
    FROM championship_bracket_preview_private.group_teams group_teams
    JOIN championship_bracket_preview_private.groups groups ON groups.id=group_teams.group_id
    JOIN championship_bracket_preview_private.competitions competitions ON competitions.id=groups.competition_id
    WHERE group_teams.job_id=_job_id;
  INSERT INTO public.championship_bracket_competitions(id,bracket_edition_id,sport_id,naipe,division,groups_count,qualifiers_per_group,third_place_mode,should_complete_knockout_with_best_second_placed_teams,knockout_pairing_mode)
    SELECT id,edition_id,sport_id,naipe,division,groups_count,qualifiers_per_group,third_place_mode,best_second,pairing_mode
    FROM championship_bracket_preview_private.competitions WHERE job_id=_job_id;
  INSERT INTO public.championship_bracket_groups(id,competition_id,group_number)
    SELECT id,competition_id,group_number FROM championship_bracket_preview_private.groups WHERE job_id=_job_id;
  INSERT INTO public.championship_bracket_group_teams(group_id,team_id,position)
    SELECT group_id,team_id,position FROM championship_bracket_preview_private.group_teams WHERE job_id=_job_id;

  WITH inserted_days AS (
    INSERT INTO public.championship_bracket_days(bracket_edition_id,event_date,start_time,end_time,break_start_time,break_end_time)
    SELECT edition_id,(day_item.value->>'date')::date,(day_item.value->>'start_time')::time,(day_item.value->>'end_time')::time,NULLIF(day_item.value->>'break_start_time','')::time,NULLIF(day_item.value->>'break_end_time','')::time
    FROM jsonb_array_elements(COALESCE(_payload->'schedule_days','[]'::jsonb)) day_item(value)
    RETURNING id,event_date
  ), inserted_locations AS (
    INSERT INTO public.championship_bracket_locations(bracket_day_id,name,position,location_group_id)
    SELECT inserted_days.id,location_item.value->>'name',COALESCE((location_item.value->>'position')::integer,location_item.ordinality::integer),(location_item.value->>'location_key')::uuid
    FROM inserted_days
    JOIN LATERAL jsonb_array_elements(COALESCE((SELECT day_item.value->'locations' FROM jsonb_array_elements(COALESCE(_payload->'schedule_days','[]'::jsonb)) day_item(value) WHERE (day_item.value->>'date')::date=inserted_days.event_date LIMIT 1),'[]'::jsonb)) WITH ORDINALITY location_item(value,ordinality) ON true
    RETURNING id,bracket_day_id,location_group_id
  ), inserted_courts AS (
    INSERT INTO public.championship_bracket_courts(bracket_location_id,name,position,court_group_id)
    SELECT inserted_locations.id,court_item.value->>'name',COALESCE((court_item.value->>'position')::integer,court_item.ordinality::integer),(court_item.value->>'court_key')::uuid
    FROM inserted_locations
    JOIN public.championship_bracket_days days_table ON days_table.id=inserted_locations.bracket_day_id
    JOIN LATERAL jsonb_array_elements(COALESCE((SELECT location_item.value->'courts' FROM jsonb_array_elements(COALESCE(_payload->'schedule_days','[]'::jsonb)) day_item(value) CROSS JOIN LATERAL jsonb_array_elements(COALESCE(day_item.value->'locations','[]'::jsonb)) location_item(value) WHERE (day_item.value->>'date')::date=days_table.event_date AND (location_item.value->>'location_key')::uuid=inserted_locations.location_group_id LIMIT 1),'[]'::jsonb)) WITH ORDINALITY court_item(value,ordinality) ON true
    RETURNING id,court_group_id
  )
  INSERT INTO public.championship_bracket_court_sports(bracket_court_id,sport_id)
    SELECT DISTINCT inserted_courts.id,slots_table.sport_id
    FROM inserted_courts
    JOIN championship_bracket_preview_private.slots slots_table ON slots_table.job_id=_job_id AND slots_table.court_key=inserted_courts.court_group_id
    ON CONFLICT DO NOTHING;
  PERFORM public.sync_championship_bracket_court_sport_preferences(edition_id,_payload);

  INSERT INTO public.matches(id,championship_id,division,naipe,sport_id,home_team_id,away_team_id,location,court_name,scheduled_date,scheduled_slot,queue_position,global_queue_order,start_time,end_time,season_year,status)
  SELECT matches_table.id,_championship_id,competitions.division,competitions.naipe,competitions.sport_id,matches_table.home_team_id,matches_table.away_team_id,slots_table.location_name,slots_table.court_name,slots_table.event_date,
    dense_rank() OVER(PARTITION BY slots_table.event_date ORDER BY slots_table.start_at),row_number() OVER(PARTITION BY slots_table.event_date,competitions.sport_id,competitions.naipe,competitions.division ORDER BY slots_table.start_at,slots_table.location_position,slots_table.court_position),
    row_number() OVER(ORDER BY slots_table.event_date,slots_table.start_at,slots_table.location_position,slots_table.court_position),slots_table.start_at,slots_table.end_at,job_record.season_year,'SCHEDULED'
  FROM championship_bracket_preview_private.assignments assignments_table
  JOIN championship_bracket_preview_private.matches matches_table ON matches_table.id=assignments_table.match_id
  JOIN championship_bracket_preview_private.competitions competitions ON competitions.id=matches_table.competition_id
  JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id=assignments_table.slot_id
  WHERE assignments_table.job_id=_job_id;
  INSERT INTO public.championship_bracket_matches(bracket_edition_id,competition_id,group_id,phase,round_number,slot_number,match_id,home_team_id,away_team_id)
    SELECT edition_id,competition_id,group_id,'GROUP_STAGE',round_number,slot_number,id,home_team_id,away_team_id
    FROM championship_bracket_preview_private.matches WHERE job_id=_job_id;

  INSERT INTO public.championship_bracket_matches(
    id,bracket_edition_id,competition_id,phase,round_number,slot_number,
    source_home_bracket_match_id,source_away_bracket_match_id,is_bye,is_third_place,
    planned_scheduled_date,planned_period,planned_scheduled_slot,planned_queue_position,
    planned_start_time,planned_end_time,planned_location_group_id,planned_court_group_id,
    planned_location_name,planned_court_name
  )
  SELECT knockout_matches.id,edition_id,knockout_matches.competition_id,'KNOCKOUT',knockout_matches.round_number,knockout_matches.slot_number,
    CASE WHEN cardinality(knockout_matches.predecessor_match_ids) > 0 THEN knockout_matches.predecessor_match_ids[1] END,
    CASE WHEN cardinality(knockout_matches.predecessor_match_ids) > 1 THEN knockout_matches.predecessor_match_ids[2] END,
    knockout_matches.is_bye,knockout_matches.phase='THIRD_PLACE',
    knockout_matches.scheduled_date,
    CASE WHEN knockout_matches.scheduled_date IS NULL THEN NULL ELSE public.resolve_bracket_schedule_period_by_timestamp(_payload,knockout_matches.scheduled_date,knockout_matches.start_at) END,
    NULL,NULL,
    CASE WHEN knockout_matches.start_at IS NULL THEN NULL ELSE (knockout_matches.start_at AT TIME ZONE 'America/Sao_Paulo')::time END,
    CASE WHEN knockout_matches.end_at IS NULL THEN NULL ELSE (knockout_matches.end_at AT TIME ZONE 'America/Sao_Paulo')::time END,
    knockout_matches.location_key,knockout_matches.court_key,knockout_matches.location_name,knockout_matches.court_name
  FROM championship_bracket_preview_private.knockout_matches knockout_matches
  WHERE knockout_matches.job_id=_job_id;
  UPDATE public.championship_bracket_matches predecessor_matches
  SET next_bracket_match_id=next_matches.id
  FROM public.championship_bracket_matches next_matches
  JOIN championship_bracket_preview_private.knockout_matches next_private ON next_private.id=next_matches.id
  WHERE predecessor_matches.bracket_edition_id=edition_id
    AND next_matches.bracket_edition_id=edition_id
    AND NOT next_matches.is_third_place
    AND predecessor_matches.id=ANY(next_private.predecessor_match_ids);

    IF EXISTS (
  SELECT 1
  FROM championship_bracket_preview_private.knockout_matches
    AS private_matches
  LEFT JOIN public.championship_bracket_matches
    AS persisted_matches
    ON persisted_matches.id = private_matches.id
  WHERE private_matches.job_id = _job_id
    AND (
      persisted_matches.id IS NULL
      OR persisted_matches.bracket_edition_id
        IS DISTINCT FROM edition_id
      OR persisted_matches.competition_id
        IS DISTINCT FROM private_matches.competition_id
      OR persisted_matches.phase
        IS DISTINCT FROM 'KNOCKOUT'::public.bracket_phase
      OR persisted_matches.round_number
        IS DISTINCT FROM private_matches.round_number
      OR persisted_matches.slot_number
        IS DISTINCT FROM private_matches.slot_number
      OR persisted_matches.is_bye
        IS DISTINCT FROM private_matches.is_bye
      OR persisted_matches.is_third_place
        IS DISTINCT FROM (
          private_matches.phase = 'THIRD_PLACE'
        )
      OR persisted_matches.source_home_bracket_match_id
        IS DISTINCT FROM (
          CASE
            WHEN cardinality(
              private_matches.predecessor_match_ids
            ) > 0
            THEN private_matches.predecessor_match_ids[1]
            ELSE NULL
          END
        )
      OR persisted_matches.source_away_bracket_match_id
        IS DISTINCT FROM (
          CASE
            WHEN cardinality(
              private_matches.predecessor_match_ids
            ) > 1
            THEN private_matches.predecessor_match_ids[2]
            ELSE NULL
          END
        )
    )
)
THEN
  RAISE EXCEPTION
    'A árvore eliminatória persistida divergiu da estrutura aprovada pela prévia v8.';
END IF;

IF EXISTS (
  SELECT 1
  FROM public.championship_bracket_matches
    AS persisted_matches
  LEFT JOIN championship_bracket_preview_private.knockout_matches
    AS private_matches
    ON private_matches.id = persisted_matches.id
    AND private_matches.job_id = _job_id
  WHERE persisted_matches.bracket_edition_id = edition_id
    AND persisted_matches.phase =
      'KNOCKOUT'::public.bracket_phase
    AND private_matches.id IS NULL
)
THEN
  RAISE EXCEPTION
    'Foram criados confrontos eliminatórios que não existem na prévia v8 aprovada.';
END IF;

IF EXISTS (
  SELECT 1
  FROM championship_bracket_preview_private.knockout_matches
    AS child_private
  CROSS JOIN LATERAL unnest(
    child_private.predecessor_match_ids
  ) AS predecessor_reference(predecessor_id)
  JOIN public.championship_bracket_matches
    AS predecessor_persisted
    ON predecessor_persisted.id =
      predecessor_reference.predecessor_id
  WHERE child_private.job_id = _job_id
    AND child_private.phase <> 'THIRD_PLACE'
    AND predecessor_persisted.next_bracket_match_id
      IS DISTINCT FROM child_private.id
)
THEN
  RAISE EXCEPTION
    'O encadeamento next_bracket_match_id divergiu da árvore eliminatória aprovada pela prévia v8.';
END IF;

IF EXISTS (
  SELECT 1
  FROM championship_bracket_preview_private.knockout_matches
    AS first_round_private
  JOIN public.championship_bracket_matches
    AS first_round_persisted
    ON first_round_persisted.id =
      first_round_private.id
  WHERE first_round_private.job_id = _job_id
    AND first_round_private.round_number = 1
    AND (
      first_round_persisted.source_home_bracket_match_id
        IS NOT NULL
      OR first_round_persisted.source_away_bracket_match_id
        IS NOT NULL
    )
)
THEN
  RAISE EXCEPTION
    'A primeira rodada eliminatória v8 possui dependências predecessoras inválidas.';
END IF;

  INSERT INTO public.championship_bracket_knockout_schedule_reservations(
    bracket_edition_id,competition_id,round_number,slot_number,is_third_place,
    scheduled_date,schedule_period,location_name,court_name,location_group_id,court_group_id,
    bracket_day_id,bracket_court_id,scheduled_slot,queue_position,start_at,end_at,duration_minutes,is_manual_final
  )
  SELECT edition_id,knockout_matches.competition_id,knockout_matches.round_number,knockout_matches.slot_number,knockout_matches.phase='THIRD_PLACE',
    knockout_matches.scheduled_date,
    public.resolve_bracket_schedule_period_by_timestamp(_payload,knockout_matches.scheduled_date,knockout_matches.start_at),
    knockout_matches.location_name,knockout_matches.court_name,knockout_matches.location_key,knockout_matches.court_key,
    days_table.id,courts_table.id,
    dense_rank() OVER(PARTITION BY knockout_matches.scheduled_date ORDER BY knockout_matches.start_at),
    row_number() OVER(PARTITION BY knockout_matches.scheduled_date,knockout_matches.court_key ORDER BY knockout_matches.start_at,knockout_matches.logical_key),
    knockout_matches.start_at,knockout_matches.end_at,knockout_matches.duration_minutes,knockout_matches.manual_final
  FROM championship_bracket_preview_private.knockout_matches knockout_matches
  JOIN public.championship_bracket_days days_table ON days_table.bracket_edition_id=edition_id AND days_table.event_date=knockout_matches.scheduled_date
  JOIN public.championship_bracket_locations locations_table ON locations_table.bracket_day_id=days_table.id AND locations_table.location_group_id=knockout_matches.location_key
  JOIN public.championship_bracket_courts courts_table ON courts_table.bracket_location_id=locations_table.id AND courts_table.court_group_id=knockout_matches.court_key
  WHERE knockout_matches.job_id=_job_id AND NOT knockout_matches.is_bye;

  UPDATE public.championship_bracket_matches AS bracket_matches
SET
  planned_scheduled_date = reservations.scheduled_date,
  planned_period = reservations.schedule_period,
  planned_scheduled_slot = reservations.scheduled_slot,
  planned_queue_position = reservations.queue_position,
  planned_start_time = (
    reservations.start_at
    AT TIME ZONE 'America/Sao_Paulo'
  )::time,
  planned_end_time = (
    reservations.end_at
    AT TIME ZONE 'America/Sao_Paulo'
  )::time,
  planned_location_group_id = reservations.location_group_id,
  planned_court_group_id = reservations.court_group_id,
  planned_location_name = reservations.location_name,
  planned_court_name = reservations.court_name
FROM public.championship_bracket_knockout_schedule_reservations
  AS reservations
WHERE bracket_matches.bracket_edition_id = edition_id
  AND bracket_matches.competition_id = reservations.competition_id
  AND bracket_matches.round_number = reservations.round_number
  AND bracket_matches.slot_number = reservations.slot_number
  AND bracket_matches.is_third_place = reservations.is_third_place
  AND reservations.bracket_edition_id = edition_id;

IF EXISTS (
  SELECT 1
  FROM championship_bracket_preview_private.knockout_matches
    AS private_matches
  LEFT JOIN public.championship_bracket_knockout_schedule_reservations
    AS reservations
    ON reservations.bracket_edition_id = edition_id
    AND reservations.competition_id =
      private_matches.competition_id
    AND reservations.round_number =
      private_matches.round_number
    AND reservations.slot_number =
      private_matches.slot_number
    AND reservations.is_third_place =
      (private_matches.phase = 'THIRD_PLACE')
  WHERE private_matches.job_id = _job_id
    AND NOT private_matches.is_bye
    AND (
      reservations.id IS NULL
      OR reservations.scheduled_date
        IS DISTINCT FROM private_matches.scheduled_date
      OR reservations.location_group_id
        IS DISTINCT FROM private_matches.location_key
      OR reservations.court_group_id
        IS DISTINCT FROM private_matches.court_key
      OR reservations.location_name
        IS DISTINCT FROM private_matches.location_name
      OR reservations.court_name
        IS DISTINCT FROM private_matches.court_name
      OR reservations.start_at
        IS DISTINCT FROM private_matches.start_at
      OR reservations.end_at
        IS DISTINCT FROM private_matches.end_at
      OR reservations.duration_minutes
        IS DISTINCT FROM private_matches.duration_minutes
      OR reservations.is_manual_final
        IS DISTINCT FROM private_matches.manual_final
    )
)
THEN
  RAISE EXCEPTION
    'Uma ou mais reservas eliminatórias persistidas divergem da programação exata aprovada pela prévia v8.';
END IF;

IF EXISTS (
  SELECT 1
  FROM championship_bracket_preview_private.knockout_matches
    AS private_matches
  JOIN public.championship_bracket_knockout_schedule_reservations
    AS reservations
    ON reservations.bracket_edition_id = edition_id
    AND reservations.competition_id =
      private_matches.competition_id
    AND reservations.round_number =
      private_matches.round_number
    AND reservations.slot_number =
      private_matches.slot_number
    AND reservations.is_third_place =
      (private_matches.phase = 'THIRD_PLACE')
  WHERE private_matches.job_id = _job_id
    AND private_matches.is_bye
)
THEN
  RAISE EXCEPTION
    'Uma partida BYE da prévia v8 recebeu indevidamente uma reserva de horário.';
END IF;

IF EXISTS (
  SELECT 1
  FROM public.championship_bracket_knockout_schedule_reservations
    AS reservations
  LEFT JOIN championship_bracket_preview_private.knockout_matches
    AS private_matches
    ON private_matches.job_id = _job_id
    AND private_matches.competition_id =
      reservations.competition_id
    AND private_matches.round_number =
      reservations.round_number
    AND private_matches.slot_number =
      reservations.slot_number
    AND (
      private_matches.phase = 'THIRD_PLACE'
    ) = reservations.is_third_place
  WHERE reservations.bracket_edition_id = edition_id
    AND (
      private_matches.id IS NULL
      OR private_matches.is_bye
    )
)
THEN
  RAISE EXCEPTION
    'Foi persistida uma reserva eliminatória que não corresponde a uma partida real da prévia v8.';
END IF;

IF EXISTS (
  SELECT 1
  FROM public.championship_bracket_matches
    AS bracket_matches
  JOIN championship_bracket_preview_private.knockout_matches
    AS private_matches
    ON private_matches.id = bracket_matches.id
    AND private_matches.job_id = _job_id
  LEFT JOIN public.championship_bracket_knockout_schedule_reservations
    AS reservations
    ON reservations.bracket_edition_id = edition_id
    AND reservations.competition_id =
      bracket_matches.competition_id
    AND reservations.round_number =
      bracket_matches.round_number
    AND reservations.slot_number =
      bracket_matches.slot_number
    AND reservations.is_third_place =
      bracket_matches.is_third_place
  WHERE bracket_matches.bracket_edition_id = edition_id
    AND NOT private_matches.is_bye
    AND (
      reservations.id IS NULL
      OR bracket_matches.planned_scheduled_date
        IS DISTINCT FROM reservations.scheduled_date
      OR bracket_matches.planned_period
        IS DISTINCT FROM reservations.schedule_period
      OR bracket_matches.planned_scheduled_slot
        IS DISTINCT FROM reservations.scheduled_slot
      OR bracket_matches.planned_queue_position
        IS DISTINCT FROM reservations.queue_position
      OR bracket_matches.planned_start_time
        IS DISTINCT FROM (
          reservations.start_at
          AT TIME ZONE 'America/Sao_Paulo'
        )::time
      OR bracket_matches.planned_end_time
        IS DISTINCT FROM (
          reservations.end_at
          AT TIME ZONE 'America/Sao_Paulo'
        )::time
      OR bracket_matches.planned_location_group_id
        IS DISTINCT FROM reservations.location_group_id
      OR bracket_matches.planned_court_group_id
        IS DISTINCT FROM reservations.court_group_id
      OR bracket_matches.planned_location_name
        IS DISTINCT FROM reservations.location_name
      OR bracket_matches.planned_court_name
        IS DISTINCT FROM reservations.court_name
    )
)
THEN
  RAISE EXCEPTION
    'Os campos planned_* do mata-mata divergem da reserva estrutural aprovada pela prévia v8.';
END IF;

  IF (SELECT count(*) FROM public.matches WHERE championship_id=_championship_id AND season_year=job_record.season_year)
      <> (SELECT count(*) FROM championship_bracket_preview_private.matches WHERE job_id=_job_id)
    OR (SELECT count(*) FROM public.championship_bracket_knockout_schedule_reservations WHERE bracket_edition_id=edition_id)
      <> (SELECT count(*) FROM championship_bracket_preview_private.knockout_matches WHERE job_id=_job_id AND NOT is_bye)
  THEN
    RAISE EXCEPTION 'A criação não materializou todas as partidas da prévia v8.';
  END IF;

  SELECT jsonb_build_object(
    'algorithm_version','async-exact-v8',
    'groups',COALESCE((SELECT jsonb_agg(jsonb_build_object('competition',competitions.competition_key,'group',groups.group_number,'teams',(SELECT jsonb_agg(group_teams.team_id ORDER BY group_teams.position) FROM public.championship_bracket_group_teams group_teams WHERE group_teams.group_id=groups.id)) ORDER BY competitions.position,groups.group_number) FROM public.championship_bracket_groups groups JOIN championship_bracket_preview_private.competitions competitions ON competitions.id=groups.competition_id WHERE groups.competition_id IN (SELECT id FROM championship_bracket_preview_private.competitions WHERE job_id=_job_id)),'[]'::jsonb),
    'group_matches',COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'key',matches_table.logical_key,'slot_id',assignments_table.slot_id,
      'home_team_id',public_matches.home_team_id,'away_team_id',public_matches.away_team_id,
      'date',public_matches.scheduled_date,'location_key',slots_table.location_key,'location',public_matches.location,
      'court_key',slots_table.court_key,'court',public_matches.court_name,'start',public_matches.start_time,'end',public_matches.end_time,
      'match_number',assignments_table.match_number
    ) ORDER BY matches_table.logical_key)
      FROM championship_bracket_preview_private.assignments assignments_table
      JOIN championship_bracket_preview_private.matches matches_table ON matches_table.id=assignments_table.match_id
      JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id=assignments_table.slot_id
      JOIN public.matches public_matches ON public_matches.id=matches_table.id
      WHERE assignments_table.job_id=_job_id),'[]'::jsonb),
    'knockout_matches',COALESCE((SELECT jsonb_agg(jsonb_build_object('key',knockout_matches.logical_key,'phase',knockout_matches.phase,'round',knockout_matches.round_number,'slot',knockout_matches.slot_number,'home_source_type',knockout_matches.home_source_type,'home_source',knockout_matches.home_source_reference,'away_source_type',knockout_matches.away_source_type,'away_source',knockout_matches.away_source_reference,'predecessors',array_remove(ARRAY[bracket_matches.source_home_bracket_match_id,bracket_matches.source_away_bracket_match_id]::uuid[],NULL),'is_bye',bracket_matches.is_bye,'date',reservations.scheduled_date,'location_key',reservations.location_group_id,'location',reservations.location_name,'court_key',reservations.court_group_id,'court',reservations.court_name,'start',reservations.start_at,'end',reservations.end_at,'manual_final',COALESCE(reservations.is_manual_final,false)) ORDER BY knockout_matches.round_number,knockout_matches.slot_number,knockout_matches.logical_key) FROM championship_bracket_preview_private.knockout_matches knockout_matches JOIN public.championship_bracket_matches bracket_matches ON bracket_matches.id=knockout_matches.id LEFT JOIN public.championship_bracket_knockout_schedule_reservations reservations ON reservations.bracket_edition_id=edition_id AND reservations.competition_id=knockout_matches.competition_id AND reservations.round_number=knockout_matches.round_number AND reservations.slot_number=knockout_matches.slot_number AND reservations.is_third_place=(knockout_matches.phase='THIRD_PLACE') WHERE knockout_matches.job_id=_job_id),'[]'::jsonb)
  ) INTO persisted_manifest;
  persisted_signature := encode(extensions.digest(convert_to(persisted_manifest::text,'UTF8'),'sha256'),'hex');
  IF persisted_signature <> job_record.generation_signature THEN
    RAISE EXCEPTION 'A programação inserida divergiu estruturalmente da prévia v8; nenhuma alteração foi confirmada.';
  END IF;
  UPDATE public.championships SET status='REVIEW' WHERE id=_championship_id;
  UPDATE championship_bracket_preview_private.jobs SET status='CONSUMED',stage='Campeonato criado',result_edition_id=edition_id,consumed_at=now(),updated_at=now() WHERE id=_job_id;
  RETURN edition_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.create_championship_bracket_from_preview_job_v7(_job_id uuid, _championship_id uuid, _payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '15s'
AS $function$
DECLARE j RECORD; actual_dependency TEXT; edition_id UUID:=gen_random_uuid(); actual_manifest JSONB; actual_signature TEXT; knockout_result JSONB;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_admin_tab_access('matches'::public.admin_panel_tab,true) THEN RAISE EXCEPTION 'Usuário sem permissão para criar o campeonato.'; END IF;
  SELECT * INTO j FROM championship_bracket_preview_private.jobs WHERE id=_job_id FOR UPDATE;
  IF j.status='CONSUMED' AND j.result_edition_id IS NOT NULL THEN RETURN j.result_edition_id; END IF;
  IF j.status<>'COMPLETED' OR j.championship_id<>_championship_id OR j.requested_by<>auth.uid() OR j.expires_at<=now() THEN RAISE EXCEPTION 'A prévia exata não está concluída, pertence a outra configuração ou expirou.'; END IF;
  IF j.algorithm_version <> 'async-exact-v7' THEN RAISE EXCEPTION 'A versão do algoritmo da prévia não é mais aceita. Calcule novamente.'; END IF;
  IF public.resolve_championship_bracket_preview_payload_signature(COALESCE(_payload,'{}'))<>j.payload_signature THEN RAISE EXCEPTION 'A configuração foi alterada desde a prévia. Calcule novamente.'; END IF;
  actual_dependency:=championship_bracket_preview_private.resolve_dependency_signature(_championship_id,_payload);
  IF actual_dependency<>j.dependency_signature THEN RAISE EXCEPTION 'Dados externos usados no cálculo foram alterados. Calcule novamente.'; END IF;
  IF EXISTS(SELECT 1 FROM public.matches WHERE championship_id=_championship_id AND season_year=j.season_year) THEN RAISE EXCEPTION 'Este campeonato já possui jogos cadastrados.'; END IF;

  PERFORM set_config('app.skip_queue_trigger','true',true); PERFORM set_config('app.skip_match_conflict_trigger','true',true);
  INSERT INTO public.championship_bracket_editions(id,championship_id,season_year,status,payload_snapshot,created_by,updated_by)
    VALUES(edition_id,_championship_id,j.season_year,'GROUPS_GENERATED',_payload,auth.uid(),auth.uid());
  INSERT INTO public.championship_bracket_team_registrations(bracket_edition_id,team_id)
    SELECT DISTINCT edition_id,gt.team_id FROM championship_bracket_preview_private.group_teams gt WHERE gt.job_id=_job_id;
  INSERT INTO public.championship_bracket_team_modalities(bracket_edition_id,team_id,sport_id,naipe,division)
    SELECT DISTINCT edition_id,gt.team_id,c.sport_id,c.naipe,c.division FROM championship_bracket_preview_private.group_teams gt
    JOIN championship_bracket_preview_private.groups g ON g.id=gt.group_id JOIN championship_bracket_preview_private.competitions c ON c.id=g.competition_id WHERE gt.job_id=_job_id;
  INSERT INTO public.championship_bracket_competitions(id,bracket_edition_id,sport_id,naipe,division,groups_count,qualifiers_per_group,third_place_mode,should_complete_knockout_with_best_second_placed_teams,knockout_pairing_mode)
    SELECT id,edition_id,sport_id,naipe,division,groups_count,qualifiers_per_group,third_place_mode,best_second,pairing_mode FROM championship_bracket_preview_private.competitions WHERE job_id=_job_id;
  INSERT INTO public.championship_bracket_groups(id,competition_id,group_number) SELECT id,competition_id,group_number FROM championship_bracket_preview_private.groups WHERE job_id=_job_id;
  INSERT INTO public.championship_bracket_group_teams(group_id,team_id,position) SELECT group_id,team_id,position FROM championship_bracket_preview_private.group_teams WHERE job_id=_job_id;

  WITH inserted_days AS (INSERT INTO public.championship_bracket_days(bracket_edition_id,event_date,start_time,end_time,break_start_time,break_end_time)
    SELECT edition_id,(d.value->>'date')::date,(d.value->>'start_time')::time,(d.value->>'end_time')::time,NULLIF(d.value->>'break_start_time','')::time,NULLIF(d.value->>'break_end_time','')::time
    FROM jsonb_array_elements(_payload->'schedule_days') d(value) RETURNING id,event_date),
  inserted_locations AS (INSERT INTO public.championship_bracket_locations(bracket_day_id,name,position,location_group_id)
    SELECT id,l.value->>'name',COALESCE((l.value->>'position')::integer,l.ordinality::integer),(l.value->>'location_key')::uuid
    FROM inserted_days d JOIN LATERAL jsonb_array_elements((SELECT value->'locations' FROM jsonb_array_elements(_payload->'schedule_days') x(value) WHERE (value->>'date')::date=d.event_date)) WITH ORDINALITY l(value,ordinality) ON true RETURNING id,bracket_day_id,name,location_group_id),
  inserted_courts AS (INSERT INTO public.championship_bracket_courts(bracket_location_id,name,position,court_group_id)
    SELECT l.id,c.value->>'name',COALESCE((c.value->>'position')::integer,c.ordinality::integer),(c.value->>'court_key')::uuid
    FROM inserted_locations l JOIN public.championship_bracket_days d ON d.id=l.bracket_day_id
    JOIN LATERAL jsonb_array_elements((SELECT location.value->'courts' FROM jsonb_array_elements(_payload->'schedule_days') day(value)
      CROSS JOIN LATERAL jsonb_array_elements(day.value->'locations') location(value) WHERE (day.value->>'date')::date=d.event_date AND location.value->>'location_key'=l.location_group_id::text)) WITH ORDINALITY c(value,ordinality) ON true RETURNING id,bracket_location_id,name,court_group_id)
  INSERT INTO public.championship_bracket_court_sports(bracket_court_id,sport_id)
    SELECT DISTINCT c.id,s.sport_id FROM inserted_courts c JOIN championship_bracket_preview_private.slots s ON s.job_id=_job_id AND s.court_key=c.court_group_id ON CONFLICT DO NOTHING;
  PERFORM public.sync_championship_bracket_court_sport_preferences(edition_id,_payload);

  INSERT INTO public.matches(id,championship_id,division,naipe,sport_id,home_team_id,away_team_id,location,court_name,scheduled_date,scheduled_slot,queue_position,global_queue_order,start_time,end_time,season_year,status)
    SELECT m.id,_championship_id,c.division,c.naipe,c.sport_id,m.home_team_id,m.away_team_id,s.location_name,s.court_name,s.event_date,
      dense_rank() OVER(PARTITION BY s.event_date ORDER BY s.start_at),row_number() OVER(PARTITION BY s.event_date,c.sport_id,c.naipe,c.division ORDER BY s.start_at,s.location_position,s.court_position),
      row_number() OVER(ORDER BY s.event_date,s.start_at,s.location_position,s.court_position),s.start_at,s.end_at,j.season_year,'SCHEDULED'
    FROM championship_bracket_preview_private.assignments a JOIN championship_bracket_preview_private.matches m ON m.id=a.match_id
    JOIN championship_bracket_preview_private.competitions c ON c.id=m.competition_id JOIN championship_bracket_preview_private.slots s ON s.id=a.slot_id WHERE a.job_id=_job_id;
  INSERT INTO public.championship_bracket_matches(bracket_edition_id,competition_id,group_id,phase,round_number,slot_number,match_id,home_team_id,away_team_id)
    SELECT edition_id,competition_id,group_id,'GROUP_STAGE',round_number,slot_number,id,home_team_id,away_team_id FROM championship_bracket_preview_private.matches WHERE job_id=_job_id;

  knockout_result := public.rebuild_championship_knockout_schedule_reservations(
    edition_id,
    false
  );
  IF COALESCE(NULLIF(knockout_result ->> 'conflict_count','')::integer,0) > 0 THEN
    RAISE EXCEPTION 'As reservas do mata-mata divergiram da prévia; nenhuma alteração foi confirmada.';
  END IF;

  SELECT jsonb_build_object('algorithm_version',j.algorithm_version,'payload_signature',j.payload_signature,'dependency_signature',j.dependency_signature,
    'groups',COALESCE((SELECT jsonb_agg(jsonb_build_object('competition',c.competition_key,'group',g.group_number,'teams',(SELECT jsonb_agg(gt.team_id ORDER BY gt.position) FROM public.championship_bracket_group_teams gt WHERE gt.group_id=g.id)) ORDER BY c.position,g.group_number)
      FROM public.championship_bracket_groups g JOIN championship_bracket_preview_private.competitions c ON c.id=g.competition_id WHERE c.job_id=_job_id),'[]'::jsonb),
    'matches',COALESCE((SELECT jsonb_agg(jsonb_build_object('key',m.logical_key,'competition',c.competition_key,'round',m.round_number,'slot',m.slot_number,'home',pm.home_team_id,'away',pm.away_team_id,'date',pm.scheduled_date,'location',pm.location,'court',pm.court_name,'start',pm.start_time,'end',pm.end_time) ORDER BY pm.scheduled_date,pm.start_time,s.location_position,s.court_position,m.logical_key)
      FROM championship_bracket_preview_private.matches m JOIN championship_bracket_preview_private.competitions c ON c.id=m.competition_id JOIN public.matches pm ON pm.id=m.id JOIN championship_bracket_preview_private.assignments a ON a.match_id=m.id JOIN championship_bracket_preview_private.slots s ON s.id=a.slot_id WHERE m.job_id=_job_id),'[]'::jsonb)) INTO actual_manifest;
  actual_signature:=encode(extensions.digest(convert_to(actual_manifest::text,'UTF8'),'sha256'),'hex');
  IF actual_signature<>j.generation_signature THEN RAISE EXCEPTION 'A programação inserida divergiu da prévia; nenhuma alteração foi confirmada.'; END IF;
  UPDATE public.championships SET status='UPCOMING' WHERE id=_championship_id;
  UPDATE championship_bracket_preview_private.jobs SET status='CONSUMED',stage='Campeonato criado',result_edition_id=edition_id,consumed_at=now(),updated_at=now() WHERE id=_job_id;
  RETURN edition_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_championship_bracket_preview_job_day(_job_id uuid, _date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  result JSONB;
  knockout_record RECORD;
  location_index INTEGER;
  court_index INTEGER;
  entries JSONB;
  display_match_numbers JSONB;
BEGIN
  result := public.get_championship_bracket_preview_job_day_v10(_job_id, _date);
  display_match_numbers := championship_bracket_preview_private.resolve_preview_display_match_numbers(
    _job_id
  );

  FOR knockout_record IN
    SELECT
      knockout_matches.*,
      competitions_table.sport_id,
      competitions_table.naipe,
      competitions_table.division
    FROM championship_bracket_preview_private.knockout_matches
    JOIN championship_bracket_preview_private.competitions AS competitions_table
      ON competitions_table.id = knockout_matches.competition_id
    WHERE knockout_matches.job_id = _job_id
      AND knockout_matches.scheduled_date = _date
      AND NOT knockout_matches.is_bye
    ORDER BY knockout_matches.start_at, knockout_matches.logical_key
  LOOP
    SELECT
      location_item.ordinality::INTEGER - 1,
      court_item.ordinality::INTEGER - 1
    INTO location_index, court_index
    FROM jsonb_array_elements(COALESCE(result -> 'locations', '[]'::JSONB))
      WITH ORDINALITY location_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(
      COALESCE(location_item.value -> 'courts', '[]'::JSONB)
    ) WITH ORDINALITY court_item(value, ordinality)
    WHERE location_item.value ->> 'location_key' = knockout_record.location_key::TEXT
      AND court_item.value ->> 'court_key' = knockout_record.court_key::TEXT
    LIMIT 1;

    IF location_index IS NULL THEN
      CONTINUE;
    END IF;

    SELECT jsonb_agg(
      CASE
        WHEN item.value ->> 'type' = 'MATCH'
          AND item.value ->> 'match_kind' = 'KNOCKOUT'
          AND item.value ->> 'sport_id' = knockout_record.sport_id::TEXT
          AND COALESCE(item.value ->> 'naipe', '') = COALESCE(
            knockout_record.naipe::TEXT,
            ''
          )
          AND COALESCE(item.value ->> 'division', '') = COALESCE(
            knockout_record.division::TEXT,
            ''
          )
          AND item.value ->> 'phase' = knockout_record.phase
          AND item.value ->> 'start_time' = to_char(
            knockout_record.start_at AT TIME ZONE 'America/Sao_Paulo',
            'HH24:MI'
          )
          AND COALESCE(item.value ->> 'reason', '') = format(
            '%s × %s',
            knockout_record.home_source_reference,
            knockout_record.away_source_reference
          )
        THEN item.value || jsonb_strip_nulls(jsonb_build_object(
          'match_number',
          NULLIF(
            display_match_numbers ->> knockout_record.id::TEXT,
            ''
          )::INTEGER,
          'home_source_match_number',
          NULLIF(
            display_match_numbers ->> regexp_replace(
              knockout_record.home_source_reference,
              '^(WINNER|LOSER)_OF_',
              ''
            ),
            ''
          )::INTEGER,
          'away_source_match_number',
          NULLIF(
            display_match_numbers ->> regexp_replace(
              knockout_record.away_source_reference,
              '^(WINNER|LOSER)_OF_',
              ''
            ),
            ''
          )::INTEGER
        ))
        ELSE item.value
      END
      ORDER BY item.ordinality
    )
    INTO entries
    FROM jsonb_array_elements(
      COALESCE(
        result #> ARRAY[
          'locations',
          location_index::TEXT,
          'courts',
          court_index::TEXT,
          'entries'
        ],
        '[]'::JSONB
      )
    ) WITH ORDINALITY item(value, ordinality);

    result := jsonb_set(
      result,
      ARRAY[
        'locations',
        location_index::TEXT,
        'courts',
        court_index::TEXT,
        'entries'
      ],
      COALESCE(entries, '[]'::JSONB)
    );
  END LOOP;

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_championship_bracket_preview_job_day_v10(_job_id uuid, _date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  result JSONB;
  knockout_record RECORD;
  location_index INTEGER;
  court_index INTEGER;
  entries JSONB;
  display_match_numbers JSONB;
BEGIN
  result := public.get_championship_bracket_preview_job_day_v9(_job_id, _date);

  WITH RECURSIVE scheduled_matches AS (
    SELECT
      matches_table.id AS match_id,
      matches_table.slot_number AS fixed_match_number,
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
  INTO display_match_numbers
  FROM numbered_matches;

  FOR knockout_record IN
    SELECT
      knockout_matches.*,
      competitions_table.sport_id,
      competitions_table.naipe,
      competitions_table.division
    FROM championship_bracket_preview_private.knockout_matches
    JOIN championship_bracket_preview_private.competitions AS competitions_table
      ON competitions_table.id = knockout_matches.competition_id
    WHERE knockout_matches.job_id = _job_id
      AND knockout_matches.scheduled_date = _date
      AND NOT knockout_matches.is_bye
    ORDER BY knockout_matches.start_at, knockout_matches.logical_key
  LOOP
    SELECT
      location_item.ordinality::INTEGER - 1,
      court_item.ordinality::INTEGER - 1
    INTO location_index, court_index
    FROM jsonb_array_elements(COALESCE(result -> 'locations', '[]'::JSONB))
      WITH ORDINALITY location_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(
      COALESCE(location_item.value -> 'courts', '[]'::JSONB)
    ) WITH ORDINALITY court_item(value, ordinality)
    WHERE location_item.value ->> 'location_key' = knockout_record.location_key::TEXT
      AND court_item.value ->> 'court_key' = knockout_record.court_key::TEXT
    LIMIT 1;

    IF location_index IS NULL THEN
      CONTINUE;
    END IF;

    SELECT jsonb_agg(
      CASE
        WHEN item.value ->> 'type' = 'MATCH'
          AND item.value ->> 'match_kind' = 'KNOCKOUT'
          AND item.value ->> 'sport_id' = knockout_record.sport_id::TEXT
          AND COALESCE(item.value ->> 'naipe', '') = COALESCE(
            knockout_record.naipe::TEXT,
            ''
          )
          AND COALESCE(item.value ->> 'division', '') = COALESCE(
            knockout_record.division::TEXT,
            ''
          )
          AND item.value ->> 'phase' = knockout_record.phase
          AND item.value ->> 'start_time' = to_char(
            knockout_record.start_at AT TIME ZONE 'America/Sao_Paulo',
            'HH24:MI'
          )
          AND COALESCE(item.value ->> 'reason', '') = format(
            '%s × %s',
            knockout_record.home_source_reference,
            knockout_record.away_source_reference
          )
        THEN item.value || jsonb_strip_nulls(jsonb_build_object(
          'match_number',
          NULLIF(
            display_match_numbers ->> knockout_record.id::TEXT,
            ''
          )::INTEGER,
          'home_source_match_number',
          NULLIF(
            display_match_numbers ->> regexp_replace(
              knockout_record.home_source_reference,
              '^(WINNER|LOSER)_OF_',
              ''
            ),
            ''
          )::INTEGER,
          'away_source_match_number',
          NULLIF(
            display_match_numbers ->> regexp_replace(
              knockout_record.away_source_reference,
              '^(WINNER|LOSER)_OF_',
              ''
            ),
            ''
          )::INTEGER
        ))
        ELSE item.value
      END
      ORDER BY item.ordinality
    )
    INTO entries
    FROM jsonb_array_elements(
      COALESCE(
        result #> ARRAY[
          'locations',
          location_index::TEXT,
          'courts',
          court_index::TEXT,
          'entries'
        ],
        '[]'::JSONB
      )
    ) WITH ORDINALITY item(value, ordinality);

    result := jsonb_set(
      result,
      ARRAY[
        'locations',
        location_index::TEXT,
        'courts',
        court_index::TEXT,
        'entries'
      ],
      COALESCE(entries, '[]'::JSONB)
    );
  END LOOP;

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_championship_bracket_preview_job_day_v7(_job_id uuid, _date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  job_record RECORD;
  result JSONB;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id;

  IF job_record.id IS NULL
    OR (
      job_record.requested_by <> auth.uid()
      AND NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true)
    )
  THEN
    RAISE EXCEPTION 'Job de prévia não encontrado.';
  END IF;

  WITH day_config AS (
    SELECT day_item.value AS day
    FROM jsonb_array_elements(COALESCE(job_record.payload -> 'schedule_days', '[]'::jsonb)) day_item(value)
    WHERE day_item.value ->> 'date' = _date::text
    LIMIT 1
  ), court_config AS (
    SELECT
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
      day_config.day
    FROM day_config
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(day_config.day -> 'locations', '[]'::jsonb)) WITH ORDINALITY location_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(location_item.value -> 'courts', '[]'::jsonb)) WITH ORDINALITY court_item(value, ordinality)
  ), match_entries AS (
    SELECT
      slots_table.location_key,
      slots_table.court_key,
      slots_table.start_at,
      slots_table.end_at,
      20 AS entry_order,
      jsonb_build_object(
        'type', 'MATCH',
        'start_time', to_char(slots_table.start_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
        'end_time', to_char(slots_table.end_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
        'duration_minutes', (EXTRACT(EPOCH FROM (slots_table.end_at - slots_table.start_at)) / 60)::integer,
        'match_kind', 'GROUP_STAGE',
        'match_number', assignments_table.match_number,
        'sport_id', competitions_table.sport_id,
        'sport_name', competitions_table.sport_name,
        'naipe', competitions_table.naipe,
        'division', competitions_table.division,
        'phase', 'GROUP_STAGE',
        'phase_label', 'Grupos',
        'group_number', groups_table.group_number,
        'round_number', matches_table.round_number,
        'reason_code', NULL,
        'projected', false,
        'manual_final', false,
        'reason', NULL
      ) AS entry
    FROM championship_bracket_preview_private.assignments AS assignments_table
    JOIN championship_bracket_preview_private.slots AS slots_table
      ON slots_table.id = assignments_table.slot_id
    JOIN championship_bracket_preview_private.matches AS matches_table
      ON matches_table.id = assignments_table.match_id
    JOIN championship_bracket_preview_private.competitions AS competitions_table
      ON competitions_table.id = matches_table.competition_id
    JOIN championship_bracket_preview_private.groups AS groups_table
      ON groups_table.id = matches_table.group_id
    WHERE assignments_table.job_id = _job_id
      AND slots_table.event_date = _date
  ), break_entries AS (
    SELECT
      court_config.location_key,
      court_config.court_key,
      public.combine_bracket_schedule_timestamp(
        _date,
        (court_config.day ->> 'break_start_time')::time
      ) AS start_at,
      public.combine_bracket_schedule_timestamp(
        _date,
        (court_config.day ->> 'break_end_time')::time
      ) AS end_at,
      10 AS entry_order,
      jsonb_build_object(
        'type', 'BREAK',
        'start_time', court_config.day ->> 'break_start_time',
        'end_time', court_config.day ->> 'break_end_time',
        'duration_minutes', (
          EXTRACT(EPOCH FROM (
            public.combine_bracket_schedule_timestamp(
              _date,
              (court_config.day ->> 'break_end_time')::time
            ) - public.combine_bracket_schedule_timestamp(
              _date,
              (court_config.day ->> 'break_start_time')::time
            )
          )) / 60
        )::integer,
        'match_kind', NULL,
        'match_number', NULL,
        'sport_id', NULL,
        'sport_name', NULL,
        'naipe', NULL,
        'division', NULL,
        'phase', NULL,
        'phase_label', NULL,
        'group_number', NULL,
        'round_number', NULL,
        'reason_code', 'SCHEDULE_BREAK',
        'projected', false,
        'manual_final', false,
        'reason', 'Intervalo da programação'
      ) AS entry
    FROM court_config
    WHERE NULLIF(court_config.day ->> 'break_start_time', '') IS NOT NULL
      AND NULLIF(court_config.day ->> 'break_end_time', '') IS NOT NULL
  ), resource_lock_entries AS (
    SELECT
      court_config.location_key,
      court_config.court_key,
      public.combine_bracket_schedule_timestamp(
        _date,
        (lock_item.value ->> 'start_time')::time
      ) AS start_at,
      public.combine_bracket_schedule_timestamp(
        _date,
        (lock_item.value ->> 'end_time')::time
      ) AS end_at,
      10 AS entry_order,
      jsonb_build_object(
        'type', 'RESERVATION',
        'start_time', lock_item.value ->> 'start_time',
        'end_time', lock_item.value ->> 'end_time',
        'duration_minutes', (
          EXTRACT(EPOCH FROM (
            public.combine_bracket_schedule_timestamp(
              _date,
              (lock_item.value ->> 'end_time')::time
            ) - public.combine_bracket_schedule_timestamp(
              _date,
              (lock_item.value ->> 'start_time')::time
            )
          )) / 60
        )::integer,
        'match_kind', NULL,
        'match_number', NULL,
        'sport_id', NULLIF(lock_item.value ->> 'sport_id', '')::uuid,
        'sport_name', sports_table.name,
        'naipe', NULLIF(lock_item.value ->> 'naipe', '')::public.match_naipe,
        'division', NULLIF(lock_item.value ->> 'division', '')::public.team_division,
        'phase', NULL,
        'phase_label', NULL,
        'group_number', NULL,
        'round_number', NULL,
        'reason_code', COALESCE(lock_item.value ->> 'lock_mode', 'RESOURCE_LOCK'),
        'projected', false,
        'manual_final', false,
        'reason', 'Reserva fixa'
      ) AS entry
    FROM court_config
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(job_record.payload -> 'resource_locks', '[]'::jsonb)) lock_item(value)
    LEFT JOIN public.sports AS sports_table
      ON sports_table.id = NULLIF(lock_item.value ->> 'sport_id', '')::uuid
    WHERE lock_item.value ->> 'date' = _date::text
      AND lock_item.value ->> 'location_key' = court_config.location_key::text
      AND lock_item.value ->> 'court_key' = court_config.court_key::text
      AND NULLIF(lock_item.value ->> 'start_time', '') IS NOT NULL
      AND NULLIF(lock_item.value ->> 'end_time', '') IS NOT NULL
      AND NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(job_record.payload -> 'individual_session_configs', '[]'::jsonb)) session_item(value)
        WHERE session_item.value ->> 'scheduled_date' = _date::text
          AND session_item.value ->> 'location_key' = court_config.location_key::text
          AND session_item.value ->> 'court_key' = court_config.court_key::text
          AND session_item.value ->> 'start_time' = lock_item.value ->> 'start_time'
          AND session_item.value ->> 'end_time' = lock_item.value ->> 'end_time'
          AND COALESCE(session_item.value ->> 'sport_id', '') = COALESCE(lock_item.value ->> 'sport_id', '')
      )
  ), individual_session_entries AS (
    SELECT
      court_config.location_key,
      court_config.court_key,
      public.combine_bracket_schedule_timestamp(
        _date,
        (session_item.value ->> 'start_time')::time
      ) AS start_at,
      public.combine_bracket_schedule_timestamp(
        _date,
        (session_item.value ->> 'end_time')::time
      ) AS end_at,
      10 AS entry_order,
      jsonb_build_object(
        'type', 'INDIVIDUAL_SESSION',
        'start_time', session_item.value ->> 'start_time',
        'end_time', session_item.value ->> 'end_time',
        'duration_minutes', (
          EXTRACT(EPOCH FROM (
            public.combine_bracket_schedule_timestamp(
              _date,
              (session_item.value ->> 'end_time')::time
            ) - public.combine_bracket_schedule_timestamp(
              _date,
              (session_item.value ->> 'start_time')::time
            )
          )) / 60
        )::integer,
        'match_kind', NULL,
        'match_number', NULL,
        'sport_id', NULLIF(session_item.value ->> 'sport_id', '')::uuid,
        'sport_name', sports_table.name,
        'naipe', NULLIF(session_item.value ->> 'naipe', '')::public.match_naipe,
        'division', NULLIF(session_item.value ->> 'division', '')::public.team_division,
        'phase', NULL,
        'phase_label', NULL,
        'group_number', NULL,
        'round_number', NULL,
        'reason_code', 'INDIVIDUAL_SESSION',
        'projected', false,
        'manual_final', false,
        'reason', 'Sessão de modalidade individual'
      ) AS entry
    FROM court_config
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(job_record.payload -> 'individual_session_configs', '[]'::jsonb)) session_item(value)
    LEFT JOIN public.sports AS sports_table
      ON sports_table.id = NULLIF(session_item.value ->> 'sport_id', '')::uuid
    WHERE session_item.value ->> 'scheduled_date' = _date::text
      AND session_item.value ->> 'location_key' = court_config.location_key::text
      AND session_item.value ->> 'court_key' = court_config.court_key::text
      AND NULLIF(session_item.value ->> 'start_time', '') IS NOT NULL
      AND NULLIF(session_item.value ->> 'end_time', '') IS NOT NULL
  ), manual_final_entries AS (
    SELECT
      court_config.location_key,
      court_config.court_key,
      public.combine_bracket_schedule_timestamp(
        _date,
        (block_item.value ->> 'start_time')::time
      ) AS start_at,
      public.combine_bracket_schedule_timestamp(
        _date,
        (block_item.value ->> 'end_time')::time
      ) AS end_at,
      10 AS entry_order,
      jsonb_build_object(
        'type', 'RESERVATION',
        'start_time', block_item.value ->> 'start_time',
        'end_time', block_item.value ->> 'end_time',
        'duration_minutes', (
          EXTRACT(EPOCH FROM (
            public.combine_bracket_schedule_timestamp(
              _date,
              (block_item.value ->> 'end_time')::time
            ) - public.combine_bracket_schedule_timestamp(
              _date,
              (block_item.value ->> 'start_time')::time
            )
          )) / 60
        )::integer,
        'match_kind', 'MANUAL_FINAL',
        'match_number', NULL,
        'sport_id', NULLIF(block_item.value ->> 'sport_id', '')::uuid,
        'sport_name', sports_table.name,
        'naipe', NULL,
        'division', NULL,
        'phase', COALESCE(block_item.value ->> 'phase', 'FINAL'),
        'phase_label', 'Final',
        'group_number', NULL,
        'round_number', NULL,
        'reason_code', 'MANUAL_FINAL_BLOCK',
        'projected', false,
        'manual_final', true,
        'reason', 'Final programada manualmente'
      ) AS entry
    FROM court_config
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(job_record.payload -> 'knockout_program_blocks', '[]'::jsonb)) block_item(value)
    LEFT JOIN public.sports AS sports_table
      ON sports_table.id = NULLIF(block_item.value ->> 'sport_id', '')::uuid
    WHERE block_item.value ->> 'date' = _date::text
      AND block_item.value ->> 'location_key' = court_config.location_key::text
      AND block_item.value ->> 'court_key' = court_config.court_key::text
      AND NULLIF(block_item.value ->> 'start_time', '') IS NOT NULL
      AND NULLIF(block_item.value ->> 'end_time', '') IS NOT NULL
  ), fixed_entries AS (
    SELECT * FROM break_entries
    UNION ALL
    SELECT * FROM resource_lock_entries
    UNION ALL
    SELECT * FROM individual_session_entries
    UNION ALL
    SELECT * FROM manual_final_entries
  ), base_free_intervals AS (
    SELECT
      court_config.location_key,
      court_config.court_key,
      free_interval.start_at,
      free_interval.end_at,
      row_number() OVER (
        PARTITION BY court_config.location_key, court_config.court_key
        ORDER BY free_interval.start_at
      ) AS interval_index
    FROM court_config
    CROSS JOIN LATERAL championship_bracket_preview_private.resolve_court_free_intervals(
      job_record.payload,
      _date,
      court_config.location_key,
      court_config.court_key
    ) free_interval
  ), interval_matches AS (
    SELECT
      base_free_intervals.location_key,
      base_free_intervals.court_key,
      base_free_intervals.interval_index,
      base_free_intervals.start_at AS interval_start,
      base_free_intervals.end_at AS interval_end,
      match_entries.start_at,
      match_entries.end_at
    FROM base_free_intervals
    LEFT JOIN match_entries
      ON match_entries.location_key = base_free_intervals.location_key
      AND match_entries.court_key = base_free_intervals.court_key
      AND match_entries.start_at >= base_free_intervals.start_at
      AND match_entries.end_at <= base_free_intervals.end_at
  ), free_window_ranges AS (
    SELECT
      interval_matches.location_key,
      interval_matches.court_key,
      interval_matches.interval_start AS start_at,
      COALESCE(min(interval_matches.start_at), interval_matches.interval_end) AS end_at
    FROM interval_matches
    GROUP BY
      interval_matches.location_key,
      interval_matches.court_key,
      interval_matches.interval_index,
      interval_matches.interval_start,
      interval_matches.interval_end

    UNION ALL

    SELECT
      interval_matches.location_key,
      interval_matches.court_key,
      interval_matches.end_at,
      lead(
        interval_matches.start_at,
        1,
        interval_matches.interval_end
      ) OVER (
        PARTITION BY
          interval_matches.location_key,
          interval_matches.court_key,
          interval_matches.interval_index
        ORDER BY interval_matches.start_at
      )
    FROM interval_matches
    WHERE interval_matches.start_at IS NOT NULL
  ), free_window_entries AS (
    SELECT
      free_window_ranges.location_key,
      free_window_ranges.court_key,
      free_window_ranges.start_at,
      free_window_ranges.end_at,
      30 AS entry_order,
      jsonb_build_object(
        'type', 'EMPTY',
        'start_time', to_char(free_window_ranges.start_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
        'end_time', to_char(free_window_ranges.end_at AT TIME ZONE 'America/Sao_Paulo', 'HH24:MI'),
        'duration_minutes', (EXTRACT(EPOCH FROM (free_window_ranges.end_at - free_window_ranges.start_at)) / 60)::integer,
        'match_kind', NULL,
        'match_number', NULL,
        'sport_id', NULL,
        'sport_name', NULL,
        'naipe', NULL,
        'division', NULL,
        'phase', NULL,
        'phase_label', NULL,
        'group_number', NULL,
        'round_number', NULL,
        'reason_code', 'FREE_WINDOW',
        'projected', false,
        'manual_final', false,
        'reason', NULL
      ) AS entry
    FROM free_window_ranges
    WHERE free_window_ranges.end_at > free_window_ranges.start_at
  ), all_entries AS (
    SELECT * FROM match_entries
    UNION ALL
    SELECT * FROM fixed_entries
    UNION ALL
    SELECT * FROM free_window_entries
  ), court_metrics AS (
    SELECT
      court_config.location_key,
      court_config.location_name,
      court_config.location_position,
      court_config.court_key,
      court_config.court_name,
      court_config.court_position,
      COALESCE((
        SELECT sum(EXTRACT(EPOCH FROM (base_free_intervals.end_at - base_free_intervals.start_at)) / 60)::integer
        FROM base_free_intervals
        WHERE base_free_intervals.location_key = court_config.location_key
          AND base_free_intervals.court_key = court_config.court_key
      ), 0) AS available_minutes,
      COALESCE((
        SELECT sum(EXTRACT(EPOCH FROM (match_entries.end_at - match_entries.start_at)) / 60)::integer
        FROM match_entries
        WHERE match_entries.location_key = court_config.location_key
          AND match_entries.court_key = court_config.court_key
      ), 0) AS occupied_minutes,
      COALESCE((
        SELECT count(*)::integer
        FROM free_window_entries
        WHERE free_window_entries.location_key = court_config.location_key
          AND free_window_entries.court_key = court_config.court_key
      ), 0) AS free_windows,
      COALESCE((
        SELECT jsonb_agg(
          all_entries.entry
          ORDER BY all_entries.start_at, all_entries.entry_order, all_entries.end_at
        )
        FROM all_entries
        WHERE all_entries.location_key = court_config.location_key
          AND all_entries.court_key = court_config.court_key
      ), '[]'::jsonb) AS entries
    FROM court_config
  ), location_rows AS (
    SELECT
      court_metrics.location_key,
      court_metrics.location_name,
      court_metrics.location_position,
      jsonb_agg(
        jsonb_build_object(
          'court_key', court_metrics.court_key,
          'court_name', court_metrics.court_name,
          'occupied_minutes', court_metrics.occupied_minutes,
          'available_minutes', court_metrics.available_minutes,
          'utilization_percentage', round(
            100 * court_metrics.occupied_minutes::numeric /
            GREATEST(court_metrics.available_minutes, 1),
            2
          ),
          'free_windows', court_metrics.free_windows,
          'entries', court_metrics.entries
        )
        ORDER BY court_metrics.court_position
      ) AS courts
    FROM court_metrics
    GROUP BY
      court_metrics.location_key,
      court_metrics.location_name,
      court_metrics.location_position
  )
  SELECT jsonb_build_object(
    'date', _date,
    'start_time', day_config.day ->> 'start_time',
    'end_time', day_config.day ->> 'end_time',
    'breaks', '[]'::jsonb,
    'occupied_minutes', COALESCE((SELECT sum(court_metrics.occupied_minutes) FROM court_metrics), 0),
    'available_minutes', COALESCE((SELECT sum(court_metrics.available_minutes) FROM court_metrics), 0),
    'free_windows', COALESCE((SELECT sum(court_metrics.free_windows) FROM court_metrics), 0),
    'utilization_percentage', round(
      100 * COALESCE((SELECT sum(court_metrics.occupied_minutes) FROM court_metrics), 0)::numeric /
      GREATEST(COALESCE((SELECT sum(court_metrics.available_minutes) FROM court_metrics), 0), 1),
      2
    ),
    'locations', COALESCE((
      SELECT jsonb_agg(
        jsonb_build_object(
          'location_key', location_rows.location_key,
          'location_name', location_rows.location_name,
          'courts', location_rows.courts
        )
        ORDER BY location_rows.location_position
      )
      FROM location_rows
    ), '[]'::jsonb)
  )
  INTO result
  FROM day_config;

  RETURN COALESCE(
    result,
    jsonb_build_object(
      'date', _date,
      'start_time', NULL,
      'end_time', NULL,
      'breaks', '[]'::jsonb,
      'occupied_minutes', 0,
      'available_minutes', 0,
      'free_windows', 0,
      'utilization_percentage', 0,
      'locations', '[]'::jsonb
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_championship_bracket_preview_job_day_v8(_job_id uuid, _date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE result JSONB; knockout_record RECORD; scheduled_match RECORD; location_index INTEGER; court_index INTEGER; entries JSONB;
BEGIN
  result:=public.get_championship_bracket_preview_job_day_v7(_job_id,_date);
  FOR knockout_record IN SELECT knockout_matches.*,competitions.sport_id,competitions.sport_name,competitions.naipe,competitions.division FROM championship_bracket_preview_private.knockout_matches knockout_matches JOIN championship_bracket_preview_private.competitions competitions ON competitions.id=knockout_matches.competition_id WHERE knockout_matches.job_id=_job_id AND knockout_matches.scheduled_date=_date AND NOT knockout_matches.is_bye ORDER BY knockout_matches.start_at,knockout_matches.logical_key LOOP
    SELECT location_item.ordinality::integer-1,court_item.ordinality::integer-1 INTO location_index,court_index FROM jsonb_array_elements(COALESCE(result->'locations','[]'::jsonb)) WITH ORDINALITY location_item(value,ordinality) CROSS JOIN LATERAL jsonb_array_elements(COALESCE(location_item.value->'courts','[]'::jsonb)) WITH ORDINALITY court_item(value,ordinality) WHERE location_item.value->>'location_key'=knockout_record.location_key::text AND court_item.value->>'court_key'=knockout_record.court_key::text LIMIT 1;
    IF location_index IS NULL THEN CONTINUE; END IF;
    SELECT COALESCE(jsonb_agg(item.value ORDER BY item.value->>'start_time',item.value->>'end_time'),'[]'::jsonb) INTO entries FROM jsonb_array_elements(COALESCE(result#>ARRAY['locations',location_index::text,'courts',court_index::text,'entries'],'[]'::jsonb)) item(value) WHERE COALESCE(item.value->>'reason_code','') <> 'MANUAL_FINAL_BLOCK';
    entries:=entries||jsonb_build_array(jsonb_build_object('type','MATCH','start_time',to_char(knockout_record.start_at AT TIME ZONE 'America/Sao_Paulo','HH24:MI'),'end_time',to_char(knockout_record.end_at AT TIME ZONE 'America/Sao_Paulo','HH24:MI'),'duration_minutes',knockout_record.duration_minutes,'match_kind','KNOCKOUT','match_number',NULL,'sport_id',knockout_record.sport_id,'sport_name',knockout_record.sport_name,'naipe',knockout_record.naipe,'division',knockout_record.division,'phase',knockout_record.phase,'phase_label',knockout_record.phase,'group_number',NULL,'round_number',knockout_record.round_number,'reason_code',NULL,'reason',format('%s × %s',knockout_record.home_source_reference,knockout_record.away_source_reference),'projected',true,'manual_final',knockout_record.manual_final));
    SELECT jsonb_agg(item.value ORDER BY item.value->>'start_time',item.value->>'end_time') INTO entries FROM jsonb_array_elements(entries) item(value);
    result:=jsonb_set(result,ARRAY['locations',location_index::text,'courts',court_index::text,'entries'],entries);
  END LOOP;
  FOR scheduled_match IN
    SELECT slots_table.location_key,slots_table.court_key,assignments_table.match_number,
      matches_table.home_team_id,home_teams_table.name AS home_team_name,
      matches_table.away_team_id,away_teams_table.name AS away_team_name
    FROM championship_bracket_preview_private.assignments assignments_table
    JOIN championship_bracket_preview_private.slots slots_table ON slots_table.id=assignments_table.slot_id
    JOIN championship_bracket_preview_private.matches matches_table ON matches_table.id=assignments_table.match_id
    JOIN public.teams home_teams_table ON home_teams_table.id=matches_table.home_team_id
    JOIN public.teams away_teams_table ON away_teams_table.id=matches_table.away_team_id
    WHERE assignments_table.job_id=_job_id AND slots_table.event_date=_date
  LOOP
    SELECT location_item.ordinality::integer-1,court_item.ordinality::integer-1 INTO location_index,court_index
    FROM jsonb_array_elements(COALESCE(result->'locations','[]'::jsonb)) WITH ORDINALITY location_item(value,ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(location_item.value->'courts','[]'::jsonb)) WITH ORDINALITY court_item(value,ordinality)
    WHERE location_item.value->>'location_key'=scheduled_match.location_key::text
      AND court_item.value->>'court_key'=scheduled_match.court_key::text LIMIT 1;
    IF location_index IS NULL THEN CONTINUE; END IF;
    SELECT COALESCE(jsonb_agg(
      CASE WHEN item.value->>'type'='MATCH' AND item.value->>'match_kind'='GROUP_STAGE'
          AND item.value->>'match_number'=scheduled_match.match_number::text
        THEN item.value || jsonb_build_object(
          'home_team_id',scheduled_match.home_team_id,'home_team_name',scheduled_match.home_team_name,
          'away_team_id',scheduled_match.away_team_id,'away_team_name',scheduled_match.away_team_name
        )
        ELSE item.value END
      ORDER BY item.ordinality
    ),'[]'::jsonb) INTO entries
    FROM jsonb_array_elements(COALESCE(result#>ARRAY['locations',location_index::text,'courts',court_index::text,'entries'],'[]'::jsonb)) WITH ORDINALITY item(value,ordinality);
    result:=jsonb_set(result,ARRAY['locations',location_index::text,'courts',court_index::text,'entries'],entries);
  END LOOP;
  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_championship_bracket_preview_job_day_v9(_job_id uuid, _date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  result JSONB;
  scheduled_match RECORD;
  location_index INTEGER;
  court_index INTEGER;
  entries JSONB;
BEGIN
  result := public.get_championship_bracket_preview_job_day_v8(_job_id, _date);

  FOR scheduled_match IN
    SELECT
      slots_table.location_key,
      slots_table.court_key,
      assignments_table.match_number,
      matches_table.home_team_id,
      home_teams_table.name AS home_team_name,
      matches_table.away_team_id,
      away_teams_table.name AS away_team_name
    FROM championship_bracket_preview_private.assignments AS assignments_table
    JOIN championship_bracket_preview_private.slots AS slots_table
      ON slots_table.id = assignments_table.slot_id
    JOIN championship_bracket_preview_private.matches AS matches_table
      ON matches_table.id = assignments_table.match_id
    JOIN public.teams AS home_teams_table
      ON home_teams_table.id = matches_table.home_team_id
    JOIN public.teams AS away_teams_table
      ON away_teams_table.id = matches_table.away_team_id
    WHERE assignments_table.job_id = _job_id
      AND slots_table.event_date = _date
  LOOP
    SELECT
      location_item.ordinality::integer - 1,
      court_item.ordinality::integer - 1
    INTO location_index, court_index
    FROM jsonb_array_elements(COALESCE(result -> 'locations', '[]'::jsonb))
      WITH ORDINALITY location_item(value, ordinality)
    CROSS JOIN LATERAL jsonb_array_elements(
      COALESCE(location_item.value -> 'courts', '[]'::jsonb)
    ) WITH ORDINALITY court_item(value, ordinality)
    WHERE location_item.value ->> 'location_key' = scheduled_match.location_key::text
      AND court_item.value ->> 'court_key' = scheduled_match.court_key::text
    LIMIT 1;

    IF location_index IS NULL THEN
      CONTINUE;
    END IF;

    SELECT jsonb_agg(
      CASE
        WHEN item.value ->> 'type' = 'MATCH'
          AND item.value ->> 'match_kind' = 'GROUP_STAGE'
          AND item.value ->> 'match_number' = scheduled_match.match_number::text
        THEN item.value || jsonb_build_object(
          'home_team_id', scheduled_match.home_team_id,
          'home_team_name', scheduled_match.home_team_name,
          'away_team_id', scheduled_match.away_team_id,
          'away_team_name', scheduled_match.away_team_name
        )
        ELSE item.value
      END
      ORDER BY item.ordinality
    )
    INTO entries
    FROM jsonb_array_elements(
      COALESCE(
        result #> ARRAY[
          'locations',
          location_index::text,
          'courts',
          court_index::text,
          'entries'
        ],
        '[]'::jsonb
      )
    ) WITH ORDINALITY item(value, ordinality);

    result := jsonb_set(
      result,
      ARRAY[
        'locations',
        location_index::text,
        'courts',
        court_index::text,
        'entries'
      ],
      COALESCE(entries, '[]'::jsonb)
    );
  END LOOP;

  RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_championship_bracket_preview_job_status(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  job_record RECORD;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id;

  IF job_record.id IS NULL
    OR (
      job_record.requested_by <> auth.uid()
      AND NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true)
    )
  THEN
    RAISE EXCEPTION 'Job de prévia não encontrado.';
  END IF;

  RETURN jsonb_build_object(
    'job_id', job_record.id,
    'championship_id', job_record.championship_id,
    'season_year', job_record.season_year,
    'status', job_record.status,
    'stage', job_record.stage,
    'current_date', job_record.current_processing_date,
    'progress_percentage', job_record.progress_percentage,
    'processed_slots', job_record.processed_slots,
    'total_slots', job_record.total_slots,
    'attempt_count', job_record.attempt_count,
    'error_message', job_record.error_message,
    'summary', job_record.summary,
    'diagnostics', job_record.diagnostics,
    'payload_signature', job_record.payload_signature,
    'dependency_signature', job_record.dependency_signature,
    'algorithm_version', job_record.algorithm_version,
    'generation_signature', job_record.generation_signature,
    'created_at', job_record.created_at,
    'started_at', job_record.started_at,
    'completed_at', job_record.completed_at,
    'expires_at', job_record.expires_at,
    'is_valid_for_creation',
      job_record.status = 'COMPLETED'
      AND job_record.algorithm_version = 'async-exact-v8'
      AND job_record.generation_signature IS NOT NULL
      AND job_record.expires_at > now()
      AND jsonb_array_length(job_record.diagnostics) = 0,
    'events', COALESCE(
      (
        WITH event_history AS (
          SELECT
            job_record.created_at AS occurred_at,
            0 AS event_order,
            jsonb_build_object(
              'event_type', 'STAGE_CHANGED',
              'stage', 'QUEUED',
              'status', 'QUEUED',
              'occurred_at', job_record.created_at,
              'details', '{}'::jsonb
            ) AS event

          UNION ALL

          SELECT
            COALESCE(job_record.started_at, job_record.created_at),
            1,
            jsonb_build_object(
              'event_type', 'STAGE_CHANGED',
              'stage', 'SCHEDULING_GROUPS',
              'status', 'SCHEDULING',
              'occurred_at', COALESCE(job_record.started_at, job_record.created_at),
              'details', '{}'::jsonb
            )
          WHERE job_record.started_at IS NOT NULL

          UNION ALL

          SELECT
            events_table.occurred_at,
            2,
            jsonb_build_object(
              'event_type', events_table.event_type,
              'stage', events_table.stage,
              'status', 'SCHEDULING',
              'occurred_at', events_table.occurred_at,
              'details', events_table.details
            )
          FROM championship_bracket_preview_private.job_events events_table
          WHERE events_table.job_id = job_record.id

          UNION ALL

          SELECT
            job_record.completed_at,
            3,
            jsonb_build_object(
              'event_type', 'STAGE_CHANGED',
              'stage', job_record.stage,
              'status', job_record.status,
              'occurred_at', job_record.completed_at,
              'details', '{}'::jsonb
            )
          WHERE job_record.completed_at IS NOT NULL
        )
        SELECT jsonb_agg(event ORDER BY occurred_at, event_order)
        FROM event_history
      ),
      '[]'::jsonb
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_championship_bracket_preview_job_status_v7(_job_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE
  job_record RECORD;
BEGIN
  SELECT *
  INTO job_record
  FROM championship_bracket_preview_private.jobs
  WHERE id = _job_id;

  IF job_record.id IS NULL
    OR (
      job_record.requested_by <> auth.uid()
      AND NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true)
    )
  THEN
    RAISE EXCEPTION 'Job de prévia não encontrado.';
  END IF;

  RETURN jsonb_build_object(
    'job_id', job_record.id,
    'championship_id', job_record.championship_id,
    'season_year', job_record.season_year,
    'status', job_record.status,
    'stage', job_record.stage,
    'current_date', job_record.current_processing_date,
    'progress_percentage', job_record.progress_percentage,
    'processed_slots', job_record.processed_slots,
    'total_slots', job_record.total_slots,
    'attempt_count', job_record.attempt_count,
    'error_message', job_record.error_message,
    'summary', job_record.summary,
    'diagnostics', job_record.diagnostics,
    'payload_signature', job_record.payload_signature,
    'dependency_signature', job_record.dependency_signature,
    'algorithm_version', job_record.algorithm_version,
    'generation_signature', job_record.generation_signature,
    'created_at', job_record.created_at,
    'completed_at', job_record.completed_at,
    'expires_at', job_record.expires_at,
    'is_valid_for_creation', (
      job_record.status = 'COMPLETED'
      AND job_record.algorithm_version = 'async-exact-v7'
      AND job_record.generation_signature IS NOT NULL
      AND job_record.expires_at > now()
      AND jsonb_array_length(job_record.diagnostics) = 0
    )
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_championship_knockout_final_program_schedule(_bracket_edition_id uuid)
 RETURNS TABLE(competition_id uuid, sport_id uuid, naipe match_naipe, division team_division, scheduled_date date, schedule_period championship_schedule_period, location_name text, court_name text, location_group_id uuid, court_group_id uuid, bracket_day_id uuid, bracket_court_id uuid, display_order integer, naipe_position integer, expected_final_round integer, duration_minutes integer, planned_start_at timestamp with time zone, planned_end_at timestamp with time zone, planned_scheduled_slot integer, planned_queue_position integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  edition_record RECORD;

  program_block_record JSONB;
  program_block_ordinality BIGINT;
  naipe_sequence_record RECORD;

  resolved_sport_id UUID;
  resolved_naipe public.match_naipe;

  resolved_division_scope
    public.bracket_knockout_division_scope;

  resolved_competition_id UUID;
  resolved_division public.team_division;
  resolved_expected_final_round INTEGER;

  resolved_duration_minutes INTEGER;
  resolved_duration_override_minutes INTEGER;
  resolved_duration_override_numeric NUMERIC;

  matching_competitions_count INTEGER;

  resolved_scheduled_date DATE;

  resolved_period
    public.championship_schedule_period;

  resolved_location_name TEXT;
  resolved_court_name TEXT;

  resolved_location_group_id UUID;
  resolved_court_group_id UUID;
  resolved_bracket_day_id UUID;
  resolved_bracket_court_id UUID;

  resolved_display_order INTEGER;
  resolved_naipe_position INTEGER;

  resolved_day_start_time TIME;
  resolved_day_end_time TIME;
  resolved_day_break_start_time TIME;
  resolved_day_break_end_time TIME;

  resolved_day_start_at TIMESTAMPTZ;
  resolved_day_end_at TIMESTAMPTZ;
  resolved_day_middle_at TIMESTAMPTZ;

  resolved_period_start_at TIMESTAMPTZ;
  resolved_period_end_at TIMESTAMPTZ;

  resolved_next_day_start_at TIMESTAMPTZ;

  resolved_period_enabled BOOLEAN;

  schedule_entry_record RECORD;

  candidate_start_at TIMESTAMPTZ;
  candidate_end_at TIMESTAMPTZ;

  existing_conflict_end_at TIMESTAMPTZ;
  programmed_final_conflict_end_at TIMESTAMPTZ;

  resolved_start_at TIMESTAMPTZ;
  resolved_end_at TIMESTAMPTZ;
BEGIN
  SELECT
    editions_table.id,
    editions_table.championship_id,
    editions_table.season_year,
    editions_table.payload_snapshot
  INTO edition_record
  FROM public.championship_bracket_editions
    AS editions_table
  WHERE editions_table.id = _bracket_edition_id
  LIMIT 1;

  IF edition_record.id IS NULL THEN
    RAISE EXCEPTION
      'Edição de chaveamento inválida para calcular os blocos de finais.';
  END IF;

  DROP TABLE IF EXISTS
    tmp_championship_final_program_schedule;

  CREATE TEMP TABLE
    tmp_championship_final_program_schedule (
      row_id BIGSERIAL PRIMARY KEY,

      competition_id UUID NOT NULL,
      sport_id UUID NOT NULL,
      naipe public.match_naipe NOT NULL,
      division public.team_division NULL,

      scheduled_date DATE NOT NULL,

      schedule_period
        public.championship_schedule_period
        NOT NULL,

      location_name TEXT NOT NULL,
      court_name TEXT NOT NULL,

      location_group_id UUID NOT NULL,
      court_group_id UUID NOT NULL,
      bracket_day_id UUID NOT NULL,
      bracket_court_id UUID NOT NULL,

      block_ordinality INTEGER NOT NULL,
      display_order INTEGER NOT NULL,
      naipe_position INTEGER NOT NULL,

      expected_final_round INTEGER NOT NULL,
      duration_minutes INTEGER NOT NULL,

      period_start_at TIMESTAMPTZ NOT NULL,
      period_end_at TIMESTAMPTZ NOT NULL,

      planned_start_at TIMESTAMPTZ NULL,
      planned_end_at TIMESTAMPTZ NULL
    )
  ON COMMIT DROP;

  IF jsonb_typeof(
    edition_record.payload_snapshot
      -> 'knockout_program_blocks'
  ) IS DISTINCT FROM 'array'
  THEN
    RETURN;
  END IF;

  FOR
    program_block_record,
    program_block_ordinality
  IN
    SELECT
      program_block.value,
      program_block.ordinality
    FROM jsonb_array_elements(
      edition_record.payload_snapshot
        -> 'knockout_program_blocks'
    )
    WITH ORDINALITY
      AS program_block(value, ordinality)
    WHERE COALESCE(
      program_block.value ->> 'phase',
      ''
    ) = 'FINAL'
  LOOP
    IF jsonb_typeof(program_block_record)
      IS DISTINCT FROM 'object'
    THEN
      RAISE EXCEPTION
        'Bloco de finais inválido na posição %.',
        program_block_ordinality;
    END IF;

    IF NULLIF(
      trim(
        COALESCE(
          program_block_record ->> 'sport_id',
          ''
        )
      ),
      ''
    ) IS NULL
    THEN
      RAISE EXCEPTION
        'Modalidade não informada no bloco de finais %.',
        program_block_ordinality;
    END IF;

    resolved_sport_id :=
      (
        program_block_record ->> 'sport_id'
      )::uuid;

    IF NULLIF(
      trim(
        COALESCE(
          program_block_record ->> 'date',
          ''
        )
      ),
      ''
    ) IS NULL
    THEN
      RAISE EXCEPTION
        'Data não informada no bloco de finais %.',
        program_block_ordinality;
    END IF;

    resolved_scheduled_date :=
      (
        program_block_record ->> 'date'
      )::date;

    resolved_location_name := NULLIF(
      trim(
        COALESCE(
          program_block_record ->> 'location_name',
          ''
        )
      ),
      ''
    );

    resolved_court_name := NULLIF(
      trim(
        COALESCE(
          program_block_record ->> 'court_name',
          ''
        )
      ),
      ''
    );

    IF resolved_location_name IS NULL
      OR resolved_court_name IS NULL
    THEN
      RAISE EXCEPTION
        'Local e quadra são obrigatórios no bloco de finais %.',
        program_block_ordinality;
    END IF;

    
    IF (
      NULLIF(
        trim(
          COALESCE(
            program_block_record ->> 'start_time',
            ''
          )
        ),
        ''
      ) IS NULL
      OR NULLIF(
        trim(
          COALESCE(
            program_block_record ->> 'end_time',
            ''
          )
        ),
        ''
      ) IS NULL
    )
      AND NULLIF(
        trim(
          COALESCE(
            program_block_record ->> 'period',
            ''
          )
        ),
        ''
      ) IS NULL
    THEN
      RAISE EXCEPTION
        'Horário ou período não informado no bloco de finais %.',
        program_block_ordinality;
    END IF;

    resolved_period :=
      CASE
        WHEN NULLIF(
          trim(
            COALESCE(
              program_block_record ->> 'period',
              ''
            )
          ),
          ''
        ) IS NULL
        THEN
          NULL
        ELSE
          (
            program_block_record ->> 'period'
          )::public.championship_schedule_period
      END;
    resolved_division_scope :=

      COALESCE(
        NULLIF(
          trim(
            COALESCE(
              program_block_record
                ->> 'division_scope',
              ''
            )
          ),
          ''
        ),
        'ALL'
      )::public.bracket_knockout_division_scope;

    resolved_display_order := GREATEST(
      1,
      COALESCE(
        NULLIF(
          trim(
            COALESCE(
              program_block_record
                ->> 'display_order',
              ''
            )
          ),
          ''
        )::integer,
        program_block_ordinality::integer
      )
    );

    /*
     * Duração especial da final.
     *
     * Campo ausente ou JSON null:
     * usa a duração padrão da modalidade.
     *
     * Campo informado:
     * precisa ser um inteiro positivo.
     */
    resolved_duration_override_minutes := NULL;
    resolved_duration_override_numeric := NULL;

    IF
      program_block_record
        ? 'match_duration_minutes_override'
      AND jsonb_typeof(
        program_block_record
          -> 'match_duration_minutes_override'
      ) IS DISTINCT FROM 'null'
    THEN
      IF jsonb_typeof(
        program_block_record
          -> 'match_duration_minutes_override'
      ) IS DISTINCT FROM 'number'
      THEN
        RAISE EXCEPTION
          'A duração especial do bloco de finais % precisa ser um número inteiro maior que zero.',
          program_block_ordinality;
      END IF;

      BEGIN
        resolved_duration_override_numeric :=
          (
            program_block_record
              ->> 'match_duration_minutes_override'
          )::numeric;
      EXCEPTION
        WHEN invalid_text_representation
          OR numeric_value_out_of_range
        THEN
          RAISE EXCEPTION
            'A duração especial do bloco de finais % é inválida.',
            program_block_ordinality;
      END;

      IF
        resolved_duration_override_numeric <= 0
        OR resolved_duration_override_numeric <>
          trunc(resolved_duration_override_numeric)
        OR resolved_duration_override_numeric >
          2147483647
      THEN
        RAISE EXCEPTION
          'A duração especial do bloco de finais % precisa ser um número inteiro maior que zero.',
          program_block_ordinality;
      END IF;

      resolved_duration_override_minutes :=
        resolved_duration_override_numeric::integer;
    END IF;

    IF jsonb_typeof(
      program_block_record -> 'naipe_sequence'
    ) IS DISTINCT FROM 'array'
      OR jsonb_array_length(
        program_block_record -> 'naipe_sequence'
      ) = 0
    THEN
      RAISE EXCEPTION
        'O bloco de finais % não possui sequência de naipes.',
        program_block_ordinality;
    END IF;

    resolved_bracket_day_id := NULL;
    resolved_bracket_court_id := NULL;
    resolved_location_group_id := NULL;
    resolved_court_group_id := NULL;

    SELECT
      days_table.id,
      days_table.start_time,
      days_table.end_time,
      days_table.break_start_time,
      days_table.break_end_time,

      locations_table.name,
      locations_table.location_group_id,

      courts_table.id,
      courts_table.name,
      courts_table.court_group_id
    INTO
      resolved_bracket_day_id,
      resolved_day_start_time,
      resolved_day_end_time,
      resolved_day_break_start_time,
      resolved_day_break_end_time,

      resolved_location_name,
      resolved_location_group_id,

      resolved_bracket_court_id,
      resolved_court_name,
      resolved_court_group_id
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
        resolved_scheduled_date
      AND (
        (
          NULLIF(
            trim(
              COALESCE(
                program_block_record
                  ->> 'location_key',
                ''
              )
            ),
            ''
          ) IS NOT NULL
          AND locations_table
            .location_group_id::text =
              program_block_record
                ->> 'location_key'
        )
        OR
        public.normalize_bracket_entity_name(
          locations_table.name
        ) =
          public.normalize_bracket_entity_name(
            resolved_location_name
          )
      )
      AND (
        (
          NULLIF(
            trim(
              COALESCE(
                program_block_record
                  ->> 'court_key',
                ''
              )
            ),
            ''
          ) IS NOT NULL
          AND courts_table
            .court_group_id::text =
              program_block_record
                ->> 'court_key'
        )
        OR
        public.normalize_bracket_entity_name(
          courts_table.name
        ) =
          public.normalize_bracket_entity_name(
            resolved_court_name
          )
      )
    ORDER BY
      CASE
        WHEN locations_table
            .location_group_id::text =
              COALESCE(
                program_block_record
                  ->> 'location_key',
                ''
              )
          AND courts_table
            .court_group_id::text =
              COALESCE(
                program_block_record
                  ->> 'court_key',
                ''
              )
        THEN 0
        ELSE 1
      END,
      locations_table.position ASC,
      courts_table.position ASC
    LIMIT 1;

    IF resolved_bracket_day_id IS NULL
      OR resolved_bracket_court_id IS NULL
    THEN
      RAISE EXCEPTION
        'A quadra % • % não existe na agenda de %.',
        resolved_location_name,
        resolved_court_name,
        resolved_scheduled_date;
    END IF;

    /*
     * IMPORTANTE:
     *
     * Não validar championship_bracket_court_sports aqui.
     *
     * Um bloco manual de FINAL pode utilizar uma quadra
     * que não esteja vinculada à modalidade nas regras
     * normais da agenda.
     *
     * Essa exceção existe somente nesta programação
     * manual de final.
     */

    
    SELECT
      fixed_block_bounds.schedule_period,
      fixed_block_bounds.period_start_at,
      fixed_block_bounds.period_end_at
    INTO
      resolved_period,
      resolved_period_start_at,
      resolved_period_end_at
    FROM public.resolve_bracket_fixed_block_bounds_from_payload(
      edition_record.payload_snapshot,
      resolved_scheduled_date,
      NULLIF(
        program_block_record ->> 'start_time',
        ''
      ),
      NULLIF(
        program_block_record ->> 'end_time',
        ''
      ),
      resolved_period
    ) AS fixed_block_bounds
    LIMIT 1;

    IF resolved_period_start_at IS NULL
      OR resolved_period_end_at IS NULL
    THEN
      RAISE EXCEPTION
        'O bloco de finais % não possui uma janela válida em %.',
        program_block_ordinality,
        resolved_scheduled_date;
    END IF;
    resolved_next_day_start_at :=

      public.combine_bracket_schedule_timestamp(
        resolved_scheduled_date + 1,
        time '00:00'
      );

    FOR naipe_sequence_record IN
      SELECT
        naipe_record.value,
        naipe_record.ordinality::integer
          AS naipe_position
      FROM jsonb_array_elements_text(
        program_block_record -> 'naipe_sequence'
      )
      WITH ORDINALITY
        AS naipe_record(value, ordinality)
      ORDER BY naipe_record.ordinality ASC
    LOOP
      resolved_naipe :=
        naipe_sequence_record.value
          ::public.match_naipe;

      resolved_naipe_position :=
        naipe_sequence_record.naipe_position;

      SELECT COUNT(*)::integer
      INTO matching_competitions_count
      FROM public.championship_bracket_competitions
        AS competitions_table
      WHERE competitions_table.bracket_edition_id =
          _bracket_edition_id
        AND competitions_table.sport_id =
          resolved_sport_id
        AND competitions_table.naipe =
          resolved_naipe
        AND (
          (
            resolved_division_scope =
              'ALL'::public
                .bracket_knockout_division_scope
            AND competitions_table.division IS NULL
          )
          OR (
            resolved_division_scope =
              'DIVISAO_PRINCIPAL'::public
                .bracket_knockout_division_scope
            AND competitions_table.division =
              'DIVISAO_PRINCIPAL'::public
                .team_division
          )
          OR (
            resolved_division_scope =
              'DIVISAO_ACESSO'::public
                .bracket_knockout_division_scope
            AND competitions_table.division =
              'DIVISAO_ACESSO'::public
                .team_division
          )
        );

      IF matching_competitions_count = 0 THEN
        RAISE EXCEPTION
          'Não existe competição ativa para a final da modalidade %, naipe % e escopo %.',
          resolved_sport_id,
          resolved_naipe,
          resolved_division_scope;
      END IF;

      IF matching_competitions_count > 1 THEN
        RAISE EXCEPTION
          'Existe mais de uma competição correspondente à final da modalidade %, naipe % e escopo %.',
          resolved_sport_id,
          resolved_naipe,
          resolved_division_scope;
      END IF;

      SELECT
        competitions_table.id,
        competitions_table.division
      INTO
        resolved_competition_id,
        resolved_division
      FROM public.championship_bracket_competitions
        AS competitions_table
      WHERE competitions_table.bracket_edition_id =
          _bracket_edition_id
        AND competitions_table.sport_id =
          resolved_sport_id
        AND competitions_table.naipe =
          resolved_naipe
        AND (
          (
            resolved_division_scope =
              'ALL'::public
                .bracket_knockout_division_scope
            AND competitions_table.division IS NULL
          )
          OR (
            resolved_division_scope =
              'DIVISAO_PRINCIPAL'::public
                .bracket_knockout_division_scope
            AND competitions_table.division =
              'DIVISAO_PRINCIPAL'::public
                .team_division
          )
          OR (
            resolved_division_scope =
              'DIVISAO_ACESSO'::public
                .bracket_knockout_division_scope
            AND competitions_table.division =
              'DIVISAO_ACESSO'::public
                .team_division
          )
        )
      LIMIT 1;

      resolved_expected_final_round :=
        public
          .resolve_championship_competition_expected_knockout_rounds(
            resolved_competition_id
          );

      IF resolved_expected_final_round < 1 THEN
        RAISE EXCEPTION
          'A competição % não possui quantidade suficiente de classificados para uma final.',
          resolved_competition_id;
      END IF;

      resolved_duration_minutes :=
        COALESCE(
          resolved_duration_override_minutes,

          GREATEST(
            1,
            public.resolve_championship_sport_duration_minutes(
              edition_record.championship_id,
              resolved_sport_id
            )
          )
        );

      INSERT INTO
        tmp_championship_final_program_schedule (
          competition_id,
          sport_id,
          naipe,
          division,

          scheduled_date,
          schedule_period,

          location_name,
          court_name,

          location_group_id,
          court_group_id,
          bracket_day_id,
          bracket_court_id,

          block_ordinality,
          display_order,
          naipe_position,

          expected_final_round,
          duration_minutes,

          period_start_at,
          period_end_at
        )
      VALUES (
        resolved_competition_id,
        resolved_sport_id,
        resolved_naipe,
        resolved_division,

        resolved_scheduled_date,
        resolved_period,

        resolved_location_name,
        resolved_court_name,

        resolved_location_group_id,
        resolved_court_group_id,
        resolved_bracket_day_id,
        resolved_bracket_court_id,

        program_block_ordinality::integer,
        resolved_display_order,
        resolved_naipe_position,

        resolved_expected_final_round,
        resolved_duration_minutes,

        resolved_period_start_at,
        resolved_period_end_at
      );
    END LOOP;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM tmp_championship_final_program_schedule
      AS final_program_table
    GROUP BY final_program_table.competition_id
    HAVING COUNT(*) > 1
  )
  THEN
    RAISE EXCEPTION
      'Uma mesma competição foi configurada em mais de um bloco de finais.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM tmp_championship_final_program_schedule
      AS final_program_table
    
    GROUP BY
      final_program_table.scheduled_date,
      final_program_table.bracket_court_id,
      final_program_table.period_start_at,
      final_program_table.period_end_at,
      final_program_table.display_order
    HAVING COUNT(
      DISTINCT final_program_table.block_ordinality
    ) > 1
  )
  THEN
    RAISE EXCEPTION
      'Existem dois blocos de finais com a mesma ordem na mesma quadra e horário.';

  END IF;

  /*
   * Programa cada final em ordem.
   *
   * O período escolhido define somente o ponto inicial
   * mínimo da programação.
   *
   * Depois disso a final pode:
   * - atravessar o intervalo;
   * - ultrapassar o término do período;
   * - ultrapassar o end_time configurado do dia.
   *
   * Mas nunca pode:
   * - sobrepor outro jogo na mesma quadra;
   * - sobrepor outra final já programada;
   * - atravessar a meia-noite.
   */
  FOR schedule_entry_record IN
    SELECT final_program_table.*
    FROM tmp_championship_final_program_schedule
      AS final_program_table
    ORDER BY
      final_program_table.scheduled_date ASC,
      final_program_table.period_start_at ASC,
      final_program_table.location_name ASC,
      final_program_table.court_name ASC,
      final_program_table.display_order ASC,
      final_program_table.block_ordinality ASC,
      final_program_table.naipe_position ASC,
      final_program_table.row_id ASC
  LOOP
    /*
     * Jogos já concretos na mesma quadra precisam possuir
     * início e fim para podermos calcular intervalos.
     *
     * Finais que pertencem aos próprios blocos manuais
     * são excluídas daqui, pois serão recalculadas abaixo.
     */
    IF EXISTS (
      SELECT 1
      FROM public.matches AS matches_table
      JOIN public.championship_bracket_matches
        AS bracket_matches_table
        ON bracket_matches_table.match_id =
          matches_table.id
      WHERE bracket_matches_table
          .bracket_edition_id =
            _bracket_edition_id
        AND matches_table.scheduled_date =
          schedule_entry_record.scheduled_date
        AND public.normalize_bracket_entity_name(
          matches_table.location
        ) =
          public.normalize_bracket_entity_name(
            schedule_entry_record.location_name
          )
        AND public.normalize_bracket_entity_name(
          matches_table.court_name
        ) =
          public.normalize_bracket_entity_name(
            schedule_entry_record.court_name
          )
        AND NOT EXISTS (
          SELECT 1
          FROM
            tmp_championship_final_program_schedule
              AS configured_final_table
          WHERE configured_final_table.competition_id =
              bracket_matches_table.competition_id
            AND bracket_matches_table.phase =
              'KNOCKOUT'::public.bracket_phase
            AND bracket_matches_table.is_third_place =
              false
            AND bracket_matches_table.round_number =
              configured_final_table
                .expected_final_round
        )
        AND (
          matches_table.start_time IS NULL
          OR matches_table.end_time IS NULL
        )
    )
    THEN
      RAISE EXCEPTION
        'Existem jogos sem horário concreto em % • % no dia %. Redistribua a grade antes de programar as finais.',
        schedule_entry_record.location_name,
        schedule_entry_record.court_name,
        schedule_entry_record.scheduled_date;
    END IF;

    candidate_start_at :=
      schedule_entry_record.period_start_at;

    /*
     * Procura conflitos de intervalo.
     *
     * Diferente da grade normal, não utilizamos
     * resolve_bracket_court_next_available_start(),
     * pois finais manuais podem cruzar break e day_end.
     */
    LOOP
      candidate_end_at :=
        candidate_start_at
        + make_interval(
          mins =>
            schedule_entry_record.duration_minutes
        );

      IF candidate_end_at >=
        public.combine_bracket_schedule_timestamp(
          schedule_entry_record.scheduled_date + 1,
          time '00:00'
        )
      THEN
        RAISE EXCEPTION
          'A final de % em % • % ultrapassaria a meia-noite do dia %.',
          schedule_entry_record.naipe,
          schedule_entry_record.location_name,
          schedule_entry_record.court_name,
          schedule_entry_record.scheduled_date;
      END IF;

      existing_conflict_end_at := NULL;
      programmed_final_conflict_end_at := NULL;

      /*
       * Jogo já existente na mesma quadra cujo intervalo
       * cruza o candidato atual.
       */
      SELECT MAX(matches_table.end_time)
      INTO existing_conflict_end_at
      FROM public.matches AS matches_table
      JOIN public.championship_bracket_matches
        AS bracket_matches_table
        ON bracket_matches_table.match_id =
          matches_table.id
      WHERE bracket_matches_table.bracket_edition_id =
          _bracket_edition_id
        AND matches_table.scheduled_date =
          schedule_entry_record.scheduled_date
        AND public.normalize_bracket_entity_name(
          matches_table.location
        ) =
          public.normalize_bracket_entity_name(
            schedule_entry_record.location_name
          )
        AND public.normalize_bracket_entity_name(
          matches_table.court_name
        ) =
          public.normalize_bracket_entity_name(
            schedule_entry_record.court_name
          )
        AND matches_table.start_time IS NOT NULL
        AND matches_table.end_time IS NOT NULL
        AND matches_table.start_time <
          candidate_end_at
        AND matches_table.end_time >
          candidate_start_at
        AND NOT EXISTS (
          SELECT 1
          FROM
            tmp_championship_final_program_schedule
              AS configured_final_table
          WHERE configured_final_table.competition_id =
              bracket_matches_table.competition_id
            AND bracket_matches_table.phase =
              'KNOCKOUT'::public.bracket_phase
            AND bracket_matches_table.is_third_place =
              false
            AND bracket_matches_table.round_number =
              configured_final_table
                .expected_final_round
        );

      /*
       * Outra final manual já calculada anteriormente
       * no mesmo dia e na mesma quadra.
       */
      SELECT MAX(
        previous_final_table.planned_end_at
      )
      INTO programmed_final_conflict_end_at
      FROM tmp_championship_final_program_schedule
        AS previous_final_table
      WHERE previous_final_table.row_id <>
          schedule_entry_record.row_id
        AND previous_final_table.scheduled_date =
          schedule_entry_record.scheduled_date
        AND previous_final_table.bracket_court_id =
          schedule_entry_record.bracket_court_id
        AND previous_final_table.planned_start_at
          IS NOT NULL
        AND previous_final_table.planned_end_at
          IS NOT NULL
        AND previous_final_table.planned_start_at <
          candidate_end_at
        AND previous_final_table.planned_end_at >
          candidate_start_at;

      EXIT WHEN
        existing_conflict_end_at IS NULL
        AND programmed_final_conflict_end_at IS NULL;

      candidate_start_at := GREATEST(
        candidate_start_at,
        COALESCE(
          existing_conflict_end_at,
          candidate_start_at
        ),
        COALESCE(
          programmed_final_conflict_end_at,
          candidate_start_at
        )
      );
    END LOOP;

    resolved_start_at := candidate_start_at;

    resolved_end_at :=
      resolved_start_at
      + make_interval(
        mins =>
          schedule_entry_record.duration_minutes
      );

    /*
     * Único limite absoluto de encerramento:
     * a final precisa terminar antes do início
     * do próximo dia civil.
     *
     * 23:00 -> 00:00 também é rejeitado.
     */
    IF resolved_end_at >=
      public.combine_bracket_schedule_timestamp(
        schedule_entry_record.scheduled_date + 1,
        time '00:00'
      )
    THEN
      RAISE EXCEPTION
        'A final de % em % • % ultrapassaria a meia-noite do dia %.',
        schedule_entry_record.naipe,
        schedule_entry_record.location_name,
        schedule_entry_record.court_name,
        schedule_entry_record.scheduled_date;
    END IF;

    UPDATE
      tmp_championship_final_program_schedule
        AS final_program_table
    SET
      planned_start_at = resolved_start_at,
      planned_end_at = resolved_end_at
    WHERE final_program_table.row_id =
      schedule_entry_record.row_id;
  END LOOP;

  RETURN QUERY
  WITH numbered_finals AS (
    SELECT
      final_program_table.*,

      ROW_NUMBER() OVER (
        PARTITION BY
          final_program_table.scheduled_date
        ORDER BY
          final_program_table.planned_start_at ASC,
          final_program_table.location_name ASC,
          final_program_table.court_name ASC,
          final_program_table.display_order ASC,
          final_program_table.naipe_position ASC,
          final_program_table.row_id ASC
      )::integer AS final_day_position,

      ROW_NUMBER() OVER (
        PARTITION BY
          final_program_table.scheduled_date,
          final_program_table.sport_id,
          final_program_table.naipe,
          public.coerce_division_for_index(
            final_program_table.division
          )
        ORDER BY
          final_program_table.planned_start_at ASC,
          final_program_table.display_order ASC,
          final_program_table.naipe_position ASC,
          final_program_table.row_id ASC
      )::integer AS final_scope_position
    FROM tmp_championship_final_program_schedule
      AS final_program_table
  )
  SELECT
    numbered_finals.competition_id,
    numbered_finals.sport_id,
    numbered_finals.naipe,
    numbered_finals.division,

    numbered_finals.scheduled_date,
    numbered_finals.schedule_period,

    numbered_finals.location_name,
    numbered_finals.court_name,

    numbered_finals.location_group_id,
    numbered_finals.court_group_id,
    numbered_finals.bracket_day_id,
    numbered_finals.bracket_court_id,

    numbered_finals.display_order,
    numbered_finals.naipe_position,
    numbered_finals.expected_final_round,
    numbered_finals.duration_minutes,

    numbered_finals.planned_start_at,
    numbered_finals.planned_end_at,

    (
      COALESCE(
        (
          SELECT MAX(matches_table.scheduled_slot)
          FROM public.matches AS matches_table
          JOIN public.championship_bracket_matches
            AS bracket_matches_table
            ON bracket_matches_table.match_id =
              matches_table.id
          WHERE bracket_matches_table
              .bracket_edition_id =
                _bracket_edition_id
            AND matches_table.scheduled_date =
              numbered_finals.scheduled_date
            AND matches_table.start_time <=
              numbered_finals.planned_start_at
            AND NOT EXISTS (
              SELECT 1
              FROM
                tmp_championship_final_program_schedule
                  AS configured_final_table
              WHERE configured_final_table
                  .competition_id =
                    bracket_matches_table
                      .competition_id
                AND bracket_matches_table.phase =
                  'KNOCKOUT'::public.bracket_phase
                AND bracket_matches_table
                  .is_third_place = false
                AND bracket_matches_table
                  .round_number =
                    configured_final_table
                      .expected_final_round
            )
        ),
        0
      )
      + numbered_finals.final_day_position
    )::integer AS planned_scheduled_slot,

    (
      COALESCE(
        (
          SELECT MAX(matches_table.queue_position)
          FROM public.matches AS matches_table
          JOIN public.championship_bracket_matches
            AS bracket_matches_table
            ON bracket_matches_table.match_id =
              matches_table.id
          WHERE bracket_matches_table
              .bracket_edition_id =
                _bracket_edition_id
            AND matches_table.scheduled_date =
              numbered_finals.scheduled_date
            AND matches_table.sport_id =
              numbered_finals.sport_id
            AND matches_table.naipe =
              numbered_finals.naipe
            AND public.coerce_division_for_index(
              matches_table.division
            ) IS NOT DISTINCT FROM
              public.coerce_division_for_index(
                numbered_finals.division
              )
            AND NOT EXISTS (
              SELECT 1
              FROM
                tmp_championship_final_program_schedule
                  AS configured_final_table
              WHERE configured_final_table
                  .competition_id =
                    bracket_matches_table
                      .competition_id
                AND bracket_matches_table.phase =
                  'KNOCKOUT'::public.bracket_phase
                AND bracket_matches_table
                  .is_third_place = false
                AND bracket_matches_table
                  .round_number =
                    configured_final_table
                      .expected_final_round
            )
        ),
        0
      )
      + numbered_finals.final_scope_position
    )::integer AS planned_queue_position
  FROM numbered_finals
  ORDER BY
    numbered_finals.scheduled_date ASC,
    numbered_finals.planned_start_at ASC,
    numbered_finals.location_name ASC,
    numbered_finals.court_name ASC,
    numbered_finals.display_order ASC,
    numbered_finals.naipe_position ASC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.has_admin_tab_access(_tab admin_panel_tab, _requires_edit boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE
    WHEN _requires_edit THEN
      public.resolve_current_user_tab_permission_level(_tab) = 'EDIT'::public.admin_panel_permission_level
    ELSE
      public.resolve_current_user_tab_permission_level(_tab) IN (
        'VIEW'::public.admin_panel_permission_level,
        'EDIT'::public.admin_panel_permission_level
      )
  END
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

CREATE OR REPLACE FUNCTION public.normalize_bracket_entity_name(_value text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT lower(trim(regexp_replace(COALESCE(_value, ''), '\s+', ' ', 'g')));
$function$;

CREATE OR REPLACE FUNCTION public.rebuild_championship_knockout_schedule_reservations(_bracket_edition_id uuid, _strict boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  edition_record RECORD;
  competition_record RECORD;
  pending_record RECORD;
  feeder_record RECORD;
  court_record RECORD;
  period_record RECORD;
  availability_window_record RECORD;
  manual_final_record RECORD;

  competition_key_value TEXT;

  direct_qualified_team_count INTEGER;
  qualified_team_count INTEGER;
  bracket_size INTEGER;
  bracket_size_cursor INTEGER;
  total_rounds INTEGER;

  round_number_value INTEGER;
  round_match_count INTEGER;
  slot_number_value INTEGER;

  first_round_home_seed INTEGER;
  first_round_away_seed INTEGER;

  is_bye_value BOOLEAN;
  is_manual_final_value BOOLEAN;

  group_match_count INTEGER;
  group_schedule_complete BOOLEAN;
  group_ready_at TIMESTAMPTZ;

  remaining_automatic_count INTEGER;

  dependency_ready_at TIMESTAMPTZ;
  feeder_count INTEGER;

  resolved_phase
    public.bracket_knockout_priority_phase;

  resolved_division_scope
    public.bracket_knockout_division_scope;

  resolved_preferred_court_group_id UUID;

  period_start_at TIMESTAMPTZ;
  period_end_at TIMESTAMPTZ;

  day_start_at TIMESTAMPTZ;
  day_end_at TIMESTAMPTZ;
  day_middle_at TIMESTAMPTZ;

  candidate_start_at TIMESTAMPTZ;
  candidate_end_at TIMESTAMPTZ;
  candidate_conflict_end_at TIMESTAMPTZ;

  candidate_is_valid BOOLEAN;
  candidate_priority_rank INTEGER;

  best_pending_row_id BIGINT;

  best_start_at TIMESTAMPTZ;
  best_end_at TIMESTAMPTZ;

  best_scheduled_date DATE;

  best_schedule_period
    public.championship_schedule_period;

  best_location_name TEXT;
  best_court_name TEXT;

  best_location_group_id UUID;
  best_court_group_id UUID;

  best_bracket_day_id UUID;
  best_bracket_court_id UUID;

  best_duration_minutes INTEGER;
  best_priority_rank INTEGER;

  best_location_position INTEGER;
  best_court_position INTEGER;

  selected_scheduled_slot INTEGER;
  selected_queue_position INTEGER;

  conflict_count INTEGER;
  expected_match_count INTEGER;
  scheduled_match_count INTEGER;

  first_conflict_message TEXT;

  result_conflicts JSONB;

  manual_dependency_ready_at TIMESTAMPTZ;
BEGIN
  IF _bracket_edition_id IS NULL THEN
    RAISE EXCEPTION
      'A edição de chaveamento é obrigatória para planejar o mata-mata.';
  END IF;


  SELECT
    editions_table.id,
    editions_table.championship_id,
    editions_table.season_year,
    editions_table.payload_snapshot
  INTO edition_record
  FROM public.championship_bracket_editions
    AS editions_table
  WHERE editions_table.id =
    _bracket_edition_id
  LIMIT 1;


  IF edition_record.id IS NULL THEN
    RAISE EXCEPTION
      'Edição de chaveamento inválida para planejar o mata-mata.';
  END IF;


  /*
   * Evita que duas reconstruções concorrentes da mesma edição
   * alterem a tabela de reservas simultaneamente.
   */
  PERFORM pg_advisory_xact_lock(
    hashtextextended(
      'championship_knockout_schedule:'
        || _bracket_edition_id::text,
      0
    )
  );


  DELETE FROM
    public.championship_bracket_knockout_schedule_reservations
  WHERE bracket_edition_id =
    _bracket_edition_id;


  DROP TABLE IF EXISTS
    tmp_knockout_schedule_conflicts;

  CREATE TEMP TABLE
    tmp_knockout_schedule_conflicts (
      row_id BIGSERIAL PRIMARY KEY,

      conflict_code TEXT NOT NULL,
      conflict_message TEXT NOT NULL,

      competition_id UUID NULL,
      round_number INTEGER NULL,
      slot_number INTEGER NULL
    )
  ON COMMIT DROP;


  /*
   * Primeiro calculamos as finais manuais.
   *
   * Elas precisam existir desde o início do planejamento porque
   * funcionam como intervalos fixos da quadra. As demais partidas
   * automáticas podem ser deslocadas ao redor delas, mas nunca
   * deslocam a própria final manual.
   */
  DROP TABLE IF EXISTS
    tmp_knockout_manual_finals;

  CREATE TEMP TABLE
    tmp_knockout_manual_finals
  ON COMMIT DROP
  AS
  SELECT
    final_schedule.*
  FROM
    public.get_championship_knockout_final_program_schedule(
      _bracket_edition_id
    ) AS final_schedule;


  /*
   * Representação temporária de todos os nós projetados do mata-mata.
   *
   * BYEs são mantidos apenas para preservar corretamente as
   * dependências do bracket. Eles não serão gravados como reserva.
   */
  DROP TABLE IF EXISTS
    tmp_knockout_pending_matches;

  CREATE TEMP TABLE
    tmp_knockout_pending_matches (
      row_id BIGSERIAL PRIMARY KEY,

      competition_id UUID NOT NULL,

      sport_id UUID NOT NULL,
      naipe public.match_naipe NOT NULL,
      division public.team_division NULL,

      total_rounds INTEGER NOT NULL,

      round_number INTEGER NOT NULL,
      slot_number INTEGER NOT NULL,

      duration_minutes INTEGER NOT NULL,

      is_bye BOOLEAN NOT NULL DEFAULT false,
      is_manual_final BOOLEAN NOT NULL DEFAULT false,

      group_ready_at TIMESTAMPTZ NULL,

      planned_start_at TIMESTAMPTZ NULL,
      planned_end_at TIMESTAMPTZ NULL,

      failed BOOLEAN NOT NULL DEFAULT false,

      UNIQUE (
        competition_id,
        round_number,
        slot_number
      )
    )
  ON COMMIT DROP;


  /*
   * Monta o bracket anônimo de cada competição.
   *
   * A regra replica o tamanho esperado utilizado pela geração real:
   *
   * - classificação normal:
   *     próximo power-of-two >= classificados diretos;
   *
   * - qualifiers_per_group = 1 com complementação pelos melhores
   *   segundos:
   *     próximo power-of-two > classificados diretos.
   */
  FOR competition_record IN
    SELECT
      competitions_table.id,
      competitions_table.sport_id,
      competitions_table.naipe,
      competitions_table.division,
      competitions_table.groups_count,
      competitions_table.qualifiers_per_group,

      competitions_table
        .should_complete_knockout_with_best_second_placed_teams,

      COALESCE(
        championship_sports_table
          .default_match_duration_minutes,

        sports_table
          .default_match_duration_minutes,

        30
      )::integer AS duration_minutes

    FROM public.championship_bracket_competitions
      AS competitions_table

    LEFT JOIN public.championship_sports
      AS championship_sports_table
      ON championship_sports_table.championship_id =
        edition_record.championship_id
      AND championship_sports_table.sport_id =
        competitions_table.sport_id

    LEFT JOIN public.sports
      AS sports_table
      ON sports_table.id =
        competitions_table.sport_id

    WHERE competitions_table.bracket_edition_id =
      _bracket_edition_id

    ORDER BY
      COALESCE(
        sports_table.name,
        ''
      ) ASC,

      competitions_table.sport_id ASC,

      CASE competitions_table.naipe
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
      END ASC,

      CASE competitions_table.division
        WHEN 'DIVISAO_PRINCIPAL'
          ::public.team_division
        THEN 1

        WHEN 'DIVISAO_ACESSO'
          ::public.team_division
        THEN 2

        ELSE 99
      END ASC,

      competitions_table.id ASC
  LOOP
    direct_qualified_team_count :=
      GREATEST(
        0,
        competition_record.groups_count
          * competition_record.qualifiers_per_group
      );


    /*
     * deterministic_knockout_preview_order
     *
     * Mantém a projeção idêntica à geração oficial.
     */
    bracket_size := 1;


    IF competition_record.qualifiers_per_group = 1
      AND competition_record
        .should_complete_knockout_with_best_second_placed_teams =
          true
    THEN
      /*
       * Modo expandido:
       *
       * mesmo quando os primeiros já fecham uma chave válida,
       * avança para a próxima potência de 2.
       *
       * Exemplo:
       * 4 primeiros → chave de 8.
       */
      WHILE
        bracket_size <=
          direct_qualified_team_count
      LOOP
        bracket_size :=
          bracket_size * 2;
      END LOOP;

    ELSE
      /*
       * Modo normal/SMART:
       *
       * utiliza a menor potência de 2 capaz de comportar os
       * classificados diretos.
       *
       * Quando qualifiers_per_group = 1 e a potência é maior que
       * a quantidade de primeiros, as vagas restantes são preenchidas
       * pelos melhores segundos colocados.
       *
       * Exemplo:
       * 5 primeiros → chave de 8 → +3 melhores segundos.
       */
      WHILE
        bracket_size <
          direct_qualified_team_count
      LOOP
        bracket_size :=
          bracket_size * 2;
      END LOOP;
    END IF;


    qualified_team_count :=
      CASE
        WHEN competition_record.qualifiers_per_group = 1
          AND bracket_size >
            direct_qualified_team_count
        THEN
          bracket_size

        ELSE
          direct_qualified_team_count
      END;


    IF qualified_team_count < 2
      OR bracket_size < 2
    THEN
      CONTINUE;
    END IF;


    total_rounds := 0;
    bracket_size_cursor :=
      bracket_size;

    WHILE bracket_size_cursor > 1
    LOOP
      bracket_size_cursor :=
        bracket_size_cursor / 2;

      total_rounds :=
        total_rounds + 1;
    END LOOP;


    /*
     * Momento em que a fase de grupos desta competição termina.
     *
     * O primeiro jogo efetivamente disputado do mata-mata pode
     * começar exatamente neste horário. Não existe descanso
     * adicional obrigatório no mata-mata.
     */
    SELECT
      COUNT(*)::integer,

      COALESCE(
        bool_and(
          matches_table.start_time IS NOT NULL
          AND matches_table.end_time IS NOT NULL
        ),
        false
      ),

      MAX(matches_table.end_time)

    INTO
      group_match_count,
      group_schedule_complete,
      group_ready_at

    FROM public.championship_bracket_matches
      AS bracket_matches_table

    JOIN public.matches
      AS matches_table
      ON matches_table.id =
        bracket_matches_table.match_id

    WHERE bracket_matches_table.competition_id =
        competition_record.id

      AND bracket_matches_table.phase =
        'GROUP_STAGE'::public.bracket_phase;


    IF group_match_count < 1
      OR group_schedule_complete IS NOT TRUE
      OR group_ready_at IS NULL
    THEN
      INSERT INTO
        tmp_knockout_schedule_conflicts (
          conflict_code,
          conflict_message,
          competition_id
        )
      VALUES (
        'GROUP_STAGE_NOT_SCHEDULED',

        'A fase de grupos da competição não possui todos os horários necessários para determinar o início do mata-mata.',

        competition_record.id
      );
    END IF;


    FOR round_number_value IN
      1..total_rounds
    LOOP
      round_match_count :=
        power(
          2,
          total_rounds
            - round_number_value
        )::integer;


      FOR slot_number_value IN
        1..round_match_count
      LOOP
        is_bye_value := false;


        /*
         * O gerador oficial usa a ordem:
         *
         * 1 x último seed
         * 2 x penúltimo seed
         * 3 x antepenúltimo seed
         * ...
         *
         * Portanto os BYEs da primeira rodada podem ser previstos
         * apenas com a quantidade de classificados, sem conhecer
         * quais atléticas serão classificadas.
         */
        IF round_number_value = 1
          AND qualified_team_count <
            bracket_size
        THEN
          first_round_home_seed :=
            slot_number_value;

          first_round_away_seed :=
            bracket_size
              + 1
              - slot_number_value;

          is_bye_value :=
            (
              first_round_home_seed >
                qualified_team_count
            )
            <>
            (
              first_round_away_seed >
                qualified_team_count
            );
        END IF;


        SELECT EXISTS (
          SELECT 1
          FROM tmp_knockout_manual_finals
            AS manual_finals_table
          WHERE manual_finals_table.competition_id =
              competition_record.id

            AND manual_finals_table.expected_final_round =
              round_number_value
        )
        INTO is_manual_final_value;


        is_manual_final_value :=
          is_manual_final_value
          AND round_number_value =
            total_rounds
          AND slot_number_value = 1;


        INSERT INTO
          tmp_knockout_pending_matches (
            competition_id,
            sport_id,
            naipe,
            division,
            total_rounds,
            round_number,
            slot_number,
            duration_minutes,
            is_bye,
            is_manual_final,
            group_ready_at,
            planned_start_at,
            planned_end_at
          )
        VALUES (
          competition_record.id,
          competition_record.sport_id,
          competition_record.naipe,
          competition_record.division,
          total_rounds,
          round_number_value,
          slot_number_value,
          competition_record.duration_minutes,
          is_bye_value,
          is_manual_final_value,
          group_ready_at,

          CASE
            WHEN is_bye_value
            THEN group_ready_at
            ELSE NULL
          END,

          CASE
            WHEN is_bye_value
            THEN group_ready_at
            ELSE NULL
          END
        );
      END LOOP;
    END LOOP;
  END LOOP;


  /*
   * Agenda das partidas automáticas.
   *
   * A cada iteração escolhemos globalmente o próximo horário
   * cronológico possível entre todas as partidas cujas dependências
   * já estão resolvidas.
   */
  LOOP
    SELECT COUNT(*)::integer
    INTO remaining_automatic_count
    FROM tmp_knockout_pending_matches
      AS pending_table
    WHERE pending_table.is_bye = false
      AND pending_table.is_manual_final = false
      AND pending_table.failed = false
      AND pending_table.planned_start_at
        IS NULL;


    EXIT WHEN
      remaining_automatic_count = 0;


    best_pending_row_id := NULL;

    best_start_at := NULL;
    best_end_at := NULL;

    best_scheduled_date := NULL;
    best_schedule_period := NULL;

    best_location_name := NULL;
    best_court_name := NULL;

    best_location_group_id := NULL;
    best_court_group_id := NULL;

    best_bracket_day_id := NULL;
    best_bracket_court_id := NULL;

    best_duration_minutes := NULL;

    best_priority_rank := NULL;
    best_location_position := NULL;
    best_court_position := NULL;


    FOR pending_record IN
      SELECT
        pending_table.*
      FROM tmp_knockout_pending_matches
        AS pending_table
      WHERE pending_table.is_bye = false
        AND pending_table.is_manual_final = false
        AND pending_table.failed = false
        AND pending_table.planned_start_at
          IS NULL
      ORDER BY
        pending_table.round_number ASC,

        pending_table.sport_id ASC,

        CASE pending_table.naipe
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
        END ASC,

        CASE pending_table.division
          WHEN 'DIVISAO_PRINCIPAL'
            ::public.team_division
          THEN 1

          WHEN 'DIVISAO_ACESSO'
            ::public.team_division
          THEN 2

          ELSE 99
        END ASC,

        pending_table.slot_number ASC,

        pending_table.competition_id ASC
    LOOP
      dependency_ready_at := NULL;


      IF pending_record.round_number = 1
      THEN
        dependency_ready_at :=
          pending_record.group_ready_at;
      ELSE
        SELECT
          COUNT(*)::integer,

          MAX(
            feeder_table.planned_end_at
          )
        INTO
          feeder_count,
          dependency_ready_at
        FROM tmp_knockout_pending_matches
          AS feeder_table
        WHERE feeder_table.competition_id =
            pending_record.competition_id

          AND feeder_table.round_number =
            pending_record.round_number - 1

          AND feeder_table.slot_number IN (
            (pending_record.slot_number * 2) - 1,
            pending_record.slot_number * 2
          )

          AND feeder_table.failed = false

          AND feeder_table.planned_end_at
            IS NOT NULL;


        IF feeder_count <> 2
        THEN
          dependency_ready_at := NULL;
        END IF;
      END IF;


      /*
       * Enquanto as partidas alimentadoras não possuírem horário,
       * este nó ainda não pode competir por uma vaga na agenda.
       */
      IF dependency_ready_at IS NULL
      THEN
        CONTINUE;
      END IF;


      resolved_phase :=
        public.resolve_bracket_knockout_match_phase(
          pending_record.round_number,
          pending_record.total_rounds,
          false
        );


      resolved_division_scope :=
        public.resolve_bracket_knockout_division_scope(
          pending_record.division
        );


      resolved_preferred_court_group_id :=
        public
          .resolve_bracket_knockout_priority_court_group_id(
            _bracket_edition_id,
            pending_record.sport_id,
            resolved_phase,
            resolved_division_scope
          );


      competition_key_value :=
        pending_record.sport_id::text
        || '::'
        || pending_record.naipe::text
        || '::'
        || COALESCE(
          pending_record.division::text,
          'WITHOUT_DIVISION'
        );


      FOR court_record IN
        SELECT
          days_table.id
            AS bracket_day_id,

          days_table.event_date,

          days_table.start_time
            AS day_start_time,

          days_table.end_time
            AS day_end_time,

          days_table.break_start_time,
          days_table.break_end_time,

          locations_table.name
            AS location_name,

          locations_table.location_group_id,

          locations_table.position
            AS location_position,

          courts_table.id
            AS bracket_court_id,

          courts_table.name
            AS court_name,

          courts_table.court_group_id,

          courts_table.position
            AS court_position,

          court_sports_table.sequence_mode,
          court_sports_table.preferred_naipe,
          court_sports_table.preferred_division

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

          AND court_sports_table.sport_id =
            pending_record.sport_id

        ORDER BY
          days_table.event_date ASC,
          locations_table.position ASC,
          courts_table.position ASC,
          locations_table.name ASC,
          courts_table.name ASC
      LOOP
        /*
         * GROUP_NAIPE:
         *
         * enquanto ainda existir qualquer partida automática
         * pendente do naipe preferencial daquela modalidade,
         * os outros naipes não utilizam esta quadra.
         *
         * Isso é deliberadamente estrito:
         * se o naipe ativo estiver temporariamente impedido,
         * a quadra pode ficar vazia em vez de quebrar o agrupamento.
         *
         * Finais manuais não participam deste bloqueio.
         */
        IF court_record.sequence_mode =
            'GROUP_NAIPE'
              ::public.bracket_court_sequence_mode

          AND court_record.preferred_naipe
            IS NOT NULL

          AND pending_record.naipe IS DISTINCT FROM
            court_record.preferred_naipe

          AND EXISTS (
            SELECT 1
            FROM tmp_knockout_pending_matches
              AS strict_pending_table
            WHERE strict_pending_table.sport_id =
                pending_record.sport_id

              AND strict_pending_table.naipe =
                court_record.preferred_naipe

              AND strict_pending_table.is_bye =
                false

              AND strict_pending_table.is_manual_final =
                false

              AND strict_pending_table.failed =
                false

              AND strict_pending_table.planned_start_at
                IS NULL
          )
        THEN
          CONTINUE;
        END IF;


        /*
         * GROUP_DIVISION:
         *
         * mesma regra, agora pelo agrupamento Principal/Acesso.
         */
        IF court_record.sequence_mode =
            'GROUP_DIVISION'
              ::public.bracket_court_sequence_mode

          AND court_record.preferred_division
            IS NOT NULL

          AND pending_record.division
            IS DISTINCT FROM
              court_record.preferred_division

          AND EXISTS (
            SELECT 1
            FROM tmp_knockout_pending_matches
              AS strict_pending_table
            WHERE strict_pending_table.sport_id =
                pending_record.sport_id

              AND strict_pending_table.division =
                court_record.preferred_division

              AND strict_pending_table.is_bye =
                false

              AND strict_pending_table.is_manual_final =
                false

              AND strict_pending_table.failed =
                false

              AND strict_pending_table.planned_start_at
                IS NULL
          )
        THEN
          CONTINUE;
        END IF;


        day_start_at :=
          public.combine_bracket_schedule_timestamp(
            court_record.event_date,
            court_record.day_start_time
          );


        day_end_at :=
          public.combine_bracket_schedule_timestamp(
            court_record.event_date,
            court_record.day_end_time
          );


        day_middle_at :=
          day_start_at
          + (
            (
              day_end_at
              - day_start_at
            ) / 2.0
          );


        FOR availability_window_record IN
          SELECT
            availability_windows.window_start_at,
            availability_windows.window_end_at
          FROM public.resolve_championship_bracket_competition_schedule_windows(
            edition_record.payload_snapshot,
            competition_key_value,
            court_record.event_date
          ) AS availability_windows
          ORDER BY
            availability_windows.window_start_at ASC,
            availability_windows.window_end_at ASC
        LOOP
          period_start_at :=
            availability_window_record.window_start_at;

          period_end_at :=
            availability_window_record.window_end_at;


          IF period_start_at >=
            period_end_at
          THEN
            CONTINUE;
          END IF;


          candidate_start_at :=
            GREATEST(
              period_start_at,
              dependency_ready_at
            );


          IF candidate_start_at >=
            period_end_at
          THEN
            CONTINUE;
          END IF;


          candidate_is_valid :=
            false;


          /*
           * Empurra o início para frente enquanto houver:
           *
           * - partida existente;
           * - reserva automática já calculada;
           * - final manual fixa;
           * - pausa geral;
           * - pausa específica da quadra.
           *
           * Como o próximo início sempre se torna o fim de algum
           * conflito, não precisamos utilizar intervalos artificiais
           * ou arredondamento de minutos.
           */
          LOOP
            candidate_end_at :=
              candidate_start_at
              + make_interval(
                mins =>
                  pending_record.duration_minutes
              );


            IF candidate_end_at >
              period_end_at
            THEN
              EXIT;
            END IF;


            candidate_conflict_end_at :=
              NULL;


            SELECT
              MAX(conflicts.conflict_end_at)
            INTO candidate_conflict_end_at
            FROM (
              /*
               * Partidas já materializadas:
               * grupos ou qualquer outro jogo real que ocupe a quadra.
               */
              SELECT
                matches_table.end_time
                  AS conflict_end_at

              FROM public.matches
                AS matches_table

              WHERE matches_table.start_time
                  IS NOT NULL

                AND matches_table.end_time
                  IS NOT NULL

                AND public.normalize_bracket_entity_name(
                  matches_table.location
                ) =
                  public.normalize_bracket_entity_name(
                    court_record.location_name
                  )

                AND public.normalize_bracket_entity_name(
                  COALESCE(
                    matches_table.court_name,
                    ''
                  )
                ) =
                  public.normalize_bracket_entity_name(
                    court_record.court_name
                  )

                AND matches_table.start_time <
                  candidate_end_at

                AND matches_table.end_time >
                  candidate_start_at


              UNION ALL


              /*
               * Reservas automáticas escolhidas anteriormente.
               */
              SELECT
                reservations_table.end_at
                  AS conflict_end_at

              FROM
                public
                  .championship_bracket_knockout_schedule_reservations
                    AS reservations_table

              WHERE reservations_table.bracket_edition_id =
                  _bracket_edition_id

                AND reservations_table.bracket_court_id =
                  court_record.bracket_court_id

                AND reservations_table.scheduled_date =
                  court_record.event_date

                AND reservations_table.start_at <
                  candidate_end_at

                AND reservations_table.end_at >
                  candidate_start_at


              UNION ALL


              /*
               * Finais manuais ainda não inseridas na tabela definitiva,
               * mas que já funcionam como ocupação fixa da quadra.
               */
              SELECT
                manual_finals_table.planned_end_at
                  AS conflict_end_at

              FROM tmp_knockout_manual_finals
                AS manual_finals_table

              WHERE manual_finals_table.scheduled_date =
                  court_record.event_date

                AND public.normalize_bracket_entity_name(
                  manual_finals_table.location_name
                ) =
                  public.normalize_bracket_entity_name(
                    court_record.location_name
                  )

                AND public.normalize_bracket_entity_name(
                  manual_finals_table.court_name
                ) =
                  public.normalize_bracket_entity_name(
                    court_record.court_name
                  )

                AND manual_finals_table.planned_start_at <
                  candidate_end_at

                AND manual_finals_table.planned_end_at >
                  candidate_start_at


              UNION ALL


              /*
               * Bloqueios HARD continuam ocupando a janela legada do período.
               */
              SELECT
                lock_bounds.period_end_at
                  AS conflict_end_at

              FROM jsonb_array_elements(
                CASE
                  WHEN jsonb_typeof(
                    edition_record.payload_snapshot
                      -> 'resource_locks'
                  ) = 'array'
                  THEN
                    edition_record.payload_snapshot
                      -> 'resource_locks'
                  ELSE
                    '[]'::jsonb
                END
              ) AS lock_record(value)

              CROSS JOIN LATERAL
                public.resolve_bracket_schedule_period_bounds_from_payload(
                  edition_record.payload_snapshot,
                  court_record.event_date,
                  (
                    lock_record.value ->> 'period'
                  )::public.championship_schedule_period
                ) AS lock_bounds

              WHERE COALESCE(
                  lock_record.value ->> 'lock_mode',
                  ''
                ) = 'HARD'

                AND NULLIF(
                  lock_record.value ->> 'date',
                  ''
                )::date =
                  court_record.event_date

                AND public.normalize_bracket_entity_name(
                  COALESCE(
                    lock_record.value ->> 'location_name',
                    ''
                  )
                ) =
                  public.normalize_bracket_entity_name(
                    court_record.location_name
                  )

                AND public.normalize_bracket_entity_name(
                  COALESCE(
                    lock_record.value ->> 'court_name',
                    ''
                  )
                ) =
                  public.normalize_bracket_entity_name(
                    court_record.court_name
                  )

                AND lock_bounds.period_start_at <
                  candidate_end_at

                AND lock_bounds.period_end_at >
                  candidate_start_at


              UNION ALL


              /*
               * Pausas modernas da agenda.
               */
              SELECT
                public.combine_bracket_schedule_timestamp(
                  court_record.event_date,
                  breaks_table.break_end_time
                ) AS conflict_end_at

              FROM public.championship_bracket_day_breaks
                AS breaks_table

              WHERE breaks_table.bracket_day_id =
                  court_record.bracket_day_id

                AND (
                  breaks_table.scope_type =
                    'ALL_COURTS'
                      ::public.bracket_day_break_scope_type

                  OR (
                    breaks_table.scope_type =
                      'COURT'
                        ::public.bracket_day_break_scope_type

                    AND breaks_table.bracket_court_id =
                      court_record.bracket_court_id
                  )
                )

                AND
                  public.combine_bracket_schedule_timestamp(
                    court_record.event_date,
                    breaks_table.break_start_time
                  ) <
                    candidate_end_at

                AND
                  public.combine_bracket_schedule_timestamp(
                    court_record.event_date,
                    breaks_table.break_end_time
                  ) >
                    candidate_start_at


              UNION ALL


              /*
               * Compatibilidade com o intervalo legado de pausa
               * ainda armazenado diretamente no dia.
               */
              SELECT
                public.combine_bracket_schedule_timestamp(
                  court_record.event_date,
                  court_record.break_end_time
                ) AS conflict_end_at

              WHERE court_record.break_start_time
                  IS NOT NULL

                AND court_record.break_end_time
                  IS NOT NULL

                AND
                  public.combine_bracket_schedule_timestamp(
                    court_record.event_date,
                    court_record.break_start_time
                  ) <
                    candidate_end_at

                AND
                  public.combine_bracket_schedule_timestamp(
                    court_record.event_date,
                    court_record.break_end_time
                  ) >
                    candidate_start_at
            ) AS conflicts;


            IF candidate_conflict_end_at
              IS NULL
            THEN
              candidate_is_valid :=
                true;

              EXIT;
            END IF;


            candidate_start_at :=
              candidate_conflict_end_at;


            IF candidate_start_at >=
              period_end_at
            THEN
              EXIT;
            END IF;
          END LOOP;


          IF candidate_is_valid
            IS NOT TRUE
          THEN
            CONTINUE;
          END IF;


          candidate_priority_rank :=
            CASE
              WHEN resolved_preferred_court_group_id
                IS NOT NULL

                AND court_record.court_group_id =
                  resolved_preferred_court_group_id

              THEN 0
              ELSE 1
            END;


          /*
           * Seleciona globalmente o horário mais cedo.
           *
           * Para empates no mesmo instante:
           * 1. prioridade de quadra do mata-mata;
           * 2. posição do local;
           * 3. posição da quadra;
           * 4. identificador da partida projetada.
           */
          IF best_pending_row_id
              IS NULL

            OR candidate_start_at <
              best_start_at

            OR (
              candidate_start_at =
                best_start_at

              AND candidate_priority_rank <
                best_priority_rank
            )

            OR (
              candidate_start_at =
                best_start_at

              AND candidate_priority_rank =
                best_priority_rank

              AND court_record.location_position <
                best_location_position
            )

            OR (
              candidate_start_at =
                best_start_at

              AND candidate_priority_rank =
                best_priority_rank

              AND court_record.location_position =
                best_location_position

              AND court_record.court_position <
                best_court_position
            )

            OR (
              candidate_start_at =
                best_start_at

              AND candidate_priority_rank =
                best_priority_rank

              AND court_record.location_position =
                best_location_position

              AND court_record.court_position =
                best_court_position

              AND pending_record.row_id <
                best_pending_row_id
            )
          THEN
            best_pending_row_id :=
              pending_record.row_id;

            best_start_at :=
              candidate_start_at;

            best_end_at :=
              candidate_end_at;

            best_scheduled_date :=
              court_record.event_date;

            best_schedule_period :=
              public.resolve_bracket_schedule_period_by_timestamp(
                edition_record.payload_snapshot,
                court_record.event_date,
                candidate_start_at
              );

            best_location_name :=
              court_record.location_name;

            best_court_name :=
              court_record.court_name;

            best_location_group_id :=
              court_record.location_group_id;

            best_court_group_id :=
              court_record.court_group_id;

            best_bracket_day_id :=
              court_record.bracket_day_id;

            best_bracket_court_id :=
              court_record.bracket_court_id;

            best_duration_minutes :=
              pending_record.duration_minutes;

            best_priority_rank :=
              candidate_priority_rank;

            best_location_position :=
              court_record.location_position;

            best_court_position :=
              court_record.court_position;
          END IF;
        END LOOP;
      END LOOP;
    END LOOP;


    /*
     * Nenhuma partida atualmente elegível encontrou horário.
     *
     * Em modo de preview marcamos uma partida como falha,
     * liberando o restante da simulação para produzir o máximo
     * possível da agenda e mostrar os demais horários ao usuário.
     */
    IF best_pending_row_id IS NULL
    THEN
      SELECT
        pending_table.*
      INTO pending_record
      FROM tmp_knockout_pending_matches
        AS pending_table
      WHERE pending_table.is_bye = false
        AND pending_table.is_manual_final = false
        AND pending_table.failed = false
        AND pending_table.planned_start_at
          IS NULL
      ORDER BY
        pending_table.round_number ASC,

        pending_table.sport_id ASC,

        CASE pending_table.naipe
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
        END ASC,

        CASE pending_table.division
          WHEN 'DIVISAO_PRINCIPAL'
            ::public.team_division
          THEN 1

          WHEN 'DIVISAO_ACESSO'
            ::public.team_division
          THEN 2

          ELSE 99
        END ASC,

        pending_table.slot_number ASC,

        pending_table.competition_id ASC
      LIMIT 1;


      IF pending_record.row_id IS NULL
      THEN
        EXIT;
      END IF;


      IF pending_record.round_number = 1
      THEN
        dependency_ready_at :=
          pending_record.group_ready_at;
      ELSE
        SELECT
          COUNT(*)::integer,
          MAX(feeder_table.planned_end_at)
        INTO
          feeder_count,
          dependency_ready_at
        FROM tmp_knockout_pending_matches
          AS feeder_table
        WHERE feeder_table.competition_id =
            pending_record.competition_id

          AND feeder_table.round_number =
            pending_record.round_number - 1

          AND feeder_table.slot_number IN (
            (pending_record.slot_number * 2) - 1,
            pending_record.slot_number * 2
          )

          AND feeder_table.failed = false

          AND feeder_table.planned_end_at
            IS NOT NULL;


        IF feeder_count <> 2
        THEN
          dependency_ready_at := NULL;
        END IF;
      END IF;


      INSERT INTO
        tmp_knockout_schedule_conflicts (
          conflict_code,
          conflict_message,
          competition_id,
          round_number,
          slot_number
        )
      VALUES (
        CASE
          WHEN dependency_ready_at IS NULL
          THEN
            'KNOCKOUT_DEPENDENCY_UNSCHEDULED'
          ELSE
            'KNOCKOUT_NO_AVAILABLE_SLOT'
        END,

        CASE
          WHEN dependency_ready_at IS NULL
          THEN
            'Não foi possível programar esta partida porque uma das partidas alimentadoras não possui horário válido.'
          ELSE
            'Não existe janela de agenda compatível para programar esta partida do mata-mata após a conclusão de suas dependências.'
        END,

        pending_record.competition_id,
        pending_record.round_number,
        pending_record.slot_number
      );


      UPDATE tmp_knockout_pending_matches
      SET failed = true
      WHERE row_id =
        pending_record.row_id;


      CONTINUE;
    END IF;


    SELECT
      pending_table.*
    INTO pending_record
    FROM tmp_knockout_pending_matches
      AS pending_table
    WHERE pending_table.row_id =
      best_pending_row_id;


    /*
     * scheduled_slot / queue_position permanecem valores
     * operacionais.
     *
     * A numeração visual COURT / SPORT_NAIPE é calculada
     * separadamente e não utiliza estes campos.
     */
    SELECT
      (
        1

        + COUNT(*) FILTER (
          WHERE chronology.source_type =
            'MATCH'
        )

        + COUNT(*) FILTER (
          WHERE chronology.source_type =
            'RESERVATION'
        )

        + COUNT(*) FILTER (
          WHERE chronology.source_type =
            'MANUAL_FINAL'
        )
      )::integer

    INTO selected_scheduled_slot

    FROM (
      SELECT
        'MATCH'::text
          AS source_type,

        matches_table.start_time
          AS start_at

      FROM public.matches
        AS matches_table

      WHERE matches_table.start_time
          IS NOT NULL

        AND public.normalize_bracket_entity_name(
          matches_table.location
        ) =
          public.normalize_bracket_entity_name(
            best_location_name
          )

        AND public.normalize_bracket_entity_name(
          COALESCE(
            matches_table.court_name,
            ''
          )
        ) =
          public.normalize_bracket_entity_name(
            best_court_name
          )

        AND (
          matches_table.start_time
          AT TIME ZONE 'America/Sao_Paulo'
        )::date =
          best_scheduled_date

        AND matches_table.start_time <
          best_start_at


      UNION ALL


      SELECT
        'RESERVATION'::text,

        reservations_table.start_at

      FROM
        public
          .championship_bracket_knockout_schedule_reservations
            AS reservations_table

      WHERE reservations_table.bracket_edition_id =
          _bracket_edition_id

        AND reservations_table.bracket_court_id =
          best_bracket_court_id

        AND reservations_table.scheduled_date =
          best_scheduled_date

        AND reservations_table.start_at <
          best_start_at


      UNION ALL


      SELECT
        'MANUAL_FINAL'::text,

        manual_finals_table.planned_start_at

      FROM tmp_knockout_manual_finals
        AS manual_finals_table

      WHERE manual_finals_table.scheduled_date =
          best_scheduled_date

        AND public.normalize_bracket_entity_name(
          manual_finals_table.location_name
        ) =
          public.normalize_bracket_entity_name(
            best_location_name
          )

        AND public.normalize_bracket_entity_name(
          manual_finals_table.court_name
        ) =
          public.normalize_bracket_entity_name(
            best_court_name
          )

        AND manual_finals_table.planned_start_at <
          best_start_at
    ) AS chronology;


    selected_scheduled_slot :=
      GREATEST(
        1,
        COALESCE(
          selected_scheduled_slot,
          1
        )
      );


    selected_queue_position :=
      selected_scheduled_slot;


    INSERT INTO
      public
        .championship_bracket_knockout_schedule_reservations (
          bracket_edition_id,
          competition_id,

          round_number,
          slot_number,

          is_third_place,

          scheduled_date,
          schedule_period,

          location_name,
          court_name,

          location_group_id,
          court_group_id,

          bracket_day_id,
          bracket_court_id,

          scheduled_slot,
          queue_position,

          start_at,
          end_at,

          duration_minutes,

          is_manual_final
        )
    VALUES (
      _bracket_edition_id,
      pending_record.competition_id,

      pending_record.round_number,
      pending_record.slot_number,

      false,

      best_scheduled_date,
      best_schedule_period,

      best_location_name,
      best_court_name,

      best_location_group_id,
      best_court_group_id,

      best_bracket_day_id,
      best_bracket_court_id,

      selected_scheduled_slot,
      selected_queue_position,

      best_start_at,
      best_end_at,

      best_duration_minutes,

      false
    );


    UPDATE tmp_knockout_pending_matches
    SET
      planned_start_at =
        best_start_at,

      planned_end_at =
        best_end_at

    WHERE row_id =
      best_pending_row_id;
  END LOOP;


  /*
   * As finais manuais são materializadas por último.
   *
   * Seus horários, entretanto, já foram considerados como bloqueios
   * fixos durante todo o planejamento automático.
   */
  FOR manual_final_record IN
    SELECT
      manual_finals_table.*
    FROM tmp_knockout_manual_finals
      AS manual_finals_table
    ORDER BY
      manual_finals_table.planned_start_at ASC,
      manual_finals_table.display_order ASC,
      manual_finals_table.naipe_position ASC
  LOOP
    SELECT
      pending_table.*
    INTO pending_record
    FROM tmp_knockout_pending_matches
      AS pending_table
    WHERE pending_table.competition_id =
        manual_final_record.competition_id

      AND pending_table.round_number =
        manual_final_record.expected_final_round

      AND pending_table.slot_number = 1
    LIMIT 1;


    IF pending_record.row_id IS NULL
    THEN
      INSERT INTO
        tmp_knockout_schedule_conflicts (
          conflict_code,
          conflict_message,
          competition_id,
          round_number,
          slot_number
        )
      VALUES (
        'MANUAL_FINAL_WITHOUT_PROJECTED_MATCH',

        'A final manual configurada não corresponde a uma final projetada válida para esta competição.',

        manual_final_record.competition_id,
        manual_final_record.expected_final_round,
        1
      );

      CONTINUE;
    END IF;


    manual_dependency_ready_at :=
      NULL;


    IF pending_record.round_number = 1
    THEN
      manual_dependency_ready_at :=
        pending_record.group_ready_at;
    ELSE
      SELECT
        COUNT(*)::integer,
        MAX(feeder_table.planned_end_at)
      INTO
        feeder_count,
        manual_dependency_ready_at
      FROM tmp_knockout_pending_matches
        AS feeder_table
      WHERE feeder_table.competition_id =
          pending_record.competition_id

        AND feeder_table.round_number =
          pending_record.round_number - 1

        AND feeder_table.slot_number IN (
          1,
          2
        )

        AND feeder_table.failed = false

        AND feeder_table.planned_end_at
          IS NOT NULL;


      IF feeder_count <> 2
      THEN
        manual_dependency_ready_at :=
          NULL;
      END IF;
    END IF;


    /*
     * Regra deliberada:
     *
     * semifinal termina 14:00
     * final manual começa 14:00
     * => válido.
     *
     * semifinal termina 14:01
     * final manual começa 14:00
     * => conflito.
     *
     * A final nunca é deslocada automaticamente.
     */
    IF manual_dependency_ready_at
        IS NULL

      OR manual_dependency_ready_at >
        manual_final_record.planned_start_at
    THEN
      INSERT INTO
        tmp_knockout_schedule_conflicts (
          conflict_code,
          conflict_message,
          competition_id,
          round_number,
          slot_number
        )
      VALUES (
        'MANUAL_FINAL_DEPENDENCY_CONFLICT',

        CASE
          WHEN manual_dependency_ready_at
            IS NULL
          THEN
            'A final manual não pode ser validada porque uma das partidas alimentadoras não possui horário válido.'
          ELSE
            'A final manual está programada antes da conclusão de uma das partidas alimentadoras. A final não será deslocada automaticamente.'
        END,

        manual_final_record.competition_id,
        manual_final_record.expected_final_round,
        1
      );
    END IF;


    INSERT INTO
      public
        .championship_bracket_knockout_schedule_reservations (
          bracket_edition_id,
          competition_id,

          round_number,
          slot_number,

          is_third_place,

          scheduled_date,
          schedule_period,

          location_name,
          court_name,

          location_group_id,
          court_group_id,

          bracket_day_id,
          bracket_court_id,

          scheduled_slot,
          queue_position,

          start_at,
          end_at,

          duration_minutes,

          is_manual_final
        )
    VALUES (
      _bracket_edition_id,
      manual_final_record.competition_id,

      manual_final_record.expected_final_round,
      1,

      false,

      manual_final_record.scheduled_date,
      manual_final_record.schedule_period,

      manual_final_record.location_name,
      manual_final_record.court_name,

      manual_final_record.location_group_id,
      manual_final_record.court_group_id,

      manual_final_record.bracket_day_id,
      manual_final_record.bracket_court_id,

      GREATEST(
        1,
        manual_final_record.planned_scheduled_slot
      ),

      GREATEST(
        1,
        manual_final_record.planned_queue_position
      ),

      manual_final_record.planned_start_at,
      manual_final_record.planned_end_at,

      manual_final_record.duration_minutes,

      true
    )
    ON CONFLICT (
      competition_id,
      round_number,
      slot_number
    )
    DO UPDATE SET
      bracket_edition_id =
        EXCLUDED.bracket_edition_id,

      scheduled_date =
        EXCLUDED.scheduled_date,

      schedule_period =
        EXCLUDED.schedule_period,

      location_name =
        EXCLUDED.location_name,

      court_name =
        EXCLUDED.court_name,

      location_group_id =
        EXCLUDED.location_group_id,

      court_group_id =
        EXCLUDED.court_group_id,

      bracket_day_id =
        EXCLUDED.bracket_day_id,

      bracket_court_id =
        EXCLUDED.bracket_court_id,

      scheduled_slot =
        EXCLUDED.scheduled_slot,

      queue_position =
        EXCLUDED.queue_position,

      start_at =
        EXCLUDED.start_at,

      end_at =
        EXCLUDED.end_at,

      duration_minutes =
        EXCLUDED.duration_minutes,

      is_manual_final =
        true;


    UPDATE tmp_knockout_pending_matches
    SET
      planned_start_at =
        manual_final_record.planned_start_at,

      planned_end_at =
        manual_final_record.planned_end_at

    WHERE row_id =
      pending_record.row_id;
  END LOOP;


  SELECT
    COUNT(*)::integer
  INTO expected_match_count
  FROM tmp_knockout_pending_matches
    AS pending_table
  WHERE pending_table.is_bye =
    false;


  SELECT
    COUNT(*)::integer
  INTO scheduled_match_count
  FROM
    public
      .championship_bracket_knockout_schedule_reservations
        AS reservations_table
  WHERE reservations_table.bracket_edition_id =
    _bracket_edition_id;


  SELECT
    COUNT(*)::integer
  INTO conflict_count
  FROM tmp_knockout_schedule_conflicts;


  SELECT
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'code',
          conflicts_table.conflict_code,

          'message',
          conflicts_table.conflict_message,

          'competition_id',
          conflicts_table.competition_id,

          'round_number',
          conflicts_table.round_number,

          'slot_number',
          conflicts_table.slot_number
        )
        ORDER BY
          conflicts_table.row_id ASC
      ),
      '[]'::jsonb
    )
  INTO result_conflicts
  FROM tmp_knockout_schedule_conflicts
    AS conflicts_table;


  /*
   * Uma diferença entre a quantidade esperada e a quantidade
   * reservada também é considerada conflito, mesmo que nenhuma
   * mensagem específica tenha sido registrada anteriormente.
   */
  IF scheduled_match_count <>
      expected_match_count

    AND NOT EXISTS (
      SELECT 1
      FROM tmp_knockout_schedule_conflicts
    )
  THEN
    INSERT INTO
      tmp_knockout_schedule_conflicts (
        conflict_code,
        conflict_message
      )
    VALUES (
      'KNOCKOUT_INCOMPLETE_SCHEDULE',

      format(
        'A agenda do mata-mata reservou %s de %s partidas projetadas.',
        scheduled_match_count,
        expected_match_count
      )
    );


    conflict_count :=
      conflict_count + 1;


    SELECT
      COALESCE(
        jsonb_agg(
          jsonb_build_object(
            'code',
            conflicts_table.conflict_code,

            'message',
            conflicts_table.conflict_message,

            'competition_id',
            conflicts_table.competition_id,

            'round_number',
            conflicts_table.round_number,

            'slot_number',
            conflicts_table.slot_number
          )
          ORDER BY
            conflicts_table.row_id ASC
        ),
        '[]'::jsonb
      )
    INTO result_conflicts
    FROM tmp_knockout_schedule_conflicts
      AS conflicts_table;
  END IF;


  IF _strict
    AND conflict_count > 0
  THEN
    SELECT
      conflicts_table.conflict_message
    INTO first_conflict_message
    FROM tmp_knockout_schedule_conflicts
      AS conflicts_table
    ORDER BY
      conflicts_table.row_id ASC
    LIMIT 1;


    RAISE EXCEPTION
      'Não foi possível reservar toda a agenda do mata-mata: %',
      COALESCE(
        first_conflict_message,
        'existem conflitos de programação.'
      );
  END IF;


  RETURN jsonb_build_object(
    'ok',
      conflict_count = 0
      AND scheduled_match_count =
        expected_match_count,

    'expected_matches',
      expected_match_count,

    'scheduled_matches',
      scheduled_match_count,

    'conflict_count',
      conflict_count,

    'conflicts',
      result_conflicts
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_bracket_fixed_block_bounds_from_payload(_payload jsonb, _event_date date, _start_time_text text, _end_time_text text, _legacy_period championship_schedule_period DEFAULT NULL::championship_schedule_period)
 RETURNS TABLE(schedule_period championship_schedule_period, period_start_at timestamp with time zone, period_end_at timestamp with time zone, duration_minutes integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  day_bounds RECORD;
  explicit_start_time TIME;
  explicit_end_time TIME;
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

  IF NULLIF(_start_time_text, '') IS NOT NULL
    AND NULLIF(_end_time_text, '') IS NOT NULL
  THEN
    explicit_start_time := _start_time_text::time;
    explicit_end_time := _end_time_text::time;

    period_start_at :=
      public.combine_bracket_schedule_timestamp(
        _event_date,
        explicit_start_time
      );

    period_end_at :=
      public.combine_bracket_schedule_timestamp(
        _event_date,
        explicit_end_time
      );

    IF period_end_at <= period_start_at
      OR period_start_at < day_bounds.day_start_at
      OR period_end_at > day_bounds.day_end_at
    THEN
      RETURN;
    END IF;

    schedule_period :=
      public.resolve_bracket_schedule_period_by_timestamp(
        _payload,
        _event_date,
        period_start_at
      );

    duration_minutes := GREATEST(
      1,
      ROUND(
        EXTRACT(
          EPOCH FROM (
            period_end_at - period_start_at
          )
        ) / 60.0
      )::integer
    );

    RETURN NEXT;
    RETURN;
  END IF;

  IF _legacy_period IS NULL THEN
    RETURN;
  END IF;

  IF NOT public.is_schedule_period_enabled_by_payload(
    _payload,
    _event_date,
    _legacy_period
  )
  THEN
    RETURN;
  END IF;

  SELECT
    _legacy_period,
    legacy_bounds.period_start_at,
    legacy_bounds.period_end_at,
    GREATEST(
      1,
      ROUND(
        EXTRACT(
          EPOCH FROM (
            legacy_bounds.period_end_at - legacy_bounds.period_start_at
          )
        ) / 60.0
      )::integer
    )
  INTO
    schedule_period,
    period_start_at,
    period_end_at,
    duration_minutes
  FROM public.resolve_bracket_schedule_period_bounds_from_payload(
    _payload,
    _event_date,
    _legacy_period
  ) AS legacy_bounds
  LIMIT 1;

  IF period_start_at IS NULL
    OR period_end_at IS NULL
    OR period_end_at <= period_start_at
  THEN
    RETURN;
  END IF;

  RETURN NEXT;
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_bracket_knockout_division_scope(_division team_division)
 RETURNS bracket_knockout_division_scope
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
    WHEN _division = 'DIVISAO_PRINCIPAL'::public.team_division THEN 'DIVISAO_PRINCIPAL'::public.bracket_knockout_division_scope
    WHEN _division = 'DIVISAO_ACESSO'::public.team_division THEN 'DIVISAO_ACESSO'::public.bracket_knockout_division_scope
    ELSE 'ALL'::public.bracket_knockout_division_scope
  END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_bracket_knockout_match_phase(_round_number integer, _competition_total_rounds integer, _is_third_place boolean)
 RETURNS bracket_knockout_priority_phase
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
BEGIN
  IF _is_third_place IS TRUE
    OR _round_number IS NULL
    OR _competition_total_rounds IS NULL
    OR _round_number < 1
    OR _competition_total_rounds < 1 THEN
    RETURN NULL;
  END IF;

  IF _round_number = _competition_total_rounds THEN
    RETURN 'FINAL'::public.bracket_knockout_priority_phase;
  END IF;

  IF _competition_total_rounds > 1
    AND _round_number = (_competition_total_rounds - 1) THEN
    RETURN 'SEMIFINAL'::public.bracket_knockout_priority_phase;
  END IF;

  RETURN NULL;
END;
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

CREATE OR REPLACE FUNCTION public.resolve_bracket_schedule_period_by_timestamp(_payload jsonb, _event_date date, _scheduled_start_at timestamp with time zone)
 RETURNS championship_schedule_period
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  day_bounds RECORD;
  break_start_at TIMESTAMPTZ;
  break_end_at TIMESTAMPTZ;
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
    RETURN 'MATUTINO'::public.championship_schedule_period;
  END IF;


  IF day_bounds.break_start_time IS NOT NULL
    AND day_bounds.break_end_time IS NOT NULL
    AND day_bounds.break_end_time > day_bounds.break_start_time
  THEN
    break_start_at :=
      public.combine_bracket_schedule_timestamp(
        _event_date,
        day_bounds.break_start_time
      );

    break_end_at :=
      public.combine_bracket_schedule_timestamp(
        _event_date,
        day_bounds.break_end_time
      );

    IF _scheduled_start_at < break_start_at THEN
      RETURN 'MATUTINO'::public.championship_schedule_period;
    END IF;

    IF _scheduled_start_at >= break_end_at THEN
      RETURN 'VESPERTINO'::public.championship_schedule_period;
    END IF;
  END IF;


  day_middle_at :=
    day_bounds.day_start_at
    + (
      (
        day_bounds.day_end_at
        - day_bounds.day_start_at
      ) / 2.0
    );


  IF _scheduled_start_at < day_middle_at THEN
    RETURN 'MATUTINO'::public.championship_schedule_period;
  END IF;


  RETURN 'VESPERTINO'::public.championship_schedule_period;
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

CREATE OR REPLACE FUNCTION public.resolve_championship_bracket_preview_payload_signature(_payload jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE
 SET search_path TO 'public'
AS $function$
  SELECT encode(
    extensions.digest(
      convert_to(
        COALESCE(_payload, '{}'::jsonb)::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
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

CREATE OR REPLACE FUNCTION public.resolve_championship_sport_duration_minutes(_championship_id uuid, _sport_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  resolved_duration INTEGER;
BEGIN
  SELECT championship_sports_table.default_match_duration_minutes
  INTO resolved_duration
  FROM public.championship_sports AS championship_sports_table
  WHERE championship_sports_table.championship_id = _championship_id
    AND championship_sports_table.sport_id = _sport_id
  LIMIT 1;

  RETURN GREATEST(1, COALESCE(resolved_duration, 35));
END;
$function$;

CREATE OR REPLACE FUNCTION public.resolve_current_user_tab_permission_level(_tab admin_panel_tab)
 RETURNS admin_panel_permission_level
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  current_user_id UUID;
  profile_permission_level public.admin_panel_permission_level;
BEGIN
  current_user_id := auth.uid();

  IF current_user_id IS NULL THEN
    RETURN 'NONE'::public.admin_panel_permission_level;
  END IF;

  SELECT admin_profile_permissions_table.access_level
  INTO profile_permission_level
  FROM public.admin_user_profiles AS admin_user_profiles_table
  JOIN public.admin_profile_permissions AS admin_profile_permissions_table
    ON admin_profile_permissions_table.profile_id = admin_user_profiles_table.profile_id
   AND admin_profile_permissions_table.admin_tab = _tab
  WHERE admin_user_profiles_table.user_id = current_user_id
  LIMIT 1;

  RETURN COALESCE(profile_permission_level, 'NONE'::public.admin_panel_permission_level);
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_championship_bracket_preview_job(_championship_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
AS $function$
DECLARE season INTEGER; payload_hash TEXT; dependency_hash TEXT; existing_job RECORD; new_job_id UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT public.has_admin_tab_access('matches'::public.admin_panel_tab,true) THEN RAISE EXCEPTION 'Usuário sem permissão para calcular a programação.'; END IF;
  SELECT current_season_year INTO season FROM public.championships WHERE id=_championship_id AND status='UPCOMING'::public.championship_status;
  IF season IS NULL THEN RAISE EXCEPTION 'Campeonato inválido ou fora do status Configurando campeonato.'; END IF;
  payload_hash:=public.resolve_championship_bracket_preview_payload_signature(COALESCE(_payload,'{}'::jsonb));
  dependency_hash:=championship_bracket_preview_private.resolve_dependency_signature(_championship_id,COALESCE(_payload,'{}'::jsonb));
  SELECT * INTO existing_job FROM championship_bracket_preview_private.jobs WHERE championship_id=_championship_id AND season_year=season AND requested_by=auth.uid() AND payload_signature=payload_hash AND dependency_signature=dependency_hash AND algorithm_version='async-exact-v8' AND expires_at>now() AND status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING','COMPLETED') ORDER BY created_at DESC LIMIT 1;
  IF existing_job.id IS NOT NULL THEN RETURN public.get_championship_bracket_preview_job_status(existing_job.id); END IF;
  IF EXISTS(SELECT 1 FROM championship_bracket_preview_private.jobs WHERE championship_id=_championship_id AND season_year=season AND requested_by<>auth.uid() AND status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING')) THEN RAISE EXCEPTION 'Já existe uma programação exata em andamento para este campeonato.'; END IF;
  UPDATE championship_bracket_preview_private.jobs SET status='CANCELLED',stage='Substituída por nova configuração',expires_at=now()+interval '24 hours',updated_at=now() WHERE championship_id=_championship_id AND season_year=season AND status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING');
  INSERT INTO championship_bracket_preview_private.jobs(championship_id,season_year,requested_by,payload,payload_signature,dependency_signature,algorithm_version) VALUES(_championship_id,season,auth.uid(),COALESCE(_payload,'{}'::jsonb),payload_hash,dependency_hash,'async-exact-v8') RETURNING id INTO new_job_id;
  PERFORM championship_bracket_preview_private.enqueue(new_job_id,0);
  RETURN public.get_championship_bracket_preview_job_status(new_job_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.start_championship_bracket_preview_job_v7(_championship_id uuid, _payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'championship_bracket_preview_private'
 SET statement_timeout TO '15s'
AS $function$
DECLARE
  season INTEGER;
  payload_hash TEXT;
  dependency_hash TEXT;
  existing_job RECORD;
  new_id UUID;
BEGIN
  IF auth.uid() IS NULL
    OR NOT public.has_admin_tab_access('matches'::public.admin_panel_tab, true)
  THEN
    RAISE EXCEPTION 'Usuário sem permissão para calcular a programação.';
  END IF;

  SELECT championships_table.current_season_year
  INTO season
  FROM public.championships AS championships_table
  WHERE championships_table.id = _championship_id
    AND championships_table.status = 'UPCOMING'::public.championship_status;

  IF season IS NULL THEN
    RAISE EXCEPTION 'Campeonato inválido ou fora do status Configurando campeonato.';
  END IF;

  payload_hash := public.resolve_championship_bracket_preview_payload_signature(
    COALESCE(_payload, '{}'::JSONB)
  );
  dependency_hash := championship_bracket_preview_private.resolve_dependency_signature(
    _championship_id,
    COALESCE(_payload, '{}'::JSONB)
  );

  SELECT *
  INTO existing_job
  FROM championship_bracket_preview_private.jobs
  WHERE championship_id = _championship_id
    AND season_year = season
    AND requested_by = auth.uid()
    AND payload_signature = payload_hash
    AND dependency_signature = dependency_hash
    AND algorithm_version = 'async-exact-v7'
    AND expires_at > now()
    AND status IN ('QUEUED', 'INITIALIZING', 'SCHEDULING', 'FINALIZING', 'COMPLETED')
  ORDER BY created_at DESC
  LIMIT 1;

  IF existing_job.id IS NOT NULL THEN
    RETURN public.get_championship_bracket_preview_job_status(existing_job.id);
  END IF;

  IF EXISTS (
    SELECT 1
    FROM championship_bracket_preview_private.jobs
    WHERE championship_id = _championship_id
      AND season_year = season
      AND requested_by <> auth.uid()
      AND status IN ('QUEUED', 'INITIALIZING', 'SCHEDULING', 'FINALIZING')
  ) THEN
    RAISE EXCEPTION 'Já existe uma programação exata em andamento para este campeonato.';
  END IF;

  UPDATE championship_bracket_preview_private.jobs
  SET
    status = 'CANCELLED',
    stage = 'Substituída por nova configuração',
    expires_at = now() + interval '24 hours',
    updated_at = now()
  WHERE championship_id = _championship_id
    AND season_year = season
    AND status IN ('QUEUED', 'INITIALIZING', 'SCHEDULING', 'FINALIZING');

  INSERT INTO championship_bracket_preview_private.jobs (
    championship_id,
    season_year,
    requested_by,
    payload,
    payload_signature,
    dependency_signature,
    algorithm_version
  ) VALUES (
    _championship_id,
    season,
    auth.uid(),
    COALESCE(_payload, '{}'::JSONB),
    payload_hash,
    dependency_hash,
    'async-exact-v7'
  )
  RETURNING id INTO new_id;

  PERFORM championship_bracket_preview_private.enqueue(new_id, 0);

  RETURN public.get_championship_bracket_preview_job_status(new_id);
END;
$function$;

CREATE OR REPLACE FUNCTION public.sync_championship_bracket_court_sport_preferences(_bracket_edition_id uuid, _payload jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  edition_record RECORD;
BEGIN
  SELECT
    editions_table.id
  INTO edition_record
  FROM public.championship_bracket_editions
    AS editions_table
  WHERE editions_table.id =
    _bracket_edition_id
  LIMIT 1;

  IF edition_record.id IS NULL THEN
    RAISE EXCEPTION
      'Edição de chaveamento inválida para sincronizar a estrutura da agenda.';
  END IF;

  INSERT INTO public.championship_bracket_days (
    bracket_edition_id,
    event_date,
    start_time,
    end_time,
    break_start_time,
    break_end_time
  )
  SELECT
    _bracket_edition_id,
    (day_item.value ->> 'date')::date,
    (day_item.value ->> 'start_time')::time,
    (day_item.value ->> 'end_time')::time,
    NULLIF(
      day_item.value ->> 'break_start_time',
      ''
    )::time,
    NULLIF(
      day_item.value ->> 'break_end_time',
      ''
    )::time
  FROM jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(
        _payload -> 'schedule_days'
      ) = 'array'
        THEN _payload -> 'schedule_days'
      ELSE '[]'::jsonb
    END
  ) AS day_item(value)
  ON CONFLICT ON CONSTRAINT
    championship_bracket_days_upsert_unique
  DO UPDATE SET
    start_time =
      EXCLUDED.start_time,
    end_time =
      EXCLUDED.end_time,
    break_start_time =
      EXCLUDED.break_start_time,
    break_end_time =
      EXCLUDED.break_end_time;

  INSERT INTO public.championship_bracket_locations (
    bracket_day_id,
    name,
    position,
    location_group_id
  )
  SELECT
    days_table.id,
    location_item.value ->> 'name',
    COALESCE(
      (
        location_item.value ->> 'position'
      )::integer,
      location_item.ordinality::integer
    ),
    (
      location_item.value ->> 'location_key'
    )::uuid
  FROM jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(
        _payload -> 'schedule_days'
      ) = 'array'
        THEN _payload -> 'schedule_days'
      ELSE '[]'::jsonb
    END
  ) AS day_item(value)
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(
        day_item.value -> 'locations'
      ) = 'array'
        THEN day_item.value -> 'locations'
      ELSE '[]'::jsonb
    END
  ) WITH ORDINALITY
    AS location_item(
      value,
      ordinality
    )
  JOIN public.championship_bracket_days
    AS days_table
    ON days_table.bracket_edition_id =
      _bracket_edition_id
    AND days_table.event_date =
      (
        day_item.value ->> 'date'
      )::date
  ON CONFLICT ON CONSTRAINT
    championship_bracket_locations_upsert_unique
  DO UPDATE SET
    position =
      EXCLUDED.position,
    location_group_id =
      EXCLUDED.location_group_id;

  INSERT INTO public.championship_bracket_courts (
    bracket_location_id,
    name,
    position,
    court_group_id
  )
  SELECT
    locations_table.id,
    court_item.value ->> 'name',
    COALESCE(
      (
        court_item.value ->> 'position'
      )::integer,
      court_item.ordinality::integer
    ),
    (
      court_item.value ->> 'court_key'
    )::uuid
  FROM jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(
        _payload -> 'schedule_days'
      ) = 'array'
        THEN _payload -> 'schedule_days'
      ELSE '[]'::jsonb
    END
  ) AS day_item(value)
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(
        day_item.value -> 'locations'
      ) = 'array'
        THEN day_item.value -> 'locations'
      ELSE '[]'::jsonb
    END
  ) AS location_item(value)
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(
        location_item.value -> 'courts'
      ) = 'array'
        THEN location_item.value -> 'courts'
      ELSE '[]'::jsonb
    END
  ) WITH ORDINALITY
    AS court_item(
      value,
      ordinality
    )
  JOIN public.championship_bracket_days
    AS days_table
    ON days_table.bracket_edition_id =
      _bracket_edition_id
    AND days_table.event_date =
      (
        day_item.value ->> 'date'
      )::date
  JOIN public.championship_bracket_locations
    AS locations_table
    ON locations_table.bracket_day_id =
      days_table.id
    AND locations_table.location_group_id =
      (
        location_item.value
          ->> 'location_key'
      )::uuid
  ON CONFLICT ON CONSTRAINT
    championship_bracket_courts_upsert_unique
  DO UPDATE SET
    position =
      EXCLUDED.position,
    court_group_id =
      EXCLUDED.court_group_id;

  PERFORM public.sync_championship_bracket_court_sport_preferences_before_structure_fix_v8(
    _bracket_edition_id,
    _payload
  );
END;
$function$;

SET check_function_bodies = on;
