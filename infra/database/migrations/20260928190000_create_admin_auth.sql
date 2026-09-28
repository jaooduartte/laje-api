-- LAJE-85 — autenticação administrativa dedicada da laje-api.
-- Migration incremental: não altera o baseline consolidado da LAJE-112.

CREATE TABLE IF NOT EXISTS public.admin_auth_accounts (
  user_id uuid PRIMARY KEY
    REFERENCES public.admin_user_profiles(user_id)
    ON DELETE CASCADE,
  email text,
  password_hash text,
  password_changed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT admin_auth_accounts_password_hash_check
    CHECK (password_hash IS NULL OR char_length(password_hash) >= 32)
);

CREATE UNIQUE INDEX IF NOT EXISTS admin_auth_accounts_email_unique_idx
  ON public.admin_auth_accounts (lower(email))
  WHERE email IS NOT NULL;

CREATE TABLE IF NOT EXISTS public.admin_auth_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL
    REFERENCES public.admin_auth_accounts(user_id)
    ON DELETE CASCADE,
  refresh_token_hash text NOT NULL,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  last_used_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT admin_auth_sessions_refresh_token_hash_check
    CHECK (char_length(refresh_token_hash) = 64),
  CONSTRAINT admin_auth_sessions_expiry_check
    CHECK (expires_at > created_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS admin_auth_sessions_refresh_token_hash_unique_idx
  ON public.admin_auth_sessions (refresh_token_hash);

CREATE INDEX IF NOT EXISTS admin_auth_sessions_active_user_idx
  ON public.admin_auth_sessions (user_id, expires_at)
  WHERE revoked_at IS NULL;

COMMENT ON TABLE public.admin_auth_accounts IS
  'Credenciais administrativas da laje-api. password_hash usa scrypt; dados do Supabase Auth são migrados somente no cutover controlado.';

COMMENT ON TABLE public.admin_auth_sessions IS
  'Sessões administrativas revogáveis. Somente hash SHA-256 do refresh token é persistido.';
