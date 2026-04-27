# MeshCore Telegraf Monitoring

Lightweight telemetry collection for MeshCore nodes using custom scripts, Telegraf and InfluxDB.

This setup collects two kinds of data:

* **Trace telemetry** (`mc_trace.sh`)

  * Multi-hop trace SNR metrics
  * Per-hop path health
  * RF profile tags for later experimentation/correlation

* **Node status telemetry** (`mc_status.sh`)

  * Remote node status snapshots
  * Battery / airtime / RSSI / SNR / counters
  * Same RF/firmware metadata tagging for correlation

Designed to be gentle on the mesh while preserving long-term data useful for RF experiments.

---

# Components

## Scripts

Installed in:

```text
/usr/local/bin/mc_trace.sh
/usr/local/bin/mc_status.sh
```

## Serial device

Uses stable udev symlink:

```text
/dev/meshcore0
```

Avoids ttyUSB/ttyACM numbering changes after reboot.

---

# Data collected

## Trace measurement

Measurement:

```text
meshcore_trace
```

### Tags

```text
site
path
from
to
ver
model
radio_freq
radio_bw
radio_sf
radio_cr
```

### Fields

```text
snr
```

Example:

```text
meshcore_trace,site=lapstone,path=e2-22-e2,from=e2,to=22,ver=v1.15.0-dee3e26,model=heltec_v4_3_oled,radio_freq=915.8,radio_bw=250.0,radio_sf=11,radio_cr=5 snr=-1.25
```

---

## Status measurement

Measurement:

```text
meshcore_status
```

### Tags

```text
node
ver
model
radio_freq
radio_bw
radio_sf
radio_cr
```

### Fields

```text
bat
tx_queue_len
noise_floor
last_rssi
nb_recv
nb_sent
airtime
uptime
sent_flood
sent_direct
recv_flood
recv_direct
full_evts
last_snr
direct_dups
flood_dups
rx_airtime
```

Example:

```text
meshcore_status,node=qh_corb,ver=v1.15.0-dee3e26,model=heltec_v4_3_oled,radio_freq=915.8,radio_bw=250.0,radio_sf=11,radio_cr=5 bat=4130i,last_snr=6.25,...
```

---

# Why these tags exist

## Firmware / model

Collected intentionally because upgrades may affect results.

Used to correlate changes in:

* routing behaviour
* link performance
* trace behaviour
* firmware regressions/improvements

## RF parameters

Collected intentionally for future experiments.

Useful when comparing:

* frequencies
* bandwidth changes
* spreading factor changes
* coding rate changes

These are experimental control variables.

---

# Trace targets

Currently:

| Node | Site          |
| ---- | ------------- |
| 4a   | faulco        |
| 22   | lapstone      |
| 62   | quakershill   |
| 4d   | acaciagardens |
| 3c   | qhpaterson    |
| 64   | hawkeshtsb    |

Generated paths:

```text
e2,node,e2
2f,node,2f
```

Each destination traced both ways.

Order is shuffled every run.

---

# Polling philosophy

## Trace

Runs batched probes:

* batch size: 3
* batch delay: 10s
* randomised path order each sweep
* missing traces simply produce no data

No explicit failure metrics are emitted.

Absence of data == unreachable / timed out.

Intentional.

---

## Status

Sequential polling with jitter.

Transient responses handled separately:

```text
unknown contact  -> local contact missing
Getting data     -> remote busy/not ready
```

Debug output distinguishes these.

---

# Telegraf config

Example:

```toml
[agent]
  interval = "1m"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 5000
  flush_interval = "1m"
  flush_jitter = "5s"

[[outputs.influxdb_v2]]
  urls = ["http://YOUR-INFLUX-HOST:8086"]
  token = "${INFLUX_TOKEN}"
  organization = "example-org"
  bucket = "example-bucket"

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

Status is intentionally offset from trace to avoid bursts.

---

# Token handling

Use environment variable via systemd drop-in:

```ini
[Service]
EnvironmentFile=/etc/telegraf/telegraf.env
```

`/etc/telegraf/telegraf.env`

```bash
INFLUX_TOKEN=...
```

Permissions:

```bash
sudo chown root:telegraf /etc/telegraf/telegraf.env
sudo chmod 640 /etc/telegraf/telegraf.env
```

---

# Testing

## Run scripts manually

```bash
DEBUG=1 /usr/local/bin/mc_trace.sh
DEBUG=1 /usr/local/bin/mc_status.sh
```

Run as telegraf user:

```bash
sudo -u telegraf /usr/local/bin/mc_trace.sh
sudo -u telegraf /usr/local/bin/mc_status.sh
```

---

## Validate telegraf

```bash
sudo telegraf --test --config /etc/telegraf/telegraf.conf
```

---

## Watch service

```bash
sudo systemctl restart telegraf
journalctl -u telegraf -f
```

---

# Debug tricks

Single-path tracing:

```bash
BATCH_SIZE=1 DEBUG=1 ./mc_trace.sh
```

Longer status delay testing:

```bash
QUERY_DELAY=15 DEBUG=1 ./mc_status.sh
```

---

# Notes / assumptions

## Trace response ordering

Trace batching assumes:

```text
meshcore-cli responses return in request order
```

Current mapping logic depends on this.

If MeshCore changes that behaviour, batch correlation logic must be revisited.

---

## Contact database

`req_status` requires monitored nodes to exist in local contact database.

If hardware is swapped or reflashed:

contacts may need re-importing.

---

# Future ideas

Possible later additions:

* summary debug counters per sweep
* Grafana RF profile comparisons
* alerting on prolonged missing traces
* compare firmware versions over time
* frequency testing dashboards

---

# Design principles

This setup intentionally prefers:

* simple shell over heavy tooling
* low mesh impact over aggressive polling
* missing data over synthetic failure metrics
* long-term experimental metadata collection
* boring, inspectable scripts

Stability over cleverness.

---

# Author notes

If something looks weird first check:

1. mesh conditions
2. node contact list
3. radio settings changed during testing
4. telegraf timeout not clipping scripts
5. `/dev/meshcore0` still pointing at correct device

Most failures are usually one of those.
