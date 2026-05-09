# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Shell script telemetry collection for MeshCore LoRa mesh nodes. Scripts are run by Telegraf on a Linux host (typically a Raspberry Pi) with a MeshCore node connected via USB at `/dev/meshcore0`. Output is InfluxDB line protocol on stdout, consumed by Telegraf's `exec` input plugin.

Dependencies: `meshcore-cli` (at `/usr/local/bin/meshcore-cli`), `jq`, `shuf`, `timeout`.

## Scripts

| Script | Purpose | Telegraf interval |
|---|---|---|
| `mc_trace.sh` | Multi-hop trace SNR metrics for each destination | 15m |
| `mc_status.sh` | Node status snapshots (battery, RSSI, SNR, counters) | 15m (offset 7m30s) |
| `mc_neighbours.sh` | RF neighbour table per node | 15m (offset 3m45s) |
| `mc_discover.sh` | Directly-heard nodes from gateway (SNR, RSSI, SNR_in) | 2m |
| `mc_advert_age.sh` | Time since last advertisement per contact (detect fast advertisers) | 1h |
| `mc_refresh_login.sh` | Re-authenticate to all contacts (run manually when needed) | — |
| `mc_star_contacts.sh` | Mark STATUS_CONTACTS as starred so they are not pruned (run manually) | — |

## Contact flags

`change_flags <contact> <int>` takes a bitmask integer. Known values (not documented in meshcore-cli source — confirmed by testing):
- `1` = star (favourite) — prevents contact from being pruned
- `2` = tel_l (telemetry location) — unconfirmed
- `4` = tel_a (telemetry ambient) — unconfirmed

## Running scripts

```bash
DEBUG=1 ./mc_trace.sh
DEBUG=1 ./mc_status.sh
BATCH_SIZE=1 DEBUG=1 ./mc_trace.sh
QUERY_DELAY=15 DEBUG=1 ./mc_status.sh
sudo -u telegraf /usr/local/bin/mc_trace.sh
export MESH_PASSWORD='...' && ./mc_refresh_login.sh
```

## Telegraf / service testing

```bash
sudo telegraf --test --config /etc/telegraf/telegraf.conf
sudo systemctl restart telegraf
journalctl -u telegraf -f
```

## Deployment

```bash
sudo ./deploy.sh   # installs scripts to /usr/local/bin
```

InfluxDB credentials are passed via `INFLUX_HOST` and `INFLUX_TOKEN` in `/etc/default/telegraf`, loaded via the systemd `EnvironmentFile=-/etc/default/telegraf` drop-in.

The serial device uses a stable udev symlink `/dev/meshcore0`.

## Grafana dashboards

Dashboard JSON files live in `dashboards/`, stored in Grafana v13 k8s API v2 format. Organised into two Grafana folders:

- **Nodes** — status metrics from managed nodes (battery, RSSI, SNR, noise floor)
- **Traces** — link test results to remote repeaters (SNR, success/failure rates, duration)

```bash
GRAFANA_TOKEN=glsa_... ./sync_dashboards.sh --push   # push local changes to Grafana
GRAFANA_TOKEN=glsa_... ./sync_dashboards.sh --pull   # pull from Grafana
```

`sync_dashboards.sh` uses a hybrid approach: classic Grafana API (`/api/dashboards/db`) to create new dashboards (so they are properly indexed), then the k8s API (`/apis/dashboard.grafana.app/v2/...`) to PUT full content. Requires a service account token with Editor role.

Dashboard filenames starting with `grafana_trace_`, `grafana_mesh_reliability_`, or `grafana_failure_reasons_` are assigned to the Traces folder; all others go to Nodes.

## Architecture

### Output format

All metric output is InfluxDB line protocol. Two measurements:
- `meshcore_trace` — one line per hop, field `snr`
- `meshcore_status` — one line per node, 17 integer/float fields

Both share tags `ver`, `model`, `radio_freq`, `radio_bw`, `radio_sf`, `radio_cr` fetched once per run via `meshcore-cli ver` and `meshcore-cli infos`.

### Trace script flow (`mc_trace.sh`)

Paths are generated as `e2,<node>,e2` and `2f,<node>,2f` for each destination, shuffled, then batched (default 3). Each batch issues multiple `trace` subcommands in a single `meshcore-cli` call. Responses are assumed to be returned in request order — if MeshCore changes this, the batch correlation logic must be revisited.

Missing traces produce no output — absence of data means unreachable/timeout, by design.

### Status script flow (`mc_status.sh`)

Sequentially polls each contact using `req_status`. Handles three error cases silently (logged in DEBUG mode): empty response, `unknown contact`, `Getting data`. Inter-query delay is `QUERY_DELAY` (default 5s) plus random jitter up to 2s.

`req_status` requires monitored nodes to exist in the local contact database. Run `mc_refresh_login.sh` after a node is reflashed.

## Design principles

- Simple shell, no heavy tooling
- Low mesh impact — missing data preferred over aggressive polling or synthetic failure metrics
- Long-term RF experiment metadata tagged on every measurement
- Scripts are meant to be boring and inspectable
- Grafana dashboards use `createEmpty:false` and `insertNulls:900000` — gaps in graphs are intentional and show unreachable nodes
</thinking>
