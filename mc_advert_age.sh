#!/usr/bin/env bash

set -euo pipefail

DEBUG="${DEBUG:-0}"

log() {
  if [ "$DEBUG" = "1" ]; then
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  fi
}

readonly device_path="/dev/meshcore0"
# only emit contacts heard within this window (default 7d) to keep cardinality sane
readonly max_age="${MAX_AGE:-604800}"

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

log "Starting meshcore advert age poll"

version_tags=$(get_version_tags)
radio_tags=$(get_radio_tags)
now=$(date +%s)

contacts_json=$(
  /usr/local/bin/meshcore-cli -j -s "$device_path" contacts 2>/dev/null || echo '{}'
)

count=$(jq 'length' <<< "$contacts_json")
log "Processing $count contacts"

jq -r \
  --arg vt "$version_tags" \
  --arg rt "$radio_tags" \
  --argjson now "$now" \
  --argjson max_age "$max_age" '
  to_entries[] |
  select(.value.last_advert > 0) |
  . as $e |
  ($now - $e.value.last_advert) as $age |
  select($age >= 0 and $age <= $max_age) |
  (
    $e.value.adv_name
    | ascii_downcase
    | gsub("[^a-z0-9]+"; "_")
    | ltrimstr("_")
    | rtrimstr("_")
  ) as $node |
  select($node != "" and $node != null) |
  "meshcore_advert" +
  ",node=" + $node +
  (if $vt != "" then "," + $vt else "" end) +
  (if $rt != "" then "," + $rt else "" end) +
  " adv_age=" + ($age|tostring) + "i"
' <<< "$contacts_json"

log "Finished meshcore advert age poll"
