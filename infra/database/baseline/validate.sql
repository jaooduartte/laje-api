-- LAJE-112 — validação estrutural do baseline.
-- Execute após schema.sql em PostgreSQL 17 limpo.

\set ON_ERROR_STOP on

DO $$
DECLARE
  v_tables integer;
  v_enums integer;
  v_primary_keys integer;
  v_unique_constraints integer;
  v_check_constraints integer;
  v_foreign_keys integer;
  v_standalone_indexes integer;
  v_public_sequences integer;
  v_support_function integer;
BEGIN
  SELECT count(*)
    INTO v_tables
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'r';

  SELECT count(DISTINCT t.oid)
    INTO v_enums
  FROM pg_type t
  JOIN pg_namespace n ON n.oid = t.typnamespace
  JOIN pg_enum e ON e.enumtypid = t.oid
  WHERE n.nspname = 'public';

  SELECT count(*) FILTER (WHERE con.contype = 'p'),
         count(*) FILTER (WHERE con.contype = 'u'),
         count(*) FILTER (WHERE con.contype = 'c'),
         count(*) FILTER (WHERE con.contype = 'f')
    INTO v_primary_keys,
         v_unique_constraints,
         v_check_constraints,
         v_foreign_keys
  FROM pg_constraint con
  JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public';

  SELECT count(*)
    INTO v_standalone_indexes
  FROM pg_index i
  JOIN pg_class t ON t.oid = i.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname = 'public'
    AND NOT EXISTS (
      SELECT 1
      FROM pg_constraint con
      WHERE con.conindid = i.indexrelid
    );

  SELECT count(*)
    INTO v_public_sequences
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind = 'S';

  SELECT count(*)
    INTO v_support_function
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'coerce_division_for_index'
    AND pg_get_function_identity_arguments(p.oid) = 'd team_division';

  IF v_tables <> 67 THEN
    RAISE EXCEPTION 'Baseline inválido: esperado 67 tabelas public, encontrado %', v_tables;
  END IF;

  IF v_enums <> 37 THEN
    RAISE EXCEPTION 'Baseline inválido: esperado 37 enums public, encontrado %', v_enums;
  END IF;

  IF v_primary_keys <> 67 THEN
    RAISE EXCEPTION 'Baseline inválido: esperado 67 PKs, encontrado %', v_primary_keys;
  END IF;

  IF v_unique_constraints <> 45 THEN
    RAISE EXCEPTION 'Baseline inválido: esperado 45 constraints UNIQUE, encontrado %', v_unique_constraints;
  END IF;

  IF v_check_constraints <> 91 THEN
    RAISE EXCEPTION 'Baseline inválido: esperado 91 constraints CHECK, encontrado %', v_check_constraints;
  END IF;

  -- O Supabase possui 149 FKs no public. Quinze apontam para auth.users e são
  -- deliberadamente adiadas para LAJE-85; o baseline independente contém 134 FKs public->public.
  IF v_foreign_keys <> 134 THEN
    RAISE EXCEPTION 'Baseline inválido: esperado 134 FKs internas, encontrado %', v_foreign_keys;
  END IF;

  IF v_standalone_indexes <> 92 THEN
    RAISE EXCEPTION 'Baseline inválido: esperado 92 índices standalone, encontrado %', v_standalone_indexes;
  END IF;

  IF v_public_sequences <> 0 THEN
    RAISE EXCEPTION 'Baseline inválido: esperado 0 sequences no public, encontrado %', v_public_sequences;
  END IF;

  IF v_support_function <> 1 THEN
    RAISE EXCEPTION 'Baseline inválido: função estrutural coerce_division_for_index ausente ou duplicada';
  END IF;

  IF to_regclass('auth.users') IS NOT NULL THEN
    RAISE EXCEPTION 'Baseline inválido: schema Supabase Auth não deve ser criado por LAJE-112';
  END IF;

  RAISE NOTICE 'Baseline LAJE validado: 67 tabelas, 37 enums, 67 PKs, 45 UNIQUE, 91 CHECK, 134 FKs internas, 92 índices standalone.';
END
$$;
