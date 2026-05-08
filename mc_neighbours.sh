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

config_file="${MESHCORE_CONFIG:-/usr/local/etc/meshcore/nodes.conf}"
[[ ! -f "$config_file" ]] && config_file="$(dirname "$0")/nodes.conf"
# shellcheck source=/dev/null
source "$config_file" || { echo "Cannot load config: $config_file" >&2; exit 1; }

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

query_neighbours() {
  local alias="$1"
  local contact="$2"
  local version_tags="$3"
  local radio_tags="$4"

  log "Querying $alias"

  local output
  output=$(
    timeout "$query_timeout" \
      /usr/local/bin/meshcore-cli -j -s "$device_path" \
      req_neighbours "$contact" \
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

  # one line per neighbour; neighbours_count repeated on each row for easy aggregation
  jq -r \
    --arg node "$alias" \
    --arg vt "$version_tags" \
    --arg rt "$radio_tags" '
      .neighbours_count as $count |
      .neighbours[] |
      "meshcore_neighbours" +
      ",node=" + $node +
      ",neighbour=" + .pubkey +
      "," + $vt +
      "," + $rt +
      " snr=" + (.snr|tostring) +
      ",secs_ago=" + (.secs_ago|tostring) + "i" +
      ",neighbours_count=" + ($count|tostring) + "i"
    ' <<<"$output"
}

log "Starting meshcore neighbours poll"

version_tags=$(get_version_tags)
radio_tags=$(get_radio_tags)

for i in "${!STATUS_CONTACTS[@]}"; do

  entry="${STATUS_CONTACTS[$i]}"

  alias="${entry%%|*}"
  contact="${entry##*|}"

  query_neighbours "$alias" "$contact" "$version_tags" "$radio_tags"

  if [ "$i" -lt $((${#STATUS_CONTACTS[@]}-1)) ]; then
    jitter=$(awk -v max="$random_jitter" 'BEGIN{srand();print int(rand()*(max+1))}')
    sleep $((query_delay + jitter))
  fi

done

log "Finished meshcore neighbours poll"
