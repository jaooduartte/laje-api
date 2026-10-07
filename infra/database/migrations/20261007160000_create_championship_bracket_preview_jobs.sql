CREATE TABLE IF NOT EXISTS public.championship_bracket_preview_jobs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  championship_id uuid NOT NULL REFERENCES public.championships(id) ON DELETE CASCADE,
  season_year integer NOT NULL CHECK (season_year BETWEEN 2000 AND 2100),
  requested_by uuid,
  status text NOT NULL DEFAULT 'QUEUED'
    CHECK (status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING','COMPLETED','FAILED','CANCELLED','CONSUMED')),
  stage text NOT NULL DEFAULT 'Na fila',
  current_preview_date date,
  progress_percentage numeric(5,2) NOT NULL DEFAULT 0 CHECK (progress_percentage BETWEEN 0 AND 100),
  processed_slots integer NOT NULL DEFAULT 0 CHECK (processed_slots >= 0),
  total_slots integer NOT NULL DEFAULT 0 CHECK (total_slots >= 0),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  error_message text,
  summary jsonb,
  diagnostics jsonb NOT NULL DEFAULT '[]'::jsonb,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  payload_signature text NOT NULL,
  dependency_signature text NOT NULL,
  algorithm_version text NOT NULL DEFAULT 'aws-structural-v1',
  generation_signature text,
  result jsonb,
  events jsonb NOT NULL DEFAULT '[]'::jsonb,
  heartbeat_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS championship_bracket_preview_jobs_active_idx
  ON public.championship_bracket_preview_jobs (championship_id, season_year, status, created_at DESC);

CREATE INDEX IF NOT EXISTS championship_bracket_preview_jobs_dedup_idx
  ON public.championship_bracket_preview_jobs
    (championship_id, season_year, requested_by, payload_signature, dependency_signature, algorithm_version)
  WHERE status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING','COMPLETED');

CREATE INDEX IF NOT EXISTS championship_bracket_preview_jobs_heartbeat_idx
  ON public.championship_bracket_preview_jobs (heartbeat_at)
  WHERE status IN ('QUEUED','INITIALIZING','SCHEDULING','FINALIZING');

CREATE INDEX IF NOT EXISTS championship_bracket_preview_jobs_expiration_idx
  ON public.championship_bracket_preview_jobs (expires_at);

COMMENT ON TABLE public.championship_bracket_preview_jobs IS
  'LAJE-126: preview assíncrono de chaveamento processado pela laje-api/SQS, sem pgmq/pg_cron.';
