-- LAJE-146 — atomic, distributed rate limiting for privileged laje-api endpoints.
-- Apply as an incremental PostgreSQL migration (do not edit the LAJE-112 baseline).
CREATE TABLE IF NOT EXISTS public.api_rate_limit_windows (
  key_hash char(64) PRIMARY KEY,
  window_bucket bigint NOT NULL,
  hits integer NOT NULL CHECK (hits >= 1),
  CONSTRAINT api_rate_limit_windows_hash_check
    CHECK (key_hash ~ '^[0-9a-f]{64}$')
);

-- Periodic maintenance (at most daily) for operators:
-- DELETE FROM public.api_rate_limit_windows
-- WHERE window_bucket < floor(extract(epoch FROM now()) / 60) - 1440;
-- Because each scope has its own configurable window, stale rows should be
-- removed by a maintenance job after 7 days of inactivity, not by a naive bucket comparison.
