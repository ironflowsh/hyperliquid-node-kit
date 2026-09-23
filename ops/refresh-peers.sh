#!/usr/bin/env bash
# refresh-peers.sh: rewrite override_gossip_config.json from the current
# list of root peers.
#
# Hyperliquid publishes its root gossip peers through the public info
# call {"type":"gossipRootIps"}. The list changes over time, and a node
# that keeps dead or distant peers syncs slower and falls behind more
# often. This script runs daily from hlnode-peers.timer:
#   1. fetches the list
#   2. optionally measures TCP connect time to port 4001 on each peer from
#      this host and sorts by it (PEERS_SORT_BY_LATENCY=1)
#   3. keeps the first PEERS_KEEP reachable peers
#   4. writes the file atomically, owned by the node user
# The node reads the file when it starts. The new list is used from the
# next start; this script does not restart the node.
#
# Usage: refresh-peers.sh [--dry-run]

set -euo pipefail
# shellcheck source=ops/lib.sh
. "$(dirname "$(readlink -f "$0")")/lib.sh"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

KEEP="${PEERS_KEEP:-16}"
SORT="${PEERS_SORT_BY_LATENCY:-1}"
PUBLIC_INFO="${PUBLIC_INFO_URL:-https://api.hyperliquid.xyz/info}"
TARGET="$HL_HOME/override_gossip_config.json"
CONNECT_TIMEOUT=2

ips=$(curl -sf -X POST "$PUBLIC_INFO" -H 'Content-Type: application/json' \
  -d '{"type":"gossipRootIps"}' --max-time 15 \
  | jq -r '.[]' | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)
count=$(printf '%s\n' "$ips" | grep -c . || true)
if [ "$count" -lt 3 ]; then
  log "got ${count} root peers from the public API, expected more; leaving $TARGET unchanged"
  exit 1
fi
log "public API lists ${count} root peers"

# connect_ms <ip>: TCP connect time to <ip>:4001 in ms, or nothing.
connect_ms() {
  local start end
  start=$(date +%s%N)
  if timeout "$CONNECT_TIMEOUT" bash -c "exec 3<>/dev/tcp/$1/4001" 2>/dev/null; then
    end=$(date +%s%N)
    echo $(( (end - start) / 1000000 ))
  fi
}

if [ "$SORT" = "1" ]; then
  ranked=""
  while IFS= read -r ip; do
    ms=$(connect_ms "$ip")
    if [ -n "$ms" ]; then
      ranked+="$ms $ip"$'\n'
    else
      log "no answer on 4001: $ip"
    fi
  done <<< "$ips"
  chosen=$(printf '%s' "$ranked" | sort -n | head -n "$KEEP" | awk '{print $2}')
  printf '%s' "$ranked" | sort -n | head -n "$KEEP" | while read -r ms ip; do log "keep ${ip} ${ms} ms"; done
else
  chosen=$(printf '%s\n' "$ips" | head -n "$KEEP")
fi

kept=$(printf '%s\n' "$chosen" | grep -c . || true)
if [ "$kept" -lt 3 ]; then
  log "only ${kept} peers answered; leaving $TARGET unchanged"
  exit 1
fi

config=$(printf '%s\n' "$chosen" | jq -R . | jq -s \
  '{root_node_ips: map({Ip: .}), try_new_peers: true, chain: "Mainnet", reserved_peer_ips: []}')

if $DRY_RUN; then
  log "would write ${kept} peers to $TARGET:"
  echo "$config"
  exit 0
fi

tmp=$(mktemp "$TARGET.XXXXXX")
printf '%s\n' "$config" > "$tmp"
chown "$HL_USER:$HL_USER" "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$TARGET"
log "wrote ${kept} peers to $TARGET (used from the next node start)"
