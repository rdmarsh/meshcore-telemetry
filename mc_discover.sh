#!/usr/bin/env bash

set -euo pipefail

DEBUG="${DEBUG:-0}"

log() {
  if [ "$DEBUG" = "1" ]; then
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  fi
}

readonly device_path="/dev/meshcore0"

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

# Build pubkey_pre → normalized alias map from ALL contacts in local DB (no radio).
# node=pubkey_pre is the stable series key; alias=adv_name is display label and
# updates automatically when a node renames — the series never splits on rename.
contacts_json=$(
  /usr/local/bin/meshcore-cli -j -s "$device_path" contacts 2>/dev/null || echo '{}'
)

alias_map=$(
  jq '
    to_entries |
    map({
      key: .value.public_key[0:12],
      value: (
        .value.adv_name
        | if . == null or . == ""
          then null
          else ascii_downcase | gsub("[^a-z0-9]+"; "_") | ltrimstr("_") | rtrimstr("_")
               | if . == "" then null else . end
          end
      )
    }) |
    from_entries
  ' <<< "$contacts_json"
)

output=$(
  /usr/local/bin/meshcore-cli -j -s "$device_path" node_discover 2>/dev/null || true
)

[ -z "$output" ] && { log "No output from node_discover"; exit 0; }

count=$(jq 'length' <<< "$output")
log "Discovered $count node(s)"

jq -r \
  --arg vt "$version_tags" \
  --arg rt "$radio_tags" \
  --argjson alias_map "$alias_map" '
  .[] |
  . as $n |
  ($n.pubkey[0:12]) as $pre |
  ($alias_map[$pre] // $pre) as $alias |
  "meshcore_discover" +
  ",alias=" + $alias +
  ",node=" + $pre +
  (if $vt != "" then "," + $vt else "" end) +
  (if $rt != "" then "," + $rt else "" end) +
  " " +
  "snr=" + ($n.SNR|tostring) + "," +
  "snr_in=" + ($n.SNR_in|tostring) + "," +
  "rssi=" + ($n.RSSI|tostring) + "i," +
  "path_len=" + ($n.path_len|tostring) + "i"
' <<< "$output"

log "Finished meshcore node discover"
