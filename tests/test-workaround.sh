#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/cursor-proxy-workaround.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cursor-proxy-workaround.XXXXXX")
DB="$TEST_DIR/state.vscdb"
BACKUPS="$TEST_DIR/backups"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT HUP INT TERM

assert_equal() {
  expected=$1
  actual=$2
  label=$3
  [ "$expected" = "$actual" ] || {
    printf 'FAIL: %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  }
}

run_script() {
  CURSOR_STATE_DB="$DB" \
  CURSOR_BACKUP_DIR="$BACKUPS" \
  CURSOR_SKIP_PROCESS_CHECK=1 \
  CURSOR_SKIP_LAUNCH=1 \
    "$SCRIPT" "$@"
}

sqlite3 "$DB" <<'SQL'
CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT);
INSERT INTO ItemTable(key, value)
VALUES (
  'workbench.experiments.statsigBootstrap',
  '{"feature_gates":{"3795038140":{"value":true}}}'
);
INSERT INTO ItemTable(key, value)
VALUES ('decompose_always_local_ext_host', 'false');
SQL

run_script repair >/dev/null

gate_value=$(sqlite3 "$DB" "SELECT json_extract(value, '$.feature_gates.\"3795038140\".value') FROM ItemTable WHERE key='workbench.experiments.statsigBootstrap';")
trigger_count=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'cursor_proxy_force_decompose_gate_off_%';")
obsolete_count=$(sqlite3 "$DB" "SELECT count(*) FROM ItemTable WHERE key IN ('decompose_always_local_ext_host', 'cursor_extensions_isolation_v2');")

assert_equal 0 "$gate_value" "gate after repair"
assert_equal 2 "$trigger_count" "trigger count after repair"
assert_equal 0 "$obsolete_count" "obsolete override count"

set -- "$BACKUPS"/statsigBootstrap-*.json
[ -s "$1" ] || {
  printf '%s\n' 'FAIL: backup was not created' >&2
  exit 1
}

sqlite3 "$DB" "UPDATE ItemTable SET value=json_set(value, '$.feature_gates.\"3795038140\".value', json('true')) WHERE key='workbench.experiments.statsigBootstrap';"
gate_value=$(sqlite3 "$DB" "SELECT json_extract(value, '$.feature_gates.\"3795038140\".value') FROM ItemTable WHERE key='workbench.experiments.statsigBootstrap';")
assert_equal 0 "$gate_value" "gate after simulated server refresh"

run_script remove >/dev/null
trigger_count=$(sqlite3 "$DB" "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'cursor_proxy_force_decompose_gate_off_%';")
assert_equal 0 "$trigger_count" "trigger count after remove"

printf '%s\n' 'PASS: cursor proxy workaround fixture test'
