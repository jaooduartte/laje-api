#!/usr/bin/env bash
set -euo pipefail

if [[ "${MIGRATION_EXECUTION_CONTEXT:-}" != "controlled" || "${MIGRATION_ALLOW_DESTINATION_WRITE:-}" != "true" ]]; then
  echo "Controlled destination write authorization is required." >&2
  exit 1
fi

for variable in PGHOST PGUSER PGDATABASE PGPASSWORD PGSSLROOTCERT; do
  if [[ -z "${!variable:-}" ]]; then
    echo "${variable} is required." >&2
    exit 1
  fi
done

if [[ "${PGSSLMODE:-}" != "verify-full" ]]; then
  echo "PGSSLMODE=verify-full is required." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_FILE="${ROOT_DIR}/infra/database/baseline/schema.sql"
VALIDATE_FILE="${ROOT_DIR}/infra/database/baseline/validate.sql"
MIGRATIONS_DIR="${ROOT_DIR}/infra/database/migrations"

if [[ ! -f "${SCHEMA_FILE}" || ! -f "${VALIDATE_FILE}" ]]; then
  echo "PostgreSQL baseline files were not found." >&2
  exit 1
fi

table_count="$(psql --no-psqlrc --tuples-only --no-align --set=ON_ERROR_STOP=1 \
  --command="SELECT count(*) FROM pg_class AS relation JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace WHERE namespace.nspname = 'public' AND relation.relkind = 'r';")"
if [[ "${table_count}" != "0" ]]; then
  echo "The destination public schema must be empty before applying the baseline." >&2
  exit 1
fi

echo "Applying PostgreSQL baseline to the configured database..."
psql --no-psqlrc --set=ON_ERROR_STOP=1 --file="${SCHEMA_FILE}"

echo "Validating PostgreSQL baseline..."
psql --no-psqlrc --set=ON_ERROR_STOP=1 --file="${VALIDATE_FILE}"

for migration in "${MIGRATIONS_DIR}"/*.sql; do
  if [[ ! -f "${migration}" ]]; then
    continue
  fi
  echo "Applying $(basename "${migration}")..."
  psql --no-psqlrc --set=ON_ERROR_STOP=1 --file="${migration}"
done

echo "LAJE PostgreSQL baseline and incremental migrations applied successfully."
