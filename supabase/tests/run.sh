#!/usr/bin/env bash
# Run migration + seed + schema tests against a throwaway local Postgres (no Docker needed).
# Usage: supabase/tests/run.sh   (set PG_BIN if Postgres 17 binaries live elsewhere)
set -euo pipefail

PG_BIN="${PG_BIN:-/opt/homebrew/opt/postgresql@17/bin}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DATA="$(mktemp -d)"
PORT="${PORT:-54399}"

cleanup() { "$PG_BIN/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$DATA"; }
trap cleanup EXIT

"$PG_BIN/initdb" -D "$DATA" -U postgres --auth=trust >/dev/null
"$PG_BIN/pg_ctl" -D "$DATA" -o "-p $PORT -k $DATA" -l "$DATA/log" -w start >/dev/null

psql() { "$PG_BIN/psql" -h "$DATA" -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -q "$@"; }

psql -f "$ROOT/supabase/tests/stub_supabase.sql"
for f in "$ROOT"/supabase/migrations/*.sql; do psql -f "$f"; done
psql -f "$ROOT/supabase/seed.sql"
psql -f "$ROOT/supabase/tests/schema_test.sql"
