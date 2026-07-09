#!/bin/sh

set -eu

DB=${CURSOR_STATE_DB:-"$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb"}
BACKUP_DIR=${CURSOR_BACKUP_DIR:-"$HOME/Library/Application Support/Cursor/User/globalStorage/proxy-workaround-backups"}
SKIP_PROCESS_CHECK=${CURSOR_SKIP_PROCESS_CHECK:-0}
SKIP_LAUNCH=${CURSOR_SKIP_LAUNCH:-0}
GATE_PATH='$.feature_gates."3795038140".value'
TRIGGER_UPDATE='cursor_proxy_force_decompose_gate_off_update'
TRIGGER_INSERT='cursor_proxy_force_decompose_gate_off_insert'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_db() {
  command -v sqlite3 >/dev/null || die "sqlite3 is required"
  [ -f "$DB" ] || die "Cursor state database not found: $DB"
}

cursor_is_running() {
  [ "$SKIP_PROCESS_CHECK" = "1" ] && return 1
  pgrep -x Cursor >/dev/null || pgrep -f 'always-local-host|alwaysLocalSingletonMain' >/dev/null
}

status() {
  require_db

  gate_value=$(sqlite3 "$DB" "PRAGMA query_only=ON; SELECT json_extract(value, '$GATE_PATH') FROM ItemTable WHERE key='workbench.experiments.statsigBootstrap';")
  trigger_count=$(sqlite3 "$DB" "PRAGMA query_only=ON; SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name IN ('$TRIGGER_UPDATE', '$TRIGGER_INSERT');")

  printf 'gate_value=%s\n' "${gate_value:-missing}"
  printf 'trigger_count=%s\n' "$trigger_count"

  if pgrep -f 'always-local-host|alwaysLocalSingletonMain' >/dev/null; then
    printf '%s\n' 'always_local_singleton=running'
  else
    printf '%s\n' 'always_local_singleton=stopped'
  fi

  if cursor_is_running; then
    printf '%s\n' 'cursor=running'
    lsof -nP -iTCP -sTCP:ESTABLISHED 2>/dev/null |
      awk '$1 == "Cursor" && ($0 ~ /->127\\.0\\.0\\.1:/ || $0 ~ /->\\[::1\\]:/)'
  else
    printf '%s\n' 'cursor=stopped'
  fi
}

install_workaround() {
  require_db
  cursor_is_running && die "Quit Cursor completely before installing the workaround"

  gate_type=$(sqlite3 "$DB" "PRAGMA query_only=ON; SELECT json_type(value, '$GATE_PATH') FROM ItemTable WHERE key='workbench.experiments.statsigBootstrap';")
  [ "$gate_type" = "true" ] || [ "$gate_type" = "false" ] ||
    die "The expected Cursor feature gate is missing; this Cursor version needs fresh analysis"

  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup="$BACKUP_DIR/statsigBootstrap-$timestamp.json"
  sqlite3 "$DB" "PRAGMA query_only=ON; SELECT value FROM ItemTable WHERE key='workbench.experiments.statsigBootstrap';" > "$backup"
  chmod 600 "$backup"

  sqlite3 "$DB" <<SQL
BEGIN IMMEDIATE;
CREATE TRIGGER IF NOT EXISTS $TRIGGER_UPDATE
AFTER UPDATE OF value ON ItemTable
WHEN NEW.key='workbench.experiments.statsigBootstrap'
 AND json_extract(NEW.value, '$GATE_PATH')=1
BEGIN
  UPDATE ItemTable
  SET value=json_set(NEW.value, '$GATE_PATH', json('false'))
  WHERE key=NEW.key;
END;
CREATE TRIGGER IF NOT EXISTS $TRIGGER_INSERT
AFTER INSERT ON ItemTable
WHEN NEW.key='workbench.experiments.statsigBootstrap'
 AND json_extract(NEW.value, '$GATE_PATH')=1
BEGIN
  UPDATE ItemTable
  SET value=json_set(NEW.value, '$GATE_PATH', json('false'))
  WHERE key=NEW.key;
END;
UPDATE ItemTable
SET value=json_set(value, '$GATE_PATH', json('false'))
WHERE key='workbench.experiments.statsigBootstrap';
DELETE FROM ItemTable
WHERE key IN ('decompose_always_local_ext_host', 'cursor_extensions_isolation_v2');
COMMIT;
SQL

  printf 'Workaround installed. Backup: %s\n' "$backup"
  status
  [ "$SKIP_LAUNCH" = "1" ] || open -a Cursor
}

remove_workaround() {
  require_db
  cursor_is_running && die "Quit Cursor completely before removing the workaround"

  sqlite3 "$DB" <<SQL
BEGIN IMMEDIATE;
DROP TRIGGER IF EXISTS $TRIGGER_UPDATE;
DROP TRIGGER IF EXISTS $TRIGGER_INSERT;
COMMIT;
SQL

  printf '%s\n' "Workaround removed. Cursor will use the server-managed gate on next launch."
}

case "${1:-status}" in
  status)
    status
    ;;
  install|repair)
    install_workaround
    ;;
  remove)
    remove_workaround
    ;;
  *)
    die "Usage: $0 {status|install|repair|remove}"
    ;;
esac
