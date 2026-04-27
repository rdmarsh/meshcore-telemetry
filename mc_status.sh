#!/usr/bin/env bash

set -euo pipefail

DEBUG="${DEBUG:-0}"

log() {
  if [ "$DEBUG" = "1" ]; then
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  fi
}

readonly device_path="/dev/meshcore0"
readonly query_timeout=30
readonly query_delay="${QUERY_DELAY:-5}"
readonly random_jitter=2

contacts=(
  "qh_corb|🦷 Quakers Hill Corb"
  "qh_wold|🦷 Quakers Hill Wold"
  "qh_mid|🦷 Quakers Hill Mid"
  "qh_paterson|🦷 QH Paterson"
  "acaciagardens|🦷 Acacia Gardens"
)

# field/tag names intentionally match meshcore-cli JSON.
# req_status requires contacts to exist on the local node.

get_version_tags() {
  /usr/local/bin/meshcore-cli -j -s "$device_path" ver 2>/dev/null |
  jq -r '
    "ver=" + .ver +
    ",model=" +
    (
      .model
      | ascii_downcase
      | gsub("[^a-z0-9]+"; "_")
      | sub("_$"; "")
    )
  ' 2>/dev/null || echo "ver=unknown,model=unknown"
}

get_radio_tags() {
  /usr/local/bin/meshcore-cli -j -s "$device_path" infos 2>/dev/null |
  jq -r '
    "radio_freq=" + (.radio_freq|tostring) +
    ",radio_bw=" + (.radio_bw|tostring) +
    ",radio_sf=" + (.radio_sf|tostring) +
    ",radio_cr=" + (.radio_cr|tostring)
  ' 2>/dev/null ||
  echo "radio_freq=0,radio_bw=0,radio_sf=0,radio_cr=0"
}

query_status() {
  local alias="$1"
  local contact="$2"
  local version_tags="$3"
  local radio_tags="$4"

  log "Querying $alias"

  local output
  output=$(
    timeout "$query_timeout" \
      /usr/local/bin/meshcore-cli -j -s "$device_path" \
      req_status "$contact" \
      2>/dev/null || true
  )

  [ -z "$output" ] && {
    log "Empty response from $alias"
    return
  }

  if jq -e '.error=="unknown contact"' >/dev/null 2>&1 <<<"$output"; then
    log "Contact missing on local node: $alias"
    return
  fi

  if jq -e '.error=="Getting data"' >/dev/null 2>&1 <<<"$output"; then
    log "Node busy or not ready: $alias"
    return
  fi

  if jq -e '.error' >/dev/null 2>&1 <<<"$output"; then
    log "Error response from $alias: $output"
    return
  fi

  jq -r \
    --arg node "$alias" \
    --arg vt "$version_tags" \
    --arg rt "$radio_tags" '
      "meshcore_status" +
      ",node=" + $node +
      "," + $vt +
      "," + $rt +
      " " +
      "bat=" + (.bat|tostring) + "i," +
      "tx_queue_len=" + (.tx_queue_len|tostring) + "i," +
      "noise_floor=" + (.noise_floor|tostring) + "i," +
      "last_rssi=" + (.last_rssi|tostring) + "i," +
      "nb_recv=" + (.nb_recv|tostring) + "i," +
      "nb_sent=" + (.nb_sent|tostring) + "i," +
      "airtime=" + (.airtime|tostring) + "i," +
      "uptime=" + (.uptime|tostring) + "i," +
      "sent_flood=" + (.sent_flood|tostring) + "i," +
      "sent_direct=" + (.sent_direct|tostring) + "i," +
      "recv_flood=" + (.recv_flood|tostring) + "i," +
      "recv_direct=" + (.recv_direct|tostring) + "i," +
      "full_evts=" + (.full_evts|tostring) + "i," +
      "last_snr=" + (.last_snr|tostring) + "," +
      "direct_dups=" + (.direct_dups|tostring) + "i," +
      "flood_dups=" + (.flood_dups|tostring) + "i," +
      "rx_airtime=" + (.rx_airtime|tostring) + "i"
    ' <<<"$output"
}

log "Starting meshcore status poll"

version_tags=$(get_version_tags)
radio_tags=$(get_radio_tags)

for i in "${!contacts[@]}"; do

  entry="${contacts[$i]}"

  alias="${entry%%|*}"
  contact="${entry##*|}"

  query_status "$alias" "$contact" "$version_tags" "$radio_tags"

  if [ "$i" -lt $((${#contacts[@]}-1)) ]; then
    jitter=$(awk -v max="$random_jitter" 'BEGIN{srand();print int(rand()*(max+1))}')
    sleep $((query_delay + jitter))
  fi

done

log "Finished meshcore status poll"
