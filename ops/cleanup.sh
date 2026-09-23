#!/usr/bin/env bash
# cleanup.sh: delete old node output so the disk does not fill.
#
# The node writes a lot: replica_cmds alone grows by around 100 GB a day,
# and every --write-* flag adds its own hourly files. This script runs
# hourly from hlnode-cleanup.timer and deletes:
#   - hourly output files (fills, misc events, trades, order statuses,
#     book diffs, twap statuses) older than CLEANUP_RETENTION_HOURS
#   - replica_cmds date folders from previous days, and files in today's
#     folder older than REPLICA_KEEP_HOURS
#   - periodic_abci_states date folders from previous days
# It never deletes a file or folder that a process still has open (lsof),
# and it never deletes the state snapshot that visor_abci_state.json
# points to, because the node loads local state from it on restart.
#
# Usage: cleanup.sh [--dry-run]

set -euo pipefail
# shellcheck source=ops/lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

RETENTION_HOURS="${CLEANUP_RETENTION_HOURS:-24}"
REPLICA_KEEP_HOURS="${REPLICA_KEEP_HOURS:-2}"
NOW=$(now)
CUTOFF=$(( NOW - RETENTION_HOURS * 3600 ))
TODAY=$(date -u +%Y%m%d)
FREED=0

# Folders the node keeps its own state in. Never touched by the hourly pass.
PROTECTED="replica_cmds periodic_abci_states periodic_abci_state_statuses"

is_open() { lsof +D "$1" >/dev/null 2>&1 || lsof "$1" >/dev/null 2>&1; }

# pointer_paths: paths named in visor_abci_state.json, one per line.
pointer_paths() {
  local f="$HL_HOME/hl/hyperliquid_data/visor_abci_state.json"
  [ -r "$f" ] || return 0
  grep -o '"/[^"]*"' "$f" | tr -d '"'
}

# remove <path> <label>: delete a file or folder and count the bytes.
remove() {
  local path="$1" label="$2" size
  size=$(du -sb "$path" 2>/dev/null | cut -f1)
  size=${size:-0}
  if $DRY_RUN; then
    log "would delete $label ($(numfmt --to=iec "$size"))"
  else
    rm -rf -- "$path"
    log "deleted $label ($(numfmt --to=iec "$size"))"
  fi
  FREED=$(( FREED + size ))
}

# date_epoch <YYYYMMDD>: start of that UTC day as epoch seconds.
date_epoch() { date -u -d "${1:0:4}-${1:4:2}-${1:6:2}" +%s 2>/dev/null; }

# clean_hour_tree <dir>: <dir>/<YYYYMMDD>/<hour>, hours are 0..23 without
# leading zeros. 10# forces base 10 so "08" and "09" are not read as octal.
clean_hour_tree() {
  local root="$1" day_dir day day_start hour_file hour file_epoch
  for day_dir in "$root"/*/; do
    [ -d "$day_dir" ] || continue
    day=$(basename "$day_dir")
    case "$day" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) continue ;; esac
    day_start=$(date_epoch "$day") || continue
    if [ $(( day_start + 86400 )) -le "$CUTOFF" ] && ! is_open "$day_dir"; then
      remove "$day_dir" "${root#"$DATA_DIR"/}/$day"
      continue
    fi
    for hour_file in "$day_dir"*; do
      [ -f "$hour_file" ] || continue
      hour=$(basename "$hour_file")
      case "$hour" in *[!0-9]*|'') continue ;; esac
      file_epoch=$(( day_start + (10#$hour + 1) * 3600 ))
      if [ "$file_epoch" -le "$CUTOFF" ] && ! is_open "$hour_file"; then
        remove "$hour_file" "${root#"$DATA_DIR"/}/$day/$hour"
      fi
    done
  done
}

# 1. Hourly output of every --write-* flag.
for type_dir in "$DATA_DIR"/*/; do
  [ -d "$type_dir" ] || continue
  name=$(basename "$type_dir")
  case " $PROTECTED " in *" $name "*) continue ;; esac
  if [ -d "$type_dir/hourly" ]; then
    clean_hour_tree "${type_dir%/}/hourly"
  else
    clean_hour_tree "${type_dir%/}"
  fi
done

# 2. replica_cmds/<start_time>/<YYYYMMDD>/<height>: previous days, then
#    files older than REPLICA_KEEP_HOURS inside today's folder.
if [ -d "$DATA_DIR/replica_cmds" ]; then
  for run_dir in "$DATA_DIR"/replica_cmds/*/; do
    [ -d "$run_dir" ] || continue
    for day_dir in "$run_dir"*/; do
      [ -d "$day_dir" ] || continue
      day=$(basename "$day_dir")
      [ "$day" = "$TODAY" ] && continue
      is_open "$day_dir" || remove "$day_dir" "replica_cmds/$(basename "$run_dir")/$day"
    done
    if [ -d "$run_dir$TODAY" ]; then
      while IFS= read -r f; do
        is_open "$f" || remove "$f" "replica_cmds/$(basename "$run_dir")/$TODAY/$(basename "$f")"
      done < <(find "$run_dir$TODAY" -maxdepth 1 -type f -mmin +$(( REPLICA_KEEP_HOURS * 60 )) 2>/dev/null)
    fi
  done
fi

# 3. periodic_abci_states/<YYYYMMDD>/: previous days, except any folder
#    that holds the snapshot visor_abci_state.json points to.
if [ -d "$DATA_DIR/periodic_abci_states" ]; then
  keep=$(pointer_paths)
  for day_dir in "$DATA_DIR"/periodic_abci_states/*/; do
    [ -d "$day_dir" ] || continue
    day=$(basename "$day_dir")
    [ "$day" = "$TODAY" ] && continue
    if [ -n "$keep" ] && printf '%s\n' "$keep" | grep -qF "${day_dir%/}"; then
      log "keeping periodic_abci_states/$day (the state pointer uses it)"
      continue
    fi
    is_open "$day_dir" || remove "$day_dir" "periodic_abci_states/$day"
  done
fi

log "freed $(numfmt --to=iec "$FREED")$($DRY_RUN && echo ' (dry run)'), disk $(df -P "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $5}') used"
