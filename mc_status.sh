#!/usr/bin/env bash

set -euo pipefail

DEBUG="${DEBUG:-0}"

log() {
  if [ "$DEBUG" = "1" ]; then
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  fi
}

readonly device_path="/dev/meshcore0"
# single batch timeout covers all nodes responding over the air
readonly query_timeout="${QUERY_TIMEOUT:-120}"

config_file="${MESHCORE_CONFIG:-/usr/local/etc/meshcore/nodes.conf}"
[[ ! -f "$config_file" ]] && config_file="$(dirname "$0")/nodes.conf"
# shellcheck source=/dev/null
source "$config_file" || { echo "Cannot load config: $config_file" >&2; exit 1; }

# field/tag names intentionally match meshcore-cli JSON.
# req_status requires contacts to exist on the local node.

get_version_tags() {
  local out
  # jq exits 0 on empty stdin, producing no output — capture and apply fallback explicitly
  out=$(/usr/local/bin/meshcore-cli -j -s "$device_path" ver 2>/dev/null |
    jq -r '
      "ver=" + .ver +
      ",model=" +
      (
        .model
        | ascii_downcase
        | gsub("[^a-z0-9]+"; "_")
        | sub("_$"; "")
      )
    ' 2>/dev/null)
  echo "${out:-ver=unknown,model=unknown}"
}

get_radio_tags() {
  local out
  # jq exits 0 on empty stdin, producing no output — capture and apply fallback explicitly
  out=$(/usr/local/bin/meshcore-cli -j -s "$device_path" infos 2>/dev/null |
    jq -r '
      "radio_freq=" + (.radio_freq|tostring) +
      ",radio_bw=" + (.radio_bw|tostring) +
      ",radio_sf=" + (.radio_sf|tostring) +
      ",radio_cr=" + (.radio_cr|tostring)
    ' 2>/dev/null)
  echo "${out:-radio_freq=0,radio_bw=0,radio_sf=0,radio_cr=0}"
}

log "Starting meshcore status poll"

version_tags=$(get_version_tags)
radio_tags=$(get_radio_tags)

# Read local contact database (no radio) to get pubkey_pre for each contact by name
contacts_json=$(
  /usr/local/bin/meshcore-cli -j -s "$device_path" contacts 2>/dev/null || echo '{}'
)

# Build pubkey_pre → alias mapping by looking up each contact's display name
mapping_json=$(
  for entry in "${STATUS_CONTACTS[@]}"; do
    alias="${entry%%|*}"
    contact="${entry##*|}"
    pubkey=$(jq -r --arg name "$contact" \
      'to_entries[] | select(.value.adv_name == $name) | .value.public_key[0:12]' \
      <<< "$contacts_json" | head -1)
    if [[ -n "$pubkey" && "$pubkey" != "null" ]]; then
      jq -n --arg k "$pubkey" --arg v "$alias" '{($k): $v}'
    else
      log "Could not find pubkey for $alias ($contact) in contacts database"
    fi
  done | jq -s 'add // {}'
)

# Build CLI args: one req_status per contact
cli_args=()
for entry in "${STATUS_CONTACTS[@]}"; do
  contact="${entry##*|}"
  cli_args+=(req_status "$contact")
done

log "Querying ${#STATUS_CONTACTS[@]} nodes in single batch"

output=$(
  timeout "$query_timeout" \
    /usr/local/bin/meshcore-cli -j -s "$device_path" "${cli_args[@]}" \
    2>/dev/null || true
)

if [ -z "$output" ]; then
  log "Empty response from batch query"
  exit 0
fi

log "Got $(jq -s 'length' <<< "$output") response(s)"

jq -r -s \
  --arg vt "$version_tags" \
  --arg rt "$radio_tags" \
  --argjson mapping "$mapping_json" '
  .[] |
  select(.pubkey_pre != null) |
  . as $r |
  ($mapping[$r.pubkey_pre]) as $node |
  select($node != null) |
  "meshcore_status" +
  ",node=" + $node +
  (if $vt != "" then "," + $vt else "" end) +
  (if $rt != "" then "," + $rt else "" end) +
  " " +
  "bat=" + ($r.bat|tostring) + "i," +
  "tx_queue_len=" + ($r.tx_queue_len|tostring) + "i," +
  "noise_floor=" + ($r.noise_floor|tostring) + "i," +
  "last_snr=" + ($r.last_snr|tostring) + "," +
  "last_rssi=" + ($r.last_rssi|tostring) + "i," +
  "nb_recv=" + ($r.nb_recv|tostring) + "i," +
  "nb_sent=" + ($r.nb_sent|tostring) + "i," +
  "airtime=" + ($r.airtime|tostring) + "i," +
  "uptime=" + ($r.uptime|tostring) + "i," +
  "sent_flood=" + ($r.sent_flood|tostring) + "i," +
  "sent_direct=" + ($r.sent_direct|tostring) + "i," +
  "recv_flood=" + ($r.recv_flood|tostring) + "i," +
  "recv_direct=" + ($r.recv_direct|tostring) + "i," +
  "full_evts=" + ($r.full_evts|tostring) + "i," +
  "direct_dups=" + ($r.direct_dups|tostring) + "i," +
  "flood_dups=" + ($r.flood_dups|tostring) + "i," +
  "rx_airtime=" + ($r.rx_airtime|tostring) + "i"
' <<< "$output"

log "Finished meshcore status poll"
