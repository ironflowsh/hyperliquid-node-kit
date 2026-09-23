#!/usr/bin/env bash
# health.sh: print one JSON line with the node's state.
#   lag_seconds        wall clock minus the L1 time of local state (null if
#                      the info server does not answer)
#   latest_block_time  that L1 time, ISO 8601 UTC
#   disk_used_pct      use of the disk that holds the data folder
#   child_running      whether the node's child process exists
# Exit code 0 when lag is known and under WATCHDOG_LAG_THRESHOLD, else 1,
# so it works as a check in cron or an uptime monitor.

set -euo pipefail
# shellcheck source=ops/lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

body=$(info_post '{"type":"exchangeStatus"}' 2>/dev/null || true)
ms=$(printf '%s' "$body" | sed -n 's/.*"time":\([0-9][0-9]*\).*/\1/p')

if [ -n "$ms" ]; then
  lag=$(( $(now) - ms / 1000 ))
  block_time="\"$(date -u -d "@$(( ms / 1000 ))" +%Y-%m-%dT%H:%M:%SZ)\""
else
  lag=null
  block_time=null
fi

disk=$(df -P "$DATA_DIR" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
disk=${disk:-null}
if child_running; then child=true; else child=false; fi

printf '{"lag_seconds":%s,"latest_block_time":%s,"disk_used_pct":%s,"child_running":%s}\n' \
  "$lag" "$block_time" "$disk" "$child"

[ "$lag" != "null" ] && [ "$lag" -le "${WATCHDOG_LAG_THRESHOLD:-600}" ]
