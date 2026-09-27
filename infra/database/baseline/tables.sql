-- LAJE-112 — tabelas do schema public
-- Snapshot estrutural do Supabase em 2026-09-27. Sem dados.

CREATE TABLE public.admin_action_logs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  actor_user_id uuid,
  actor_email text,
  actor_role app_role,
  action_type admin_action_type NOT NULL,
  resource_table text NOT NULL,
  record_id text,
  description text,
  old_data jsonb,
  new_data jsonb,
  metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  actor_name text
);

CREATE TABLE public.admin_profile_permissions (
  profile_id uuid NOT NULL,
  admin_tab admin_panel_tab NOT NULL,
  access_level admin_panel_permission_level DEFAULT 'NONE'::admin_panel_permission_level NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.admin_profiles (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  is_system boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  system_role app_role
);

CREATE TABLE public.admin_user_profiles (
  user_id uuid NOT NULL,
  profile_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  login_identifier text NOT NULL,
  password_status admin_user_password_status DEFAULT 'PENDING'::admin_user_password_status NOT NULL,
  name text NOT NULL,
  theme_mode_preference theme_mode_preference DEFAULT 'auto'::theme_mode_preference NOT NULL
);

CREATE TABLE public.championship_award_draw_results (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  sport_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  award_type championship_award_type NOT NULL,
  winner_player_id uuid,
  tied_player_ids_signature text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  winner_team_id uuid
);

CREATE TABLE public.championship_award_players (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  sport_id uuid NOT NULL,
  team_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  name text NOT NULL,
  normalized_name text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_competitions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_edition_id uuid NOT NULL,
  sport_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  groups_count integer NOT NULL,
  qualifiers_per_group integer NOT NULL,
  third_place_mode bracket_third_place_mode DEFAULT 'NONE'::bracket_third_place_mode NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  should_complete_knockout_with_best_second_placed_teams boolean DEFAULT false NOT NULL,
  knockout_pairing_mode text DEFAULT 'CLASSIC_SEEDED'::text NOT NULL
);

CREATE TABLE public.championship_bracket_court_sports (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_court_id uuid NOT NULL,
  sport_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  preferred_naipe match_naipe,
  preferred_division team_division,
  sequence_mode bracket_court_sequence_mode DEFAULT 'FLEXIBLE'::bracket_court_sequence_mode NOT NULL,
  alternate_naipe_after_exclusive_knockout_phase boolean DEFAULT false NOT NULL
);

CREATE TABLE public.championship_bracket_courts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_location_id uuid NOT NULL,
  name text NOT NULL,
  "position" integer DEFAULT 1 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  court_group_id uuid NOT NULL,
  preferred_sport_id uuid
);

CREATE TABLE public.championship_bracket_day_breaks (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_day_id uuid NOT NULL,
  break_start_time time without time zone NOT NULL,
  break_end_time time without time zone NOT NULL,
  "position" integer DEFAULT 1 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  scope_type bracket_day_break_scope_type DEFAULT 'ALL_COURTS'::bracket_day_break_scope_type NOT NULL,
  bracket_court_id uuid
);

CREATE TABLE public.championship_bracket_days (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_edition_id uuid NOT NULL,
  event_date date NOT NULL,
  start_time time without time zone NOT NULL,
  end_time time without time zone NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  break_start_time time without time zone,
  break_end_time time without time zone
);

CREATE TABLE public.championship_bracket_editions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  status bracket_edition_status DEFAULT 'DRAFT'::bracket_edition_status NOT NULL,
  payload_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  season_year integer DEFAULT (date_part('year'::text, timezone('America/Sao_Paulo'::text, now())))::integer NOT NULL,
  updated_by uuid,
  reprogramming_revision bigint DEFAULT 0 NOT NULL
);

