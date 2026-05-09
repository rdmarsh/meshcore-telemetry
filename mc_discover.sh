#!/usr/bin/env bash

set -euo pipefail

DEBUG="${DEBUG:-0}"

log() {
  if [ "$DEBUG" = "1" ]; then
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  fi
}

readonly device_path="/dev/meshcore0"

config_file="${MESHCORE_CONFIG:-/usr/local/etc/meshcore/nodes.conf}"
[[ ! -f "$config_file" ]] && config_file="$(dirname "$0")/nodes.conf"
# shellcheck source=/dev/null
source "$config_file" || { echo "Cannot load config: $config_file" >&2; exit 1; }

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

log "Starting meshcore node discover"

version_tags=$(get_version_tags)
radio_tags=$(get_radio_tags)

# Build pubkey_pre → alias map from local contacts database (no radio)
contacts_json=$(
  /usr/local/bin/meshcore-cli -j -s "$device_path" contacts 2>/dev/null || echo '{}'
)

mapping_json=$(
  for entry in "${STATUS_CONTACTS[@]}"; do
    alias="${entry%%|*}"
    contact="${entry##*|}"
    pubkey=$(jq -r --arg name "$contact" \
      'to_entries[] | select(.value.adv_name == $name) | .value.public_key[0:12]' \
      <<< "$contacts_json" | head -1)
    if [[ -n "$pubkey" && "$pubkey" != "null" ]]; then
      jq -n --arg k "$pubkey" --arg v "$alias" '{($k): $v}'
    fi
  done | jq -s 'add // {}'
)

output=$(
  /usr/local/bin/meshcore-cli -j -s "$device_path" node_discover 2>/dev/null || true
)

[ -z "$output" ] && { log "No output from node_discover"; exit 0; }

count=$(jq 'length' <<< "$output")
log "Discovered $count node(s)"

# node_discover pubkey is 16 hex chars; match on first 12 (pubkey_pre)
# unknown nodes fall back to pubkey prefix as tag value
jq -r \
  --arg vt "$version_tags" \
  --arg rt "$radio_tags" \
  --argjson mapping "$mapping_json" '
  .[] |
  . as $n |
  ($n.pubkey[0:12]) as $pre |
  ($mapping[$pre] // $pre) as $node |
  "meshcore_discover" +
  ",node=" + $node +
  (if $vt != "" then "," + $vt else "" end) +
  (if $rt != "" then "," + $rt else "" end) +
  " " +
  "snr=" + ($n.SNR|tostring) + "," +
  "snr_in=" + ($n.SNR_in|tostring) + "," +
  "rssi=" + ($n.RSSI|tostring) + "i," +
  "path_len=" + ($n.path_len|tostring) + "i"
' <<< "$output"

log "Finished meshcore node discover"
