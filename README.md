# MeshCore Telemetry

Shell script telemetry for MeshCore LoRa mesh nodes. Scripts run under Telegraf on a Raspberry Pi with a MeshCore node connected via USB. Output is InfluxDB line protocol. Grafana dashboards are synced via `sync_dashboards.sh`.

## Scripts

| Script | Purpose | Interval |
|---|---|---|
| `mc_trace.sh` | Multi-hop trace SNR per destination | 15m |
| `mc_status.sh` | Node status snapshots (battery, RSSI, SNR, counters) | 15m (offset 7m30s) |
| `mc_refresh_login.sh` | Re-authenticate to all contacts | manual |

## Setup

```bash
# Install scripts
sudo ./deploy.sh

# Set InfluxDB token
echo "INFLUX_TOKEN=..." | sudo tee /etc/telegraf/telegraf.env
sudo chown root:telegraf /etc/telegraf/telegraf.env
sudo chmod 640 /etc/telegraf/telegraf.env
```

The serial device uses a stable udev symlink at `/dev/meshcore0`. The connected node must be configured as a **serial companion**, not a repeater.

## Dashboards

Grafana dashboards live in `dashboards/`, split into two folders:

- **Nodes** — battery, RSSI, SNR, noise floor, RF link health
- **Traces** — trace SNR, success/failure rates, duration, reliability trend

```bash
# Push local changes to Grafana
GRAFANA_TOKEN=glsa_... ./sync_dashboards.sh --push

# Pull latest from Grafana
GRAFANA_TOKEN=glsa_... ./sync_dashboards.sh --pull
```

Requires a Grafana service account token with Editor role.

## Running manually

```bash
DEBUG=1 ./mc_trace.sh
DEBUG=1 ./mc_status.sh

# Single-path trace
BATCH_SIZE=1 DEBUG=1 ./mc_trace.sh

# Longer status delay
QUERY_DELAY=15 DEBUG=1 ./mc_status.sh

# Run as telegraf user
sudo -u telegraf /usr/local/bin/mc_trace.sh

# Refresh logins (required after node reflash)
export MESH_PASSWORD='...'
./mc_refresh_login.sh
```

## Telegraf

```bash
sudo telegraf --test --config /etc/telegraf/telegraf.conf
sudo systemctl restart telegraf
journalctl -u telegraf -f
```

Example exec inputs:

```toml
[[inputs.exec]]
  commands = ["/usr/local/bin/mc_trace.sh"]
  interval = "15m"
  timeout = "4m"
  ignore_error = true
  data_format = "influx"

[[inputs.exec]]
  commands = ["/usr/local/bin/mc_status.sh"]
  interval = "15m"
  collection_offset = "7m30s"
  timeout = "2m"
  ignore_error = true
  data_format = "influx"
```

## Measurements

### `meshcore_trace`

Tags: `site`, `path`, `from`, `to`, `ver`, `model`, `radio_freq`, `radio_bw`, `radio_sf`, `radio_cr`
Fields: `snr`

### `meshcore_status`

Tags: `node`, `ver`, `model`, `radio_freq`, `radio_bw`, `radio_sf`, `radio_cr`
Fields: `bat`, `last_rssi`, `last_snr`, `noise_floor`, `airtime`, `rx_airtime`, `uptime`, `nb_recv`, `nb_sent`, `sent_flood`, `sent_direct`, `recv_flood`, `recv_direct`, `tx_queue_len`, `full_evts`, `direct_dups`, `flood_dups`

## Notes

- Missing traces produce no output — absence of data means unreachable, by design
- Trace batching assumes `meshcore-cli` returns responses in request order
- `req_status` requires monitored nodes to exist in the local contact database; run `mc_refresh_login.sh` after a node is reflashed
- RF and firmware tags are collected intentionally for long-term experiment correlation
