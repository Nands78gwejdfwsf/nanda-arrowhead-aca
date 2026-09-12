#!/bin/sh
set -eu

: "${PGHOST:?PGHOST is required}"
: "${PGDATABASE:?PGDATABASE is required}"
: "${PGUSER:?PGUSER is required}"
: "${IDENTITY_CLIENT_ID:?IDENTITY_CLIENT_ID is required}"
: "${IDENTITY_ENDPOINT:?IDENTITY_ENDPOINT is required}"
: "${IDENTITY_HEADER:?IDENTITY_HEADER is required}"

TOKEN_URL="${IDENTITY_ENDPOINT}?api-version=2019-08-01&resource=https%3A%2F%2Fossrdbms-aad.database.windows.net&client_id=${IDENTITY_CLIENT_ID}"

TOKEN=$(curl -fsS \
  -H "X-IDENTITY-HEADER: ${IDENTITY_HEADER}" \
  "${TOKEN_URL}" | jq -er '.access_token')

PGPASSWORD="${TOKEN}" psql \
  "host=${PGHOST} port=${PGPORT:-5432} dbname=${PGDATABASE} user=${PGUSER} sslmode=${PGSSLMODE:-require}" \
  -v ON_ERROR_STOP=1 \
  -Atqc 'SELECT 1;' >/dev/null

unset TOKEN PGPASSWORD
cat > /usr/share/nginx/html/db-status.json <<EOF
{"status":"connected","database":"${PGDATABASE}","user":"${PGUSER}"}
EOF
echo "PostgreSQL connection check succeeded for ${PGUSER}@${PGDATABASE}."
