#!/usr/bin/env bash
# install.sh: set up a Hyperliquid mainnet non-validator node on Ubuntu,
# with the ops timers from this kit.
#
# What it does, in order:
#   1. installs curl, gnupg, jq, lsof and ufw
#   2. creates the node user (default: hl)
#   3. writes /etc/hlkit.env from config/hlkit.env.example (kept if present)
#   4. writes visor.json for Mainnet in the node user's home
#   5. imports Hyperliquid's signing key, downloads the visor binary and its
#      signature from binaries.hyperliquid.xyz, and verifies the signature
#   6. copies ops/ to /opt/hlkit and writes override_gossip_config.json
#      from the published root peers
#   7. opens TCP 4001-4002 in ufw (gossip; peers deprioritize nodes they
#      cannot reach)
#   8. installs the hlnode service and the cleanup, watchdog and peer
#      timers, then starts them
#
# Safe to run again: it keeps existing config, skips the download when a
# verified binary is present, and only rewrites files it owns.
#
# Usage: sudo ./install.sh [--dry-run]

set -euo pipefail

KIT_SRC="$(dirname "$(readlink -f "$0")")"
# shellcheck source=ops/lib.sh
. "$KIT_SRC/ops/lib.sh"

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

KIT_DIR=/opt/hlkit
ENV_TARGET=/etc/hlkit.env
BIN_BASE="https://binaries.hyperliquid.xyz/Mainnet"
KEY_URL="https://raw.githubusercontent.com/hyperliquid-dex/node/main/pub_key.asc"

step() { echo; echo "==> $*"; }
run() {
  if $DRY_RUN; then echo "   [dry-run] $*"; else "$@"; fi
}

# --- Checks ---

if [ "$(id -u)" -ne 0 ] && ! $DRY_RUN; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

# The folder this runs from ends up in the argv of every process it
# starts. If it contains the node's program names, the supervisor panics
# when it starts (see ops/lib.sh). Refuse early.
case "$KIT_SRC" in
  *"$SUPERVISOR_NAME"*|*"$CHILD_NAME"*)
    echo "This folder's path contains a name the node supervisor reacts to:" >&2
    echo "  $KIT_SRC" >&2
    echo "Move or rename it (for example to /root/hlkit) and run it again." >&2
    exit 1 ;;
esac

if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    echo "Ubuntu is required (found ${ID:-unknown})." >&2
    exit 1
  fi
  if [ "${VERSION_ID:-}" != "24.04" ]; then
    echo "Warning: the official node README supports Ubuntu 24.04 only; found ${VERSION_ID:-unknown}."
  fi
fi

# --- 1. Packages ---
step "1/8 Installing packages"
run apt-get update -qq
run apt-get install -y -qq curl gnupg jq lsof ufw ca-certificates

# --- 2. User ---
step "2/8 Node user: $HL_USER ($HL_HOME)"
if id "$HL_USER" >/dev/null 2>&1; then
  echo "   exists"
else
  run useradd --create-home --home-dir "$HL_HOME" --shell /bin/bash "$HL_USER"
fi

# --- 3. Config ---
step "3/8 Config: $ENV_TARGET"
if [ -f "$ENV_TARGET" ]; then
  echo "   exists, keeping it"
else
  run install -m 0644 "$KIT_SRC/config/hlkit.env.example" "$ENV_TARGET"
  if ! $DRY_RUN; then
    sed -i "s|^HL_USER=.*|HL_USER=$HL_USER|; s|^HL_HOME=.*|HL_HOME=$HL_HOME|" "$ENV_TARGET"
  fi
fi

# --- 4. Chain ---
step "4/8 Chain: Mainnet ($HL_HOME/visor.json)"
if ! $DRY_RUN; then
  echo '{"chain": "Mainnet"}' > "$HL_HOME/visor.json"
  chown "$HL_USER:$HL_USER" "$HL_HOME/visor.json"
else
  echo "   [dry-run] write {\"chain\": \"Mainnet\"}"
fi

# --- 5. Binary ---
step "5/8 Visor binary, signature check"
BIN="$HL_HOME/$SUPERVISOR_NAME"
as_hl() { run sudo -u "$HL_USER" -H "$@"; }
as_hl bash -c "curl -fsSL '$KEY_URL' | gpg --batch --import"
if [ -x "$BIN" ] && ! $DRY_RUN; then
  echo "   binary present; the visor keeps it updated itself"
else
  tmp=$(mktemp -d)
  run curl -fsSL -o "$tmp/bin" "$BIN_BASE/$SUPERVISOR_NAME"
  run curl -fsSL -o "$tmp/bin.asc" "$BIN_BASE/$SUPERVISOR_NAME.asc"
  run chown -R "$HL_USER:$HL_USER" "$tmp"
  if ! as_hl gpg --batch --verify "$tmp/bin.asc" "$tmp/bin"; then
    echo "Signature check FAILED. Not installing the binary." >&2
    rm -rf "$tmp"
    exit 1
  fi
  run install -o "$HL_USER" -g "$HL_USER" -m 0755 "$tmp/bin" "$BIN"
  rm -rf "$tmp"
  if $DRY_RUN; then
    echo "   [dry-run] signature check skipped"
  else
    echo "   signature OK"
  fi
fi

# --- 6. Ops scripts and peers ---
step "6/8 Ops scripts in $KIT_DIR, root peers"
run install -d "$KIT_DIR/ops"
run install -m 0755 "$KIT_SRC"/ops/*.sh "$KIT_DIR/ops/"
run install -d -m 0755 "$STATE_DIR"
if $DRY_RUN; then
  echo "   [dry-run] $KIT_DIR/ops/refresh-peers.sh"
else
  "$KIT_DIR/ops/refresh-peers.sh"
fi

# --- 7. Firewall ---
step "7/8 Firewall: TCP 4001-4002"
run ufw allow 4001:4002/tcp
if ! $DRY_RUN && ! ufw status | grep -q "Status: active"; then
  echo "   ufw is not active. The rule is saved. Enabling ufw is left to you,"
  echo "   because doing it before allowing SSH locks you out."
fi

# --- 8. Services ---
step "8/8 systemd units"
if ! $DRY_RUN; then
  sed -e "s|@HL_HOME@|$HL_HOME|g" -e "s|@HL_USER@|$HL_USER|g" \
    "$KIT_SRC/systemd/hlnode.service.template" > /etc/systemd/system/hlnode.service
else
  echo "   [dry-run] render hlnode.service"
fi
for u in hlnode-cleanup hlnode-watchdog hlnode-peers; do
  run install -m 0644 "$KIT_SRC/systemd/$u.service" "$KIT_SRC/systemd/$u.timer" /etc/systemd/system/
done
run systemctl daemon-reload
run systemctl enable --now hlnode-cleanup.timer hlnode-watchdog.timer hlnode-peers.timer
run systemctl enable hlnode
# --no-block: this script has exited before the supervisor scans processes.
run systemctl --no-block start hlnode

echo
echo "Done. The first sync downloads state from a peer and takes 10 to 30 minutes."
echo "  Follow the log:   journalctl -u hlnode -f"
echo "  Check health:     $KIT_DIR/ops/health.sh"
