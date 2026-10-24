-- LAJE-150 — PostgreSQL AWS identity adapter for selected operational functions.
-- The AWS API sets laje.request_user_id transaction-locally after JWT/RBAC validation.
-- Avoid dependency on Supabase Auth's auth.users and auth.uid() session implementation.
CREATE SCHEMA IF NOT EXISTS auth;

CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
  SELECT nullif(current_setting('laje.request_user_id', true), '')::uuid
$$;

REVOKE ALL ON FUNCTION auth.uid() FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.write_admin_action_log(
  _action_type public.admin_action_type,
  _resource_table text,
  _record_id text DEFAULT NULL,
  _description text DEFAULT NULL,
  _old_data jsonb DEFAULT NULL,
  _new_data jsonb DEFAULT NULL,
  _metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
DECLARE
  actor_user_id uuid := auth.uid();
  actor_role public.app_role;
  actor_email text;
  actor_name text;
BEGIN
  IF actor_user_id IS NULL THEN
    RAISE EXCEPTION 'A auditoria administrativa exige um usuário autenticado.';
  END IF;

  SELECT aa.email, up.name
    INTO actor_email, actor_name
    FROM public.admin_auth_accounts aa
    JOIN public.admin_user_profiles up ON up.user_id = aa.user_id
   WHERE aa.user_id = actor_user_id
     AND up.password_status = 'ACTIVE'::public.admin_user_password_status
   LIMIT 1;

  IF actor_email IS NULL THEN
    RAISE EXCEPTION 'Usuário administrativo não encontrado para registrar a alteração.';
  END IF;

  SELECT ur.role
    INTO actor_role
    FROM public.user_roles ur
   WHERE ur.user_id = actor_user_id
   ORDER BY CASE ur.role::text WHEN 'admin' THEN 0 WHEN 'eventos' THEN 1 WHEN 'mesa' THEN 2 ELSE 3 END
   LIMIT 1;

  INSERT INTO public.admin_action_logs (
    actor_user_id, actor_email, actor_name, actor_role, action_type,
    resource_table, record_id, description, old_data, new_data, metadata
  ) VALUES (
    actor_user_id, actor_email,
    public.normalize_admin_user_name(actor_name, actor_email),
    actor_role, _action_type, _resource_table, _record_id,
    _description, _old_data, _new_data, coalesce(_metadata, '{}'::jsonb)
  );
END;
$$;