CREATE TABLE public.championship_bracket_group_teams (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  group_id uuid NOT NULL,
  team_id uuid NOT NULL,
  "position" integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_groups (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  competition_id uuid NOT NULL,
  group_number integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_knockout_court_priorities (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_edition_id uuid NOT NULL,
  sport_id uuid NOT NULL,
  phase bracket_knockout_priority_phase NOT NULL,
  division_scope bracket_knockout_division_scope DEFAULT 'ALL'::bracket_knockout_division_scope NOT NULL,
  location_group_id uuid NOT NULL,
  court_group_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_knockout_schedule_reservations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_edition_id uuid NOT NULL,
  competition_id uuid NOT NULL,
  round_number integer NOT NULL,
  slot_number integer NOT NULL,
  is_third_place boolean DEFAULT false NOT NULL,
  scheduled_date date NOT NULL,
  schedule_period championship_schedule_period NOT NULL,
  location_name text NOT NULL,
  court_name text NOT NULL,
  location_group_id uuid NOT NULL,
  court_group_id uuid NOT NULL,
  bracket_day_id uuid NOT NULL,
  bracket_court_id uuid NOT NULL,
  scheduled_slot integer NOT NULL,
  queue_position integer NOT NULL,
  start_at timestamp with time zone NOT NULL,
  end_at timestamp with time zone NOT NULL,
  duration_minutes integer NOT NULL,
  is_manual_final boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_location_sport_priorities (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_edition_id uuid NOT NULL,
  location_group_id uuid NOT NULL,
  sport_id uuid NOT NULL,
  priority_mode bracket_court_priority_mode DEFAULT 'NONE'::bracket_court_priority_mode NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_location_template_court_sports (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  location_template_court_id uuid NOT NULL,
  sport_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_location_template_courts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  location_template_id uuid NOT NULL,
  name text NOT NULL,
  "position" integer DEFAULT 1 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_location_templates (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  normalized_name text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_locations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_day_id uuid NOT NULL,
  name text NOT NULL,
  "position" integer DEFAULT 1 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  location_group_id uuid NOT NULL
);

CREATE TABLE public.championship_bracket_matches (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_edition_id uuid NOT NULL,
  competition_id uuid NOT NULL,
  group_id uuid,
  phase bracket_phase NOT NULL,
  round_number integer DEFAULT 1 NOT NULL,
  slot_number integer DEFAULT 1 NOT NULL,
  match_id uuid,
  home_team_id uuid,
  away_team_id uuid,
  winner_team_id uuid,
  source_home_bracket_match_id uuid,
  source_away_bracket_match_id uuid,
  next_bracket_match_id uuid,
  is_bye boolean DEFAULT false NOT NULL,
  is_third_place boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  planned_scheduled_date date,
  planned_period championship_schedule_period,
  planned_scheduled_slot integer,
  planned_queue_position integer,
  planned_start_time time without time zone,
  planned_end_time time without time zone,
  planned_location_group_id uuid,
  planned_court_group_id uuid,
  planned_location_name text,
  planned_court_name text
);

CREATE TABLE public.championship_bracket_team_modalities (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_edition_id uuid NOT NULL,
  team_id uuid NOT NULL,
  sport_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_team_registrations (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_edition_id uuid NOT NULL,
  team_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_tie_break_resolution_teams (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  resolution_id uuid NOT NULL,
  team_id uuid NOT NULL,
  draw_order integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_bracket_tie_break_resolutions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  bracket_edition_id uuid NOT NULL,
  competition_id uuid NOT NULL,
  group_id uuid,
  context_type championship_bracket_tie_break_context_type NOT NULL,
  qualification_rank integer,
  context_key text NOT NULL,
  tied_team_signature text NOT NULL,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_competition_team_disqualifications (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  sport_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  team_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  created_by uuid
);

CREATE TABLE public.championship_individual_event_entries (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  event_id uuid NOT NULL,
  team_id uuid NOT NULL,
  athlete_id uuid,
  athlete_name text,
  entry_type championship_individual_event_kind NOT NULL,
  final_position integer,
  status championship_individual_entry_status DEFAULT 'PENDING'::championship_individual_entry_status NOT NULL,
  points_awarded numeric(10,2) DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  result_time_milliseconds integer,
  result_mark_centimeters integer,
  lane_number integer,
  attempt_one_centimeters integer,
  attempt_two_centimeters integer,
  attempt_three_centimeters integer,
  recording_mode text DEFAULT 'ATHLETE_METRIC'::text NOT NULL
);

CREATE TABLE public.championship_individual_event_entry_members (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  entry_id uuid NOT NULL,
  athlete_id uuid,
  athlete_name text NOT NULL,
  is_starter boolean DEFAULT false NOT NULL,
  "position" integer DEFAULT 1 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_individual_events (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  sport_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  event_code text NOT NULL,
  name text NOT NULL,
  kind championship_individual_event_kind NOT NULL,
  display_order integer DEFAULT 1 NOT NULL,
  scheduled_date date,
  period championship_schedule_period,
  location text,
  status championship_individual_event_status DEFAULT 'DRAFT'::championship_individual_event_status NOT NULL,
  relay_multiplier numeric(10,2) DEFAULT 2 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  session_id uuid
);

CREATE TABLE public.championship_individual_sessions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  sport_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  scheduled_date date,
  period championship_schedule_period,
  location_key text,
  court_key text,
  location_name text,
  court_name text,
  status championship_individual_session_status DEFAULT 'DRAFT'::championship_individual_session_status NOT NULL,
  exclusive_lock_enabled boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  start_time time without time zone,
  end_time time without time zone
);

CREATE TABLE public.championship_individual_team_standings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  sport_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  team_id uuid NOT NULL,
  total_points numeric(10,2) DEFAULT 0 NOT NULL,
  scored_events_count integer DEFAULT 0 NOT NULL,
  first_places integer DEFAULT 0 NOT NULL,
  second_places integer DEFAULT 0 NOT NULL,
  third_places integer DEFAULT 0 NOT NULL,
  fourth_places integer DEFAULT 0 NOT NULL,
  fifth_places integer DEFAULT 0 NOT NULL,
  sixth_places integer DEFAULT 0 NOT NULL,
  seventh_places integer DEFAULT 0 NOT NULL,
  eighth_places integer DEFAULT 0 NOT NULL,
  ninth_places integer DEFAULT 0 NOT NULL,
  tenth_places integer DEFAULT 0 NOT NULL,
  eleventh_places integer DEFAULT 0 NOT NULL,
  twelfth_places integer DEFAULT 0 NOT NULL,
  thirteenth_places integer DEFAULT 0 NOT NULL,
  fourteenth_places integer DEFAULT 0 NOT NULL,
  fifteenth_places integer DEFAULT 0 NOT NULL,
  sixteenth_places integer DEFAULT 0 NOT NULL,
  seventeenth_places integer DEFAULT 0 NOT NULL,
  eighteenth_places integer DEFAULT 0 NOT NULL,
  nineteenth_places integer DEFAULT 0 NOT NULL,
  twentieth_places integer DEFAULT 0 NOT NULL,
  relay_points_total numeric(10,2) DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_interlaje_individual_tie_break_resolutions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  event_id uuid NOT NULL,
  decision_kind text NOT NULL,
  justification text NOT NULL,
  resolved_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_interlaje_ranking_audits (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  competition_id uuid NOT NULL,
  previous_qualified_team_ids uuid[] NOT NULL,
  current_qualified_team_ids uuid[] NOT NULL,
  action text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_interlaje_tie_break_resolutions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  sport_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  group_id uuid,
  team_id uuid NOT NULL,
  draw_order integer NOT NULL,
  decision_kind text NOT NULL,
  justification text NOT NULL,
  resolved_by uuid,
  resolved_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_knockout_result_corrections (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  competition_id uuid NOT NULL,
  source_bracket_match_id uuid NOT NULL,
  source_match_id uuid NOT NULL,
  previous_winner_team_id uuid,
  corrected_winner_team_id uuid,
  walkover_mode text NOT NULL,
  reason text,
  selected_replay_slot jsonb,
  impact_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
  archived_matches jsonb DEFAULT '[]'::jsonb NOT NULL,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_opening_ceremony_bonus_settings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  points integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_overall_competition_placements (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  sport_id uuid NOT NULL,
  naipe match_naipe NOT NULL,
  division team_division,
  team_id uuid NOT NULL,
  final_position integer NOT NULL,
  source text DEFAULT 'MANUAL'::text NOT NULL,
  justification text,
  confirmed_by uuid,
  confirmed_at timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_overall_position_point_settings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  final_position integer NOT NULL,
  points integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_overall_score_adjustments (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  team_id uuid NOT NULL,
  adjustment_type text NOT NULL,
  points numeric NOT NULL,
  justification text NOT NULL,
  granted_by uuid,
  granted_at timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_overall_tie_break_resolution_teams (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  resolution_id uuid NOT NULL,
  team_id uuid NOT NULL,
  draw_order integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_overall_tie_break_resolutions (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  points_total numeric NOT NULL,
  team_signature text NOT NULL,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_season_division_movements (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  team_id uuid NOT NULL,
  previous_division team_division,
  next_division team_division,
  source_division team_division,
  ranking_position integer NOT NULL,
  rule_code text NOT NULL,
  confirmed_by uuid,
  confirmed_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE public.championship_season_settings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  division_format championship_season_division_format DEFAULT 'UNIFIED'::championship_season_division_format NOT NULL,
  division_settlement_mode championship_season_division_settlement_mode DEFAULT 'NONE'::championship_season_division_settlement_mode NOT NULL,
  principal_slots_count integer,
  principal_relegation_count integer,
  access_promotion_count integer,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  yellow_card_reset_phase text DEFAULT 'NONE'::text NOT NULL
);

CREATE TABLE public.championship_season_sport_removals (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  sport_id uuid NOT NULL,
  removed_by uuid,
  removed_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_sports (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  sport_id uuid NOT NULL,
  points_win integer DEFAULT 3 NOT NULL,
  points_draw integer DEFAULT 1 NOT NULL,
  points_loss integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  naipe_mode championship_sport_naipe_mode DEFAULT 'MASCULINO_FEMININO'::championship_sport_naipe_mode NOT NULL,
  supports_cards boolean DEFAULT false NOT NULL,
  tie_breaker_rule championship_sport_tie_breaker_rule DEFAULT 'STANDARD'::championship_sport_tie_breaker_rule NOT NULL,
  result_rule championship_sport_result_rule DEFAULT 'POINTS'::championship_sport_result_rule NOT NULL,
  default_match_duration_minutes integer NOT NULL,
  show_estimated_start_time_on_cards boolean DEFAULT false NOT NULL,
  walkover_winner_points integer,
  awards_include_knockout_phase boolean DEFAULT false NOT NULL,
  supports_individual_awards boolean DEFAULT false NOT NULL,
  walkover_winner_set_count integer DEFAULT 1 NOT NULL,
  classification_policy jsonb
);

CREATE TABLE public.championship_walkover_penalty_counts (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  team_id uuid NOT NULL,
  walkover_count integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championship_walkover_penalty_settings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  points integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.championships (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  code championship_code NOT NULL,
  name text NOT NULL,
  uses_divisions boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  status championship_status DEFAULT 'UPCOMING'::championship_status NOT NULL,
  default_location text,
  current_season_year integer DEFAULT (date_part('year'::text, timezone('America/Sao_Paulo'::text, now())))::integer NOT NULL
);

CREATE TABLE public.league_calendar_holidays (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  holiday_date date NOT NULL,
  name text NOT NULL,
  scope league_calendar_holiday_scope NOT NULL,
  day_kind league_calendar_holiday_day_kind NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.league_event_organizer_teams (
  event_id uuid NOT NULL,
  team_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.league_event_reservation_requests (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  team_id uuid NOT NULL,
  event_name text NOT NULL,
  event_type league_event_type NOT NULL,
  event_date date NOT NULL,
  requester_name text NOT NULL,
  requester_email text NOT NULL,
  status league_event_reservation_request_status DEFAULT 'PENDING'::league_event_reservation_request_status NOT NULL,
  approved_league_event_id uuid,
  review_notes text,
  reviewed_at timestamp with time zone,
  reviewed_by uuid,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
  updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE public.league_events (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  event_type league_event_type NOT NULL,
  organizer_type league_event_organizer_type NOT NULL,
  organizer_team_id uuid,
  event_date date NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.match_award_goal_scorers (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  match_id uuid NOT NULL,
  team_id uuid NOT NULL,
  player_id uuid NOT NULL,
  goal_order integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.match_blue_card_players (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  match_id uuid NOT NULL,
  team_id uuid NOT NULL,
  player_id uuid NOT NULL,
  card_order integer NOT NULL,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE public.match_red_card_players (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  match_id uuid NOT NULL,
  team_id uuid NOT NULL,
  player_id uuid NOT NULL,
  card_order integer NOT NULL,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE public.match_sets (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  match_id uuid NOT NULL,
  set_number integer NOT NULL,
  home_points integer DEFAULT 0 NOT NULL,
  away_points integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.match_yellow_card_players (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  match_id uuid NOT NULL,
  team_id uuid NOT NULL,
  player_id uuid NOT NULL,
  card_order integer NOT NULL,
  created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE public.matches (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sport_id uuid NOT NULL,
  home_team_id uuid NOT NULL,
  away_team_id uuid NOT NULL,
  location text,
  start_time timestamp with time zone,
  end_time timestamp with time zone,
  status match_status DEFAULT 'SCHEDULED'::match_status NOT NULL,
  home_score integer DEFAULT 0 NOT NULL,
  away_score integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  championship_id uuid NOT NULL,
  division team_division,
  naipe match_naipe DEFAULT 'MASCULINO'::match_naipe NOT NULL,
  supports_cards boolean DEFAULT false NOT NULL,
  home_yellow_cards integer DEFAULT 0 NOT NULL,
  home_red_cards integer DEFAULT 0 NOT NULL,
  away_yellow_cards integer DEFAULT 0 NOT NULL,
  away_red_cards integer DEFAULT 0 NOT NULL,
  court_name text,
  season_year integer DEFAULT (date_part('year'::text, timezone('America/Sao_Paulo'::text, now())))::integer NOT NULL,
  scheduled_date date,
  queue_position integer,
  current_set_home_score integer,
  current_set_away_score integer,
  resolved_tie_breaker_rule championship_sport_tie_breaker_rule,
  resolved_tie_break_winner_team_id uuid,
  global_queue_order integer,
  scheduled_slot integer,
  is_walkover boolean DEFAULT false NOT NULL,
  walkover_loser_team_id uuid,
  is_score_sheet_reviewed boolean DEFAULT false NOT NULL,
  manual_representation_mode text DEFAULT 'AUTO'::text NOT NULL,
  is_double_walkover boolean DEFAULT false NOT NULL,
  disqualification_id uuid,
  home_penalty_score integer,
  away_penalty_score integer,
  home_blue_cards integer DEFAULT 0 NOT NULL,
  away_blue_cards integer DEFAULT 0 NOT NULL,
  home_two_minute_penalties integer DEFAULT 0 NOT NULL,
  away_two_minute_penalties integer DEFAULT 0 NOT NULL,
  is_manual_schedule_override boolean DEFAULT false NOT NULL,
  manual_schedule_override_reason text,
  manual_schedule_override_notes text,
  is_pending_manual_relocation boolean DEFAULT false NOT NULL,
  pending_manual_relocation_reason text,
  pending_manual_relocation_notes text,
  pending_manual_relocation_previous_schedule jsonb,
  pending_manual_relocation_previous_label text,
  pending_manual_relocation_created_by uuid,
  pending_manual_relocation_at timestamp with time zone,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  scheduled_start_time timestamp with time zone
);

CREATE TABLE public.public_link_item_filters (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  public_link_item_id uuid NOT NULL,
  championship_id uuid NOT NULL,
  season_year integer NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.public_link_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  section_id uuid NOT NULL,
  display_name text NOT NULL,
  url text NOT NULL,
  sort_order integer DEFAULT 1 NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  filter_mode public_link_filter_mode DEFAULT 'GLOBAL'::public_link_filter_mode NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.public_link_sections (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  description text,
  sort_order integer DEFAULT 1 NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.public_page_access_settings (
  id smallint DEFAULT 1 NOT NULL,
  is_public_access_blocked boolean DEFAULT false NOT NULL,
  blocked_message text,
  updated_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  is_live_page_blocked boolean DEFAULT false NOT NULL,
  is_championships_page_blocked boolean DEFAULT false NOT NULL,
  is_schedule_page_blocked boolean DEFAULT false NOT NULL,
  is_league_calendar_page_blocked boolean DEFAULT false NOT NULL,
  is_links_page_blocked boolean DEFAULT false NOT NULL,
  announcement_message text,
  announcement_content jsonb,
  announcement_type text DEFAULT 'NOTICE'::text NOT NULL
);

CREATE TABLE public.sports (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  code text,
  default_match_duration_minutes integer NOT NULL
);

CREATE TABLE public.standings (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  sport_id uuid NOT NULL,
  team_id uuid NOT NULL,
  played integer DEFAULT 0 NOT NULL,
  wins integer DEFAULT 0 NOT NULL,
  draws integer DEFAULT 0 NOT NULL,
  losses integer DEFAULT 0 NOT NULL,
  goals_for integer DEFAULT 0 NOT NULL,
  goals_against integer DEFAULT 0 NOT NULL,
  goal_diff integer DEFAULT 0 NOT NULL,
  points integer DEFAULT 0 NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  championship_id uuid NOT NULL,
  division team_division,
  naipe match_naipe DEFAULT 'MASCULINO'::match_naipe NOT NULL,
  yellow_cards integer DEFAULT 0 NOT NULL,
  red_cards integer DEFAULT 0 NOT NULL,
  season_year integer DEFAULT (date_part('year'::text, timezone('America/Sao_Paulo'::text, now())))::integer NOT NULL,
  blue_cards integer DEFAULT 0 NOT NULL,
  two_minute_penalties integer DEFAULT 0 NOT NULL
);

CREATE TABLE public.teams (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  name text NOT NULL,
  city text DEFAULT 'Joinville'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  division team_division DEFAULT 'DIVISAO_ACESSO'::team_division,
  is_active boolean DEFAULT true NOT NULL
);

CREATE TABLE public.user_roles (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  user_id uuid NOT NULL,
  role app_role NOT NULL
);
