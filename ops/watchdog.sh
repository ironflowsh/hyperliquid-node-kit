#!/usr/bin/env bash
# watchdog.sh: restart the node when it falls behind the chain, carefully.
#
# Runs every 5 minutes from hlnode-watchdog.timer. It measures lag as the
# difference between wall clock and the L1 time of the node's local state
# (the exchangeStatus request on the local info server). When the info
# server does not answer, it falls back to the age of the newest output
# file. A process that is alive but behind is the common failure, so lag
# is what matters, not whether the process exists.
#
# Restart rules, because a careless restart makes things worse:
#   - no restarts in the first WATCHDOG_STARTUP_GRACE seconds after the
#     service starts, and none while the log shows a state download
#     (every restart starts that download again)
#   - at most one restart per WATCHDOG_COOLDOWN_SECONDS
#   - after WATCHDOG_FAILURE_BUDGET restarts in a row that did not bring
#     the lag down, it stops restarting and alerts. A person looks at it.
#   - systemctl --no-block, so the systemctl client has exited before the
#     supervisor starts and scans the process list (see ops/lib.sh).
#
# Usage: watchdog.sh [--dry-run]

set -euo pipefail
# shellcheck source=ops/lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

LAG_THRESHOLD="${WATCHDOG_LAG_THRESHOLD:-600}"
COOLDOWN="${WATCHDOG_COOLDOWN_SECONDS:-900}"
BUDGET="${WATCHDOG_FAILURE_BUDGET:-3}"
STARTUP_GRACE="${WATCHDOG_STARTUP_GRACE:-1800}"

mkdir -p "$STATE_DIR"
LAST_RESTART_FILE="$STATE_DIR/watchdog-last-restart"
STRIKES_FILE="$STATE_DIR/watchdog-strikes"
HALT_FILE="$STATE_DIR/watchdog-halted"

read_state() { if [ -f "$1" ]; then cat "$1"; else echo "$2"; fi; }

if ! systemctl is-active --quiet "$UNIT"; then
  log "service $UNIT is not active; systemd restarts it (Restart=always), nothing to do"
  exit 0
fi

# Time since the service (re)started.
started=$(systemctl show -p ActiveEnterTimestamp --value "$UNIT")
started_epoch=$(date -d "$started" +%s 2>/dev/null || echo 0)
uptime=$(( $(now) - started_epoch ))
if [ "$uptime" -lt "$STARTUP_GRACE" ]; then
  log "service up ${uptime}s, inside the ${STARTUP_GRACE}s startup grace, skipping"
  exit 0
fi

# State download in progress? These are the node's own log lines while it
# fetches a state snapshot from a peer. grep -c instead of grep -q so the
# pipe is never cut short under pipefail.
downloading=$(journalctl -u "$UNIT" --since "-3min" --no-pager -o cat 2>/dev/null \
  | grep -ciE 'abci_stream greeting|abci state|downloading' || true)
if [ "${downloading:-0}" -gt 0 ]; then
  log "state download in progress (${downloading} log lines in 3 min), skipping"
  exit 0
fi

lag=$(chain_lag_seconds)
source_note="exchangeStatus"
if [ -z "$lag" ]; then
  lag=$(newest_output_age_seconds)
  source_note="newest output file"
fi
if [ -z "$lag" ]; then
  log "no lag signal (info server silent, no output files yet), skipping"
  exit 0
fi

if child_running; then child="running"; else child="not running"; fi

if [ "$lag" -le "$LAG_THRESHOLD" ]; then
  if [ "$(read_state "$STRIKES_FILE" 0)" -gt 0 ] || [ -f "$HALT_FILE" ]; then
    log "lag back to ${lag}s, clearing restart strikes"
    rm -f "$STRIKES_FILE" "$HALT_FILE"
  fi
  log "ok: lag ${lag}s (${source_note}), child ${child}"
  exit 0
fi

log "behind: lag ${lag}s > ${LAG_THRESHOLD}s (${source_note}), child ${child}"

if [ -f "$HALT_FILE" ]; then
  log "halted after ${BUDGET} restarts; delete $HALT_FILE after fixing the cause"
  exit 1
fi

last=$(read_state "$LAST_RESTART_FILE" 0)
since_last=$(( $(now) - last ))
if [ "$since_last" -lt "$COOLDOWN" ]; then
  log "last restart ${since_last}s ago, cooldown ${COOLDOWN}s, waiting"
  exit 0
fi

strikes=$(read_state "$STRIKES_FILE" 0)
if [ "$strikes" -ge "$BUDGET" ]; then
  touch "$HALT_FILE"
  alert "node still ${lag}s behind after ${strikes} restarts. Watchdog stopped restarting. Check peers and the service log."
  exit 1
fi

if $DRY_RUN; then
  log "would restart $UNIT (strike $(( strikes + 1 ))/${BUDGET})"
  exit 0
fi

systemctl --no-block restart "$UNIT"
now > "$LAST_RESTART_FILE"
echo $(( strikes + 1 )) > "$STRIKES_FILE"
alert "node ${lag}s behind, restarted it (restart $(( strikes + 1 )) of ${BUDGET}). The state download takes 10 to 30 minutes."
