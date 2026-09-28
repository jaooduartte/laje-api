#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "DATABASE_URL is required." >&2
  exit 1
fi

if [[ -z "${PGSSLROOTCERT:-}" ]]; then
  echo "PGSSLROOTCERT must point to the trusted Amazon RDS CA bundle." >&2
  exit 1
fi

export PGSSLMODE="${PGSSLMODE:-verify-full}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_FILE="${ROOT_DIR}/infra/database/baseline/schema.sql"
VALIDATE_FILE="${ROOT_DIR}/infra/database/baseline/validate.sql"

if [[ ! -f "${SCHEMA_FILE}" || ! -f "${VALIDATE_FILE}" ]]; then
  echo "PostgreSQL baseline files were not found." >&2
  exit 1
fi

echo "Applying PostgreSQL baseline to the configured staging database..."
psql "${DATABASE_URL}" \
  --set=ON_ERROR_STOP=1 \
  --file="${SCHEMA_FILE}"

echo "Validating PostgreSQL baseline..."
psql "${DATABASE_URL}" \
  --set=ON_ERROR_STOP=1 \
  --file="${VALIDATE_FILE}"

echo "LAJE staging PostgreSQL baseline applied and validated successfully."
