-- LAJE-112 — baseline estrutural consolidado do PostgreSQL.
--
-- Fonte: Supabase LAJE (PostgreSQL 17.6), snapshot de 2026-09-27.
-- Alvo: PostgreSQL 17 limpo, incluindo Amazon RDS for PostgreSQL 17.
--
-- Este arquivo é o entrypoint oficial do baseline e deve ser executado via psql.
-- Ele NÃO importa dados e NÃO reproduz componentes específicos da plataforma Supabase
-- (Auth, Storage, Realtime, RLS/policies, Edge Functions, cron ou schemas internos).
--
-- Uso:
--   psql "$DATABASE_URL" --set ON_ERROR_STOP=1 --file infra/database/baseline/schema.sql
--
-- O baseline é destinado a banco vazio. Após sua consolidação, alterações futuras de
-- schema devem ser adicionadas como novas migrations, sem editar retroativamente este snapshot.

\set ON_ERROR_STOP on

BEGIN;

SET client_min_messages = warning;
SET search_path = public, pg_catalog;

\ir types.sql
\ir tables.sql
\ir keys.sql
\ir checks.sql
\ir foreign-keys.sql
\ir support-functions.sql
\ir indexes.sql

COMMIT;
