# hyperliquid-node-kit

Scripts to install and run a Hyperliquid mainnet non-validator node on Ubuntu, plus a read-only MCP server so an AI agent can read from your own node.

It is what we run on our own nodes, cut down to the parts that apply to any node. MIT licensed.

## What it installs

- The node supervisor (visor) from `binaries.hyperliquid.xyz`, with its GPG signature checked against the key published in the [official node repo](https://github.com/hyperliquid-dex/node).
- A node user (`hl`), `visor.json` for Mainnet, and `override_gossip_config.json` built from the published root peers.
- A systemd service, `hlnode`, that runs `run-non-validator` with the flags in `/etc/hlkit.env`.
- Three systemd timers: disk cleanup (hourly), lag watchdog (every 5 minutes) and peer refresh (daily).
- A firewall rule for TCP 4001-4002, the gossip ports.

The installer does not enable ufw for you. Enabling it before allowing SSH locks you out.

## Requirements

- Ubuntu 24.04. The official node README supports only this version. The installer warns on anything else.
- 16 vCPUs (8 cores / 16 threads, high clock speed) and 128 GB RAM, as the official node README lists. The node uses around 40 GB normally, and memory climbs fast under network stress. 64 GB gets tight.
- About 2 TB of NVMe. The node writes around 100 GB a day with default flags, and more with each `--write-*` flag. The cleanup timer keeps it bounded.
- TCP 4001 and 4002 open to the internet. Peers deprioritize nodes they cannot reach.
- A server close to the root peers syncs faster. Most of them are in Tokyo.

## Quick start

```bash
git clone https://github.com/ironflowsh/hyperliquid-node-kit /root/hlkit
cd /root/hlkit
sudo ./install.sh --dry-run   # print every step
sudo ./install.sh
journalctl -u hlnode -f       # follow the first sync
/opt/hlkit/ops/health.sh      # {"lag_seconds":8,...}
```

The first sync downloads a state snapshot of several hundred MB from a peer. It takes 10 to 30 minutes. Do not restart during it: every restart starts the download again.

Clone the repo into a folder whose path does not contain the node's program names (see "The program-name rule" below). The installer refuses to run from such a path.

## Configuration

Everything lives in `/etc/hlkit.env`. See `config/hlkit.env.example` for every setting and its default. The main ones:

| Setting | Default | What it does |
|---|---|---|
| `NODE_FLAGS` | `--serve-info --write-fills --write-misc-events --disable-output-file-buffering` | Flags for `run-non-validator` |
| `CLEANUP_RETENTION_HOURS` | 24 | Hourly output older than this is deleted |
| `WATCHDOG_LAG_THRESHOLD` | 600 | Seconds behind the chain before a restart |
| `WATCHDOG_COOLDOWN_SECONDS` | 900 | Minimum time between restarts |
| `WATCHDOG_FAILURE_BUDGET` | 3 | Restarts in a row before the watchdog stops and alerts |
| `PEERS_KEEP` | 16 | Root peers written to the peer config |
| `ALERT_WEBHOOK_URL` | empty | Slack-compatible webhook for watchdog alerts |

After changing `NODE_FLAGS`, run `sudo systemctl restart hlnode`.

## Ops scripts

All scripts take `--dry-run` where they change something.

- `ops/cleanup.sh` deletes hourly output older than the retention, `replica_cmds` folders from previous days, and old `periodic_abci_states` folders. It skips anything a process still has open, and it never deletes the state snapshot that `visor_abci_state.json` points to, so a restart can load local state instead of downloading it again.
- `ops/watchdog.sh` measures lag as wall clock minus the L1 time of the node's local state (the `exchangeStatus` request on the local info server). It restarts only when lag is over the threshold, never during the startup grace or a state download, at most once per cooldown, and stops after the failure budget with an alert. Restarting in a loop makes a slow node slower.
- `ops/refresh-peers.sh` fetches the root peers from the public `gossipRootIps` request, measures TCP connect time to port 4001 on each one from this host, and keeps the fastest. The node reads the file on its next start.
- `ops/health.sh` prints `{"lag_seconds","latest_block_time","disk_used_pct","child_running"}` and exits 1 when lag is unknown or over the threshold, so an uptime monitor can use it.

## The program-name rule

The node supervisor scans running processes when it starts and panics if another process has its name, or its child's name, in the command line. A `pgrep`, an alert payload or a script path containing those names is enough to crash it on the next start. The scripts here build the names from parts, walk `/proc` instead of calling `pgrep`, use a service called `hlnode`, and install to `/opt/hlkit`. Keep to the same rule in anything you add.

## MCP server

`mcp/` is `hlnode-mcp`, a read-only [MCP](https://modelcontextprotocol.io) server that lets Claude, Cursor or any MCP client read from your node's local info server. There is no public rate limit on your own node, and nothing leaves the machine except the answers.

It never signs, places or cancels orders.

| Tool | Info request |
|---|---|
| `get_clearinghouse_state(user, dex?)` | `clearinghouseState` |
| `get_spot_state(user)` | `spotClearinghouseState` |
| `get_open_orders(user, dex?)` | `openOrders` |
| `get_frontend_open_orders(user, dex?)` | `frontendOpenOrders` |
| `get_meta(dex?)` | `meta` |
| `get_user_abstraction(user)` | `userAbstraction` |
| `node_health()` | `exchangeStatus`, returns lag and `stale` |

`dex` is a HIP-3 builder dex name, for example `xyz`.

The local info server answers only requests that depend on local state. `allMids`, `l2Book`, `userFills`, `portfolio` and `metaAndAssetCtxs` return 422 there, so the server does not offer them. Use the public API for those.

Build:

```bash
cd mcp
npm ci
npm test
npm run build
```

The paths below assume the repo is at `/root/hlkit`. As with the ops scripts, keep the node's program names out of the path, because the running server's command line contains it.

Claude Code:

```bash
claude mcp add hlnode -- node /root/hlkit/mcp/dist/index.js
```

Claude Desktop (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "hlnode": {
      "command": "node",
      "args": ["/root/hlkit/mcp/dist/index.js"],
      "env": { "HL_INFO_URL": "http://localhost:3001/info" }
    }
  }
}
```

If the agent runs on another machine, reach the info server through an SSH tunnel (`ssh -L 3001:localhost:3001 your-node`). Port 3001 has no authentication, so do not open it to the internet.

Env: `HL_INFO_URL` (default `http://localhost:3001/info`), `HL_MAX_LAG_SECONDS` (default 60, above it `node_health` reports `stale: true`).

## Troubleshooting

The node guide lists the common log errors with causes and fixes:
https://ironflow.sh/guides/run-hyperliquid-node?utm_source=github&utm_campaign=node-kit#errors

- Stuck downloading state, `early eof`, `abci_stream ... timed out`: peers too slow or too far. Run `ops/refresh-peers.sh`, check that 4001-4002 are open, and let it run without restarts.
- `missing file: .../visor_abci_state.json` on the first start is normal. The node creates it after the first sync.
- Falling behind while CPU is idle: the usual cause is a slow upstream peer. See the gossip section of the guide.

## Managed option

If you would rather not run it yourself, we run dedicated nodes in Tokyo with an indexed data layer on top:
https://ironflow.sh/nodes?utm_source=github&utm_campaign=node-kit

## License

MIT, see [LICENSE](LICENSE).
