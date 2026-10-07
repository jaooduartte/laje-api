-- LAJE-126: snapshot do motor exato v8 proveniente do Supabase legado.
-- Somente schema/estado privado; filas e cron são substituídos por SQS/EventBridge.
-- Constraints são aplicadas em ordem de dependência: PK/UNIQUE, CHECK e somente depois FKs.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
CREATE SCHEMA IF NOT EXISTS championship_bracket_preview_private;

CREATE SEQUENCE IF NOT EXISTS championship_bracket_preview_private.job_events_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 NO CYCLE;
CREATE SEQUENCE IF NOT EXISTS championship_bracket_preview_private.manifest_daily_interday_repairs_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 NO CYCLE;
CREATE SEQUENCE IF NOT EXISTS championship_bracket_preview_private.relocation_attempt_metrics_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 NO CYCLE;
CREATE SEQUENCE IF NOT EXISTS championship_bracket_preview_private.slots_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 NO CYCLE;
CREATE SEQUENCE IF NOT EXISTS championship_bracket_preview_private.stage_metrics_id_seq AS bigint START WITH 1 INCREMENT BY 1 MINVALUE 1 MAXVALUE 9223372036854775807 CACHE 1 NO CYCLE;

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.assignments (
  job_id uuid NOT NULL,
  match_id uuid NOT NULL,
  slot_id bigint NOT NULL,
  match_number integer,
  assigned_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.compaction_gaps (
  job_id uuid NOT NULL,
  gap_key text NOT NULL,
  status text NOT NULL,
  timeout_count integer DEFAULT 0 NOT NULL,
  attempted_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.competitions (
  id uuid NOT NULL,
  job_id uuid NOT NULL,
  sport_id uuid NOT NULL,
  sport_name text NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  groups_count integer NOT NULL,
  qualifiers_per_group integer NOT NULL,
  third_place_mode bracket_third_place_mode NOT NULL,
  best_second boolean NOT NULL,
  pairing_mode text NOT NULL,
  competition_key text NOT NULL,
  "position" integer NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.group_teams (
  job_id uuid NOT NULL,
  group_id uuid NOT NULL,
  team_id uuid NOT NULL,
  "position" integer NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.groups (
  id uuid NOT NULL,
  job_id uuid NOT NULL,
  competition_id uuid NOT NULL,
  group_number integer NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.job_events (
  id bigint NOT NULL,
  job_id uuid NOT NULL,
  event_type text NOT NULL,
  group_match_id uuid,
  knockout_match_id uuid,
  details jsonb DEFAULT '{}'::jsonb NOT NULL,
  occurred_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
  stage text
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.jobs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  requested_by uuid NOT NULL,
  payload jsonb NOT NULL,
  payload_signature text NOT NULL,
  dependency_signature text NOT NULL,
  algorithm_version text DEFAULT 'async-exact-v8'::text NOT NULL,
  status text DEFAULT 'QUEUED'::text NOT NULL,
  stage text DEFAULT 'QUEUED'::text NOT NULL,
  current_processing_date date,
  progress_percentage numeric(5,2) DEFAULT 0 NOT NULL,
  processed_slots integer DEFAULT 0 NOT NULL,
  total_slots integer DEFAULT 0 NOT NULL,
  attempt_count integer DEFAULT 0 NOT NULL,
  heartbeat_at timestamp with time zone,
  error_message text,
  summary jsonb,
  diagnostics jsonb DEFAULT '[]'::jsonb NOT NULL,
  generation_signature text,
  result_edition_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  started_at timestamp with time zone,
  completed_at timestamp with time zone,
  consumed_at timestamp with time zone,
  expires_at timestamp with time zone DEFAULT (now() + '24:00:00'::interval) NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.knockout_matches (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  job_id uuid NOT NULL,
  competition_id uuid NOT NULL,
  phase text NOT NULL,
  round_number integer NOT NULL,
  slot_number integer NOT NULL,
  logical_key text NOT NULL,
  home_source_type text NOT NULL,
  home_source_reference text NOT NULL,
  away_source_type text NOT NULL,
  away_source_reference text NOT NULL,
  predecessor_match_ids uuid[] DEFAULT ARRAY[]::uuid[] NOT NULL,
  scheduled_slot_id bigint,
  scheduled_date date,
  location_key uuid,
  location_name text,
  court_key uuid,
  court_name text,
  start_at timestamp with time zone,
  end_at timestamp with time zone,
  duration_minutes integer NOT NULL,
  projected boolean DEFAULT true NOT NULL,
  manual_final boolean DEFAULT false NOT NULL,
  is_bye boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_daily_interday_repairs (
  id bigint DEFAULT nextval('championship_bracket_preview_private.manifest_daily_interday_repairs_id_seq'::regclass) NOT NULL,
  job_id uuid NOT NULL,
  closed_date date NOT NULL,
  final_date date NOT NULL,
  inbound_match_id uuid NOT NULL,
  outbound_match_id uuid NOT NULL,
  earlier_slot_id bigint NOT NULL,
  final_candidate_slot_id bigint,
  success boolean NOT NULL,
  failure_reason text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_daily_probe_frames (
  job_id uuid NOT NULL,
  event_date date NOT NULL,
  rest_gap integer NOT NULL,
  depth integer NOT NULL,
  slot_id bigint NOT NULL,
  chosen_match_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_daily_probe_tried_matches (
  job_id uuid NOT NULL,
  event_date date NOT NULL,
  rest_gap integer NOT NULL,
  depth integer NOT NULL,
  slot_id bigint NOT NULL,
  match_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_daily_solver_frames (
  job_id uuid NOT NULL,
  event_date date NOT NULL,
  rest_gap integer NOT NULL,
  depth integer NOT NULL,
  slot_id bigint NOT NULL,
  chosen_match_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_daily_solver_state (
  job_id uuid NOT NULL,
  processing_date date,
  rest_gap integer DEFAULT 3 NOT NULL,
  phase text DEFAULT 'SEARCHING_DAY'::text NOT NULL,
  completed_days integer DEFAULT 0 NOT NULL,
  decisions_count bigint DEFAULT 0 NOT NULL,
  total_backtracks bigint DEFAULT 0 NOT NULL,
  day_backtracks bigint DEFAULT 0 NOT NULL,
  day_started_at timestamp with time zone DEFAULT now() NOT NULL,
  last_forward_diagnostics jsonb DEFAULT '[]'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  interday_repairs_count integer DEFAULT 0 NOT NULL,
  last_interday_repair jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_daily_solver_tried_matches (
  job_id uuid NOT NULL,
  event_date date NOT NULL,
  rest_gap integer NOT NULL,
  depth integer NOT NULL,
  slot_id bigint NOT NULL,
  match_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_solver_candidates (
  job_id uuid NOT NULL,
  match_id uuid NOT NULL,
  slot_id bigint NOT NULL,
  base_rank integer NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_solver_decisions (
  job_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  rest_gap integer NOT NULL,
  depth integer NOT NULL,
  match_id uuid NOT NULL,
  slot_id bigint NOT NULL,
  candidate_rank integer NOT NULL,
  pressure bigint DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_solver_frames (
  job_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  rest_gap integer NOT NULL,
  depth integer NOT NULL,
  match_id uuid NOT NULL,
  chosen_slot_id bigint,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_solver_state (
  job_id uuid NOT NULL,
  current_naipe match_naipe,
  rest_gap integer DEFAULT 3 NOT NULL,
  decisions_count bigint DEFAULT 0 NOT NULL,
  backtracks_count bigint DEFAULT 0 NOT NULL,
  phase text DEFAULT 'SEARCHING'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  phase_started_at timestamp with time zone DEFAULT now() NOT NULL,
  phase_backtracks bigint DEFAULT 0 NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.manifest_solver_tried_slots (
  job_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  rest_gap integer NOT NULL,
  depth integer NOT NULL,
  match_id uuid NOT NULL,
  slot_id bigint NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.matches (
  id uuid NOT NULL,
  job_id uuid NOT NULL,
  competition_id uuid NOT NULL,
  group_id uuid NOT NULL,
  logical_key text NOT NULL,
  round_number integer NOT NULL,
  slot_number integer NOT NULL,
  home_team_id uuid NOT NULL,
  away_team_id uuid NOT NULL,
  priority_weight integer DEFAULT 0 NOT NULL,
  assigned boolean DEFAULT false NOT NULL,
  relocation_attempt_count integer DEFAULT 0 NOT NULL,
  relocation_candidate_cursor bigint DEFAULT 0 NOT NULL,
  relocation_search_exhausted boolean DEFAULT false NOT NULL,
  relocation_search_phase text DEFAULT 'STRICT'::text NOT NULL,
  relaxed_rest_gap_applied boolean DEFAULT false NOT NULL,
  applied_rest_gap integer DEFAULT 3 NOT NULL,
  relocation_search_tier text DEFAULT 'FAST'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.relocation_attempt_metrics (
  id bigint NOT NULL,
  job_id uuid NOT NULL,
  match_id uuid,
  phase text NOT NULL,
  rest_gap integer NOT NULL,
  search_tier text NOT NULL,
  candidate_rank integer,
  candidate_slot_id bigint,
  max_depth integer NOT NULL,
  candidate_limit integer NOT NULL,
  relocation_limit integer NOT NULL,
  result_status text NOT NULL,
  timeout_count integer DEFAULT 0 NOT NULL,
  relocations_used integer DEFAULT 0 NOT NULL,
  branches_examined integer DEFAULT 0 NOT NULL,
  duration_ms integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.relocation_candidate_states (
  job_id uuid NOT NULL,
  match_id uuid NOT NULL,
  phase text NOT NULL,
  slot_id bigint NOT NULL,
  status text NOT NULL,
  attempt_count integer DEFAULT 0 NOT NULL,
  timeout_count integer DEFAULT 0 NOT NULL,
  last_attempt_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.relocation_candidate_tier_states (
  job_id uuid NOT NULL,
  match_id uuid NOT NULL,
  phase text NOT NULL,
  search_tier text NOT NULL,
  slot_id bigint NOT NULL,
  status text NOT NULL,
  attempt_count integer DEFAULT 0 NOT NULL,
  timeout_count integer DEFAULT 0 NOT NULL,
  last_attempt_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.relocation_ranked_candidate_cache (
  job_id uuid NOT NULL,
  match_id uuid NOT NULL,
  phase text NOT NULL,
  slot_id bigint NOT NULL,
  candidate_rank bigint NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.relocation_ranked_candidate_cache_runs (
  job_id uuid NOT NULL,
  match_id uuid NOT NULL,
  phase text NOT NULL,
  generated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.slots (
  id bigint DEFAULT nextval('championship_bracket_preview_private.slots_id_seq'::regclass) NOT NULL,
  job_id uuid NOT NULL,
  event_date date NOT NULL,
  location_key uuid NOT NULL,
  location_name text NOT NULL,
  location_position integer NOT NULL,
  court_key uuid NOT NULL,
  court_name text NOT NULL,
  court_position integer NOT NULL,
  sport_id uuid NOT NULL,
  start_at timestamp with time zone NOT NULL,
  end_at timestamp with time zone NOT NULL,
  sequence_index integer NOT NULL,
  preferred_sport boolean DEFAULT false NOT NULL,
  preferred_naipe match_naipe,
  preferred_division team_division,
  sequence_mode text DEFAULT 'FLEXIBLE'::text NOT NULL,
  cursor_position bigint NOT NULL,
  processed boolean DEFAULT false NOT NULL,
  structural_slot_key text,
  structural_competition_id uuid,
  structural_competition_key text,
  structural_phase text,
  structural_phase_slot_number integer,
  structural_match_kind text,
  structural_manual_final boolean DEFAULT false NOT NULL
);

CREATE TABLE IF NOT EXISTS championship_bracket_preview_private.stage_metrics (
  id bigint DEFAULT nextval('championship_bracket_preview_private.stage_metrics_id_seq'::regclass) NOT NULL,
  job_id uuid NOT NULL,
  stage text NOT NULL,
  batch_number integer NOT NULL,
  duration_ms integer NOT NULL,
  processed_slots integer NOT NULL,
  candidates_examined integer NOT NULL,
  produced_rows integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE championship_bracket_preview_private.assignments ADD CONSTRAINT assignments_pkey PRIMARY KEY (job_id, match_id);
ALTER TABLE championship_bracket_preview_private.compaction_gaps ADD CONSTRAINT compaction_gaps_pkey PRIMARY KEY (job_id, gap_key);
ALTER TABLE championship_bracket_preview_private.competitions ADD CONSTRAINT competitions_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.group_teams ADD CONSTRAINT group_teams_pkey PRIMARY KEY (job_id, group_id, team_id);
ALTER TABLE championship_bracket_preview_private.groups ADD CONSTRAINT groups_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.job_events ADD CONSTRAINT job_events_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.jobs ADD CONSTRAINT jobs_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.knockout_matches ADD CONSTRAINT knockout_matches_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.manifest_daily_interday_repairs ADD CONSTRAINT manifest_daily_interday_repairs_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_frames ADD CONSTRAINT manifest_daily_probe_frames_pkey PRIMARY KEY (job_id, event_date, rest_gap, depth);
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_tried_matches ADD CONSTRAINT manifest_daily_probe_tried_matches_pkey PRIMARY KEY (job_id, event_date, rest_gap, depth, match_id);
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_frames ADD CONSTRAINT manifest_daily_solver_frames_pkey PRIMARY KEY (job_id, event_date, rest_gap, depth);
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_state ADD CONSTRAINT manifest_daily_solver_state_pkey PRIMARY KEY (job_id);
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_tried_matches ADD CONSTRAINT manifest_daily_solver_tried_matches_pkey PRIMARY KEY (job_id, event_date, rest_gap, depth, match_id);
ALTER TABLE championship_bracket_preview_private.manifest_solver_candidates ADD CONSTRAINT manifest_solver_candidates_pkey PRIMARY KEY (job_id, match_id, slot_id);
ALTER TABLE championship_bracket_preview_private.manifest_solver_decisions ADD CONSTRAINT manifest_solver_decisions_pkey PRIMARY KEY (job_id, naipe, depth);
ALTER TABLE championship_bracket_preview_private.manifest_solver_frames ADD CONSTRAINT manifest_solver_frames_pkey PRIMARY KEY (job_id, naipe, rest_gap, depth);
ALTER TABLE championship_bracket_preview_private.manifest_solver_state ADD CONSTRAINT manifest_solver_state_pkey PRIMARY KEY (job_id);
ALTER TABLE championship_bracket_preview_private.manifest_solver_tried_slots ADD CONSTRAINT manifest_solver_tried_slots_pkey PRIMARY KEY (job_id, naipe, rest_gap, depth, slot_id);
ALTER TABLE championship_bracket_preview_private.matches ADD CONSTRAINT matches_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.relocation_attempt_metrics ADD CONSTRAINT relocation_attempt_metrics_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.relocation_candidate_states ADD CONSTRAINT relocation_candidate_states_pkey PRIMARY KEY (job_id, match_id, phase, slot_id);
ALTER TABLE championship_bracket_preview_private.relocation_candidate_tier_states ADD CONSTRAINT relocation_candidate_tier_states_pkey PRIMARY KEY (job_id, match_id, phase, search_tier, slot_id);
ALTER TABLE championship_bracket_preview_private.relocation_ranked_candidate_cache ADD CONSTRAINT relocation_ranked_candidate_cache_pkey PRIMARY KEY (job_id, match_id, phase, slot_id);
ALTER TABLE championship_bracket_preview_private.relocation_ranked_candidate_cache_runs ADD CONSTRAINT relocation_ranked_candidate_cache_runs_pkey PRIMARY KEY (job_id, match_id, phase);
ALTER TABLE championship_bracket_preview_private.slots ADD CONSTRAINT slots_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.stage_metrics ADD CONSTRAINT stage_metrics_pkey PRIMARY KEY (id);
ALTER TABLE championship_bracket_preview_private.assignments ADD CONSTRAINT assignments_job_id_slot_id_key UNIQUE (job_id, slot_id);
ALTER TABLE championship_bracket_preview_private.competitions ADD CONSTRAINT competitions_job_id_competition_key_key UNIQUE (job_id, competition_key);
ALTER TABLE championship_bracket_preview_private.group_teams ADD CONSTRAINT group_teams_job_id_group_id_position_key UNIQUE (job_id, group_id, "position");
ALTER TABLE championship_bracket_preview_private.groups ADD CONSTRAINT groups_job_id_competition_id_group_number_key UNIQUE (job_id, competition_id, group_number);
ALTER TABLE championship_bracket_preview_private.job_events ADD CONSTRAINT job_events_job_id_event_type_group_match_id_knockout_match__key UNIQUE NULLS NOT DISTINCT (job_id, event_type, group_match_id, knockout_match_id);
ALTER TABLE championship_bracket_preview_private.knockout_matches ADD CONSTRAINT knockout_matches_job_id_competition_id_round_number_slot_nu_key UNIQUE (job_id, competition_id, round_number, slot_number, phase);
ALTER TABLE championship_bracket_preview_private.knockout_matches ADD CONSTRAINT knockout_matches_job_id_logical_key_key UNIQUE (job_id, logical_key);
ALTER TABLE championship_bracket_preview_private.manifest_daily_interday_repairs ADD CONSTRAINT manifest_daily_interday_repai_job_id_final_date_inbound_mat_key UNIQUE (job_id, final_date, inbound_match_id, outbound_match_id, earlier_slot_id);
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_frames ADD CONSTRAINT manifest_daily_probe_frames_job_id_event_date_rest_gap_slot_key UNIQUE (job_id, event_date, rest_gap, slot_id);
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_frames ADD CONSTRAINT manifest_daily_solver_frames_job_id_event_date_rest_gap_slo_key UNIQUE (job_id, event_date, rest_gap, slot_id);
ALTER TABLE championship_bracket_preview_private.manifest_solver_decisions ADD CONSTRAINT manifest_solver_decisions_job_id_match_id_key UNIQUE (job_id, match_id);
ALTER TABLE championship_bracket_preview_private.manifest_solver_decisions ADD CONSTRAINT manifest_solver_decisions_job_id_slot_id_key UNIQUE (job_id, slot_id);
ALTER TABLE championship_bracket_preview_private.manifest_solver_frames ADD CONSTRAINT manifest_solver_frames_job_id_match_id_key UNIQUE (job_id, match_id);
ALTER TABLE championship_bracket_preview_private.matches ADD CONSTRAINT matches_job_id_logical_key_key UNIQUE (job_id, logical_key);
ALTER TABLE championship_bracket_preview_private.relocation_ranked_candidate_cache ADD CONSTRAINT relocation_ranked_candidate_c_job_id_match_id_phase_candida_key UNIQUE (job_id, match_id, phase, candidate_rank);
ALTER TABLE championship_bracket_preview_private.slots ADD CONSTRAINT slots_job_id_event_date_court_key_sport_id_start_at_key UNIQUE (job_id, event_date, court_key, sport_id, start_at);
ALTER TABLE championship_bracket_preview_private.job_events ADD CONSTRAINT job_events_event_type_check CHECK (event_type = ANY (ARRAY['STAGE_CHANGED'::text, 'GROUP_MATCH_SCHEDULED'::text, 'KNOCKOUT_MATCH_SCHEDULED'::text, 'PENDING_MATCH_COUNT_DECREASED'::text]));
ALTER TABLE championship_bracket_preview_private.jobs ADD CONSTRAINT jobs_status_check CHECK (status = ANY (ARRAY['QUEUED'::text, 'INITIALIZING'::text, 'SCHEDULING'::text, 'FINALIZING'::text, 'COMPLETED'::text, 'FAILED'::text, 'CANCELLED'::text, 'CONSUMED'::text]));
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_frames ADD CONSTRAINT manifest_daily_probe_frames_rest_gap_check CHECK (rest_gap = ANY (ARRAY[2, 3]));
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_tried_matches ADD CONSTRAINT manifest_daily_probe_tried_matches_rest_gap_check CHECK (rest_gap = ANY (ARRAY[2, 3]));
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_frames ADD CONSTRAINT manifest_daily_solver_frames_rest_gap_check CHECK (rest_gap = ANY (ARRAY[2, 3]));
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_state ADD CONSTRAINT manifest_daily_solver_state_rest_gap_check CHECK (rest_gap = ANY (ARRAY[2, 3]));
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_tried_matches ADD CONSTRAINT manifest_daily_solver_tried_matches_rest_gap_check CHECK (rest_gap = ANY (ARRAY[2, 3]));
ALTER TABLE championship_bracket_preview_private.manifest_solver_decisions ADD CONSTRAINT manifest_solver_decisions_rest_gap_check CHECK (rest_gap = ANY (ARRAY[2, 3]));
ALTER TABLE championship_bracket_preview_private.manifest_solver_frames ADD CONSTRAINT manifest_solver_frames_rest_gap_check CHECK (rest_gap = ANY (ARRAY[2, 3]));
ALTER TABLE championship_bracket_preview_private.manifest_solver_state ADD CONSTRAINT manifest_solver_state_rest_gap_check CHECK (rest_gap = ANY (ARRAY[2, 3]));
ALTER TABLE championship_bracket_preview_private.manifest_solver_tried_slots ADD CONSTRAINT manifest_solver_tried_slots_rest_gap_check CHECK (rest_gap = ANY (ARRAY[2, 3]));
ALTER TABLE championship_bracket_preview_private.assignments ADD CONSTRAINT assignments_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.assignments ADD CONSTRAINT assignments_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.assignments ADD CONSTRAINT assignments_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.compaction_gaps ADD CONSTRAINT compaction_gaps_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.competitions ADD CONSTRAINT competitions_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.competitions ADD CONSTRAINT competitions_sport_id_fkey FOREIGN KEY (sport_id) REFERENCES sports(id);
ALTER TABLE championship_bracket_preview_private.group_teams ADD CONSTRAINT group_teams_group_id_fkey FOREIGN KEY (group_id) REFERENCES championship_bracket_preview_private.groups(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.group_teams ADD CONSTRAINT group_teams_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.group_teams ADD CONSTRAINT group_teams_team_id_fkey FOREIGN KEY (team_id) REFERENCES teams(id);
ALTER TABLE championship_bracket_preview_private.groups ADD CONSTRAINT groups_competition_id_fkey FOREIGN KEY (competition_id) REFERENCES championship_bracket_preview_private.competitions(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.groups ADD CONSTRAINT groups_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.job_events ADD CONSTRAINT job_events_group_match_id_fkey FOREIGN KEY (group_match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE SET NULL;
ALTER TABLE championship_bracket_preview_private.job_events ADD CONSTRAINT job_events_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.job_events ADD CONSTRAINT job_events_knockout_match_id_fkey FOREIGN KEY (knockout_match_id) REFERENCES championship_bracket_preview_private.knockout_matches(id) ON DELETE SET NULL;
ALTER TABLE championship_bracket_preview_private.jobs ADD CONSTRAINT jobs_championship_id_fkey FOREIGN KEY (championship_id) REFERENCES championships(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.knockout_matches ADD CONSTRAINT knockout_matches_competition_id_fkey FOREIGN KEY (competition_id) REFERENCES championship_bracket_preview_private.competitions(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.knockout_matches ADD CONSTRAINT knockout_matches_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.knockout_matches ADD CONSTRAINT knockout_matches_scheduled_slot_id_fkey FOREIGN KEY (scheduled_slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE SET NULL;
ALTER TABLE championship_bracket_preview_private.manifest_daily_interday_repairs ADD CONSTRAINT manifest_daily_interday_repairs_earlier_slot_id_fkey FOREIGN KEY (earlier_slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_interday_repairs ADD CONSTRAINT manifest_daily_interday_repairs_final_candidate_slot_id_fkey FOREIGN KEY (final_candidate_slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE SET NULL;
ALTER TABLE championship_bracket_preview_private.manifest_daily_interday_repairs ADD CONSTRAINT manifest_daily_interday_repairs_inbound_match_id_fkey FOREIGN KEY (inbound_match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_interday_repairs ADD CONSTRAINT manifest_daily_interday_repairs_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_interday_repairs ADD CONSTRAINT manifest_daily_interday_repairs_outbound_match_id_fkey FOREIGN KEY (outbound_match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_frames ADD CONSTRAINT manifest_daily_probe_frames_chosen_match_id_fkey FOREIGN KEY (chosen_match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE SET NULL;
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_frames ADD CONSTRAINT manifest_daily_probe_frames_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_frames ADD CONSTRAINT manifest_daily_probe_frames_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_tried_matches ADD CONSTRAINT manifest_daily_probe_tried_matches_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_tried_matches ADD CONSTRAINT manifest_daily_probe_tried_matches_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_probe_tried_matches ADD CONSTRAINT manifest_daily_probe_tried_matches_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_frames ADD CONSTRAINT manifest_daily_solver_frames_chosen_match_id_fkey FOREIGN KEY (chosen_match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE SET NULL;
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_frames ADD CONSTRAINT manifest_daily_solver_frames_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_frames ADD CONSTRAINT manifest_daily_solver_frames_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_state ADD CONSTRAINT manifest_daily_solver_state_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_tried_matches ADD CONSTRAINT manifest_daily_solver_tried_matches_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_tried_matches ADD CONSTRAINT manifest_daily_solver_tried_matches_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_daily_solver_tried_matches ADD CONSTRAINT manifest_daily_solver_tried_matches_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_candidates ADD CONSTRAINT manifest_solver_candidates_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_candidates ADD CONSTRAINT manifest_solver_candidates_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_candidates ADD CONSTRAINT manifest_solver_candidates_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_decisions ADD CONSTRAINT manifest_solver_decisions_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_decisions ADD CONSTRAINT manifest_solver_decisions_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_decisions ADD CONSTRAINT manifest_solver_decisions_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_frames ADD CONSTRAINT manifest_solver_frames_chosen_slot_id_fkey FOREIGN KEY (chosen_slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE SET NULL;
ALTER TABLE championship_bracket_preview_private.manifest_solver_frames ADD CONSTRAINT manifest_solver_frames_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_frames ADD CONSTRAINT manifest_solver_frames_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_state ADD CONSTRAINT manifest_solver_state_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_tried_slots ADD CONSTRAINT manifest_solver_tried_slots_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_tried_slots ADD CONSTRAINT manifest_solver_tried_slots_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.manifest_solver_tried_slots ADD CONSTRAINT manifest_solver_tried_slots_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.matches ADD CONSTRAINT matches_away_team_id_fkey FOREIGN KEY (away_team_id) REFERENCES teams(id);
ALTER TABLE championship_bracket_preview_private.matches ADD CONSTRAINT matches_competition_id_fkey FOREIGN KEY (competition_id) REFERENCES championship_bracket_preview_private.competitions(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.matches ADD CONSTRAINT matches_group_id_fkey FOREIGN KEY (group_id) REFERENCES championship_bracket_preview_private.groups(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.matches ADD CONSTRAINT matches_home_team_id_fkey FOREIGN KEY (home_team_id) REFERENCES teams(id);
ALTER TABLE championship_bracket_preview_private.matches ADD CONSTRAINT matches_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_attempt_metrics ADD CONSTRAINT relocation_attempt_metrics_candidate_slot_id_fkey FOREIGN KEY (candidate_slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE SET NULL;
ALTER TABLE championship_bracket_preview_private.relocation_attempt_metrics ADD CONSTRAINT relocation_attempt_metrics_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_attempt_metrics ADD CONSTRAINT relocation_attempt_metrics_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE SET NULL;
ALTER TABLE championship_bracket_preview_private.relocation_candidate_states ADD CONSTRAINT relocation_candidate_states_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_candidate_states ADD CONSTRAINT relocation_candidate_states_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_candidate_states ADD CONSTRAINT relocation_candidate_states_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_candidate_tier_states ADD CONSTRAINT relocation_candidate_tier_states_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_candidate_tier_states ADD CONSTRAINT relocation_candidate_tier_states_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_candidate_tier_states ADD CONSTRAINT relocation_candidate_tier_states_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_ranked_candidate_cache ADD CONSTRAINT relocation_ranked_candidate_cache_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_ranked_candidate_cache ADD CONSTRAINT relocation_ranked_candidate_cache_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_ranked_candidate_cache ADD CONSTRAINT relocation_ranked_candidate_cache_slot_id_fkey FOREIGN KEY (slot_id) REFERENCES championship_bracket_preview_private.slots(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_ranked_candidate_cache_runs ADD CONSTRAINT relocation_ranked_candidate_cache_runs_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.relocation_ranked_candidate_cache_runs ADD CONSTRAINT relocation_ranked_candidate_cache_runs_match_id_fkey FOREIGN KEY (match_id) REFERENCES championship_bracket_preview_private.matches(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.slots ADD CONSTRAINT slots_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;
ALTER TABLE championship_bracket_preview_private.slots ADD CONSTRAINT slots_sport_id_fkey FOREIGN KEY (sport_id) REFERENCES sports(id);
ALTER TABLE championship_bracket_preview_private.stage_metrics ADD CONSTRAINT stage_metrics_job_id_fkey FOREIGN KEY (job_id) REFERENCES championship_bracket_preview_private.jobs(id) ON DELETE CASCADE;

CREATE INDEX championship_bracket_preview_assignment_team_time_idx ON championship_bracket_preview_private.assignments USING btree (job_id, slot_id, match_id);
CREATE INDEX championship_bracket_preview_job_events_history_idx ON championship_bracket_preview_private.job_events USING btree (job_id, occurred_at, id);
CREATE INDEX championship_bracket_preview_jobs_expiration_idx ON championship_bracket_preview_private.jobs USING btree (expires_at);
CREATE INDEX championship_bracket_preview_jobs_recovery_idx ON championship_bracket_preview_private.jobs USING btree (heartbeat_at) WHERE (status = ANY (ARRAY['QUEUED'::text, 'INITIALIZING'::text, 'SCHEDULING'::text, 'FINALIZING'::text]));
CREATE INDEX championship_bracket_preview_jobs_terminal_expiration_idx ON championship_bracket_preview_private.jobs USING btree (expires_at) WHERE (status = ANY (ARRAY['COMPLETED'::text, 'FAILED'::text, 'CANCELLED'::text, 'CONSUMED'::text]));
CREATE UNIQUE INDEX championship_bracket_preview_one_active_job_idx ON championship_bracket_preview_private.jobs USING btree (championship_id, season_year) WHERE (status = ANY (ARRAY['QUEUED'::text, 'INITIALIZING'::text, 'SCHEDULING'::text, 'FINALIZING'::text]));
CREATE INDEX championship_bracket_preview_knockout_schedule_idx ON championship_bracket_preview_private.knockout_matches USING btree (job_id, scheduled_date, start_at, location_key, court_key);
CREATE INDEX manifest_daily_interday_repairs_job_idx ON championship_bracket_preview_private.manifest_daily_interday_repairs USING btree (job_id, final_date, success, created_at);
CREATE INDEX manifest_daily_probe_frames_search_idx ON championship_bracket_preview_private.manifest_daily_probe_frames USING btree (job_id, event_date, rest_gap, depth DESC);
CREATE INDEX manifest_daily_probe_tried_search_idx ON championship_bracket_preview_private.manifest_daily_probe_tried_matches USING btree (job_id, event_date, rest_gap, depth, slot_id);
CREATE INDEX manifest_daily_solver_frames_day_idx ON championship_bracket_preview_private.manifest_daily_solver_frames USING btree (job_id, event_date, rest_gap, depth DESC);
CREATE INDEX manifest_daily_solver_tried_day_idx ON championship_bracket_preview_private.manifest_daily_solver_tried_matches USING btree (job_id, event_date, rest_gap, depth, slot_id);
CREATE INDEX manifest_solver_candidates_match_idx ON championship_bracket_preview_private.manifest_solver_candidates USING btree (job_id, match_id, base_rank);
CREATE INDEX manifest_solver_candidates_slot_idx ON championship_bracket_preview_private.manifest_solver_candidates USING btree (job_id, slot_id);
CREATE INDEX manifest_solver_decisions_search_idx ON championship_bracket_preview_private.manifest_solver_decisions USING btree (job_id, naipe, rest_gap, depth DESC);
CREATE INDEX manifest_solver_tried_slots_frame_idx ON championship_bracket_preview_private.manifest_solver_tried_slots USING btree (job_id, naipe, rest_gap, depth, match_id);
CREATE INDEX championship_bracket_preview_match_team_idx ON championship_bracket_preview_private.matches USING btree (job_id, home_team_id, away_team_id);
CREATE INDEX championship_bracket_preview_matches_relocation_attempt_idx ON championship_bracket_preview_private.matches USING btree (job_id, assigned, relocation_attempt_count, priority_weight DESC, round_number, slot_number);
CREATE INDEX championship_bracket_preview_matches_search_idx ON championship_bracket_preview_private.matches USING btree (job_id, assigned, relocation_search_exhausted, relocation_attempt_count, priority_weight DESC, round_number, slot_number);
CREATE INDEX championship_bracket_preview_pending_match_idx ON championship_bracket_preview_private.matches USING btree (job_id, assigned, competition_id, priority_weight DESC, slot_number);
CREATE INDEX championship_bracket_preview_relocation_metrics_job_idx ON championship_bracket_preview_private.relocation_attempt_metrics USING btree (job_id, created_at DESC);
CREATE INDEX championship_bracket_preview_relocation_candidate_states_search ON championship_bracket_preview_private.relocation_candidate_states USING btree (job_id, match_id, phase, status, timeout_count, last_attempt_at);
CREATE INDEX championship_bracket_preview_relocation_tier_states_job_idx ON championship_bracket_preview_private.relocation_candidate_tier_states USING btree (job_id, match_id, phase, search_tier);
CREATE INDEX championship_bracket_preview_relocation_candidate_cache_idx ON championship_bracket_preview_private.relocation_ranked_candidate_cache USING btree (job_id, match_id, phase, candidate_rank);
CREATE INDEX championship_bracket_preview_slot_cursor_idx ON championship_bracket_preview_private.slots USING btree (job_id, processed, cursor_position);
CREATE UNIQUE INDEX championship_bracket_preview_slots_structural_key_idx ON championship_bracket_preview_private.slots USING btree (job_id, structural_slot_key) WHERE (structural_slot_key IS NOT NULL);
CREATE UNIQUE INDEX championship_bracket_preview_slots_structural_phase_idx ON championship_bracket_preview_private.slots USING btree (job_id, structural_competition_id, structural_phase, structural_phase_slot_number) WHERE ((structural_competition_id IS NOT NULL) AND (structural_phase IS NOT NULL) AND (structural_phase_slot_number IS NOT NULL));
