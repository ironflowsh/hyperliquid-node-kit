#!/usr/bin/env bash
# Shared helpers for the ops scripts. Sourced, not run.
#
# Program-name rule: the node's supervisor scans running processes when it
# starts and panics if another process has its own name or its child's
# name in the command line. A pgrep, an alert payload or a script path
# with those words is enough. So no script in this kit, and no command it
# runs, contains either name as a literal. Where the names are needed they
# are built from the parts below at run time, and they are only compared
# against /proc/<pid>/comm, which never puts them into an argv.
#
# The same goes for file paths: a script run as /opt/<name>/x.sh puts the
# path in its argv. That is why the kit installs to /opt/hlkit, reads
# /etc/hlkit.env and keeps state in /var/lib/hlkit.

_HL_A="hl"
_HL_S="visor"
_HL_C="node"
# shellcheck disable=SC2034  # used by the scripts that source this file
SUPERVISOR_NAME="${_HL_A}-${_HL_S}"
# shellcheck disable=SC2034
CHILD_NAME="${_HL_A}-${_HL_C}"

# The systemd unit is called hlnode, which contains neither name.
# shellcheck disable=SC2034
UNIT="hlnode"

ENV_FILE="${HLKIT_ENV:-/etc/hlkit.env}"
if [ -r "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$ENV_FILE"
fi

HL_USER="${HL_USER:-hl}"
HL_HOME="${HL_HOME:-/home/$HL_USER}"
DATA_DIR="${DATA_DIR:-$HL_HOME/hl/data}"
STATE_DIR="${STATE_DIR:-/var/lib/hlkit}"
INFO_URL="${INFO_URL:-http://localhost:3001/info}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
now() { date +%s; }

# info_post <json>: POST one request to the local info server, 5 s timeout.
info_post() {
  curl -sf -X POST "$INFO_URL" -H 'Content-Type: application/json' \
    -d "$1" --max-time 5
}

# chain_lag_seconds: seconds between wall clock and the L1 time of the
# node's local state, from the exchangeStatus request (served locally).
# Prints nothing when the info server does not answer.
chain_lag_seconds() {
  local body ms
  body=$(info_post '{"type":"exchangeStatus"}' 2>/dev/null) || return 0
  ms=$(printf '%s' "$body" | sed -n 's/.*"time":\([0-9][0-9]*\).*/\1/p')
  [ -n "$ms" ] || return 0
  echo $(( $(now) - ms / 1000 ))
}

# newest_output_age_seconds: age of the most recently modified file under
# the data folder's hourly output. A fallback when the info server is off.
newest_output_age_seconds() {
  local newest
  newest=$(find "$DATA_DIR" -path '*/hourly/*' -type f -printf '%T@\n' 2>/dev/null \
    | sort -n | tail -1)
  [ -n "$newest" ] || return 0
  echo $(( $(now) - ${newest%.*} ))
}

# child_running: true when a process whose comm is the child's name exists.
# Walks /proc instead of calling pgrep, see the program-name rule above.
child_running() {
  local entry comm
  for entry in /proc/[0-9]*/comm; do
    [ -r "$entry" ] || continue
    read -r comm < "$entry" 2>/dev/null || continue
    [ "$comm" = "$CHILD_NAME" ] && return 0
  done
  return 1
}

# alert <text>: post to ALERT_WEBHOOK_URL when set. The text must not
# contain the program names (see the rule at the top of this file).
alert() {
  log "ALERT: $1"
  [ -n "$ALERT_WEBHOOK_URL" ] || return 0
  local payload
  payload=$(printf '{"text":"%s: %s"}' "$(hostname)" "$1")
  curl -s -X POST "$ALERT_WEBHOOK_URL" -H 'Content-Type: application/json' \
    -d "$payload" --max-time 5 >/dev/null 2>&1 || log "alert delivery failed"
}
