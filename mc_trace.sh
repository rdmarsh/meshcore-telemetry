#!/usr/bin/env bash

set -euo pipefail

DEBUG="${DEBUG:-0}"

log() {
  if [ "$DEBUG" = "1" ]; then
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  fi
}

readonly device_path="/dev/meshcore0"

batch_size="${BATCH_SIZE:-3}"
readonly batch_delay=10
readonly trace_timeout=45

destinations=(
  "4a:faulco"
  "22:lapstone"
  "62:quakershill"
  "4d:acaciagardens"
  "3c:qhpaterson"
  "64:hawkeshtsb"
)

paths=()
for d in "${destinations[@]}"; do
  node="${d%%:*}"
  site="${d##*:}"
  paths+=("$site|e2,$node,e2")
  paths+=("$site|2f,$node,2f")
done

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

run_batch() {
  local vt="$1"
  local rt="$2"
  shift 2

  local cmd=(/usr/local/bin/meshcore-cli -j -s "$device_path")
  local batch_paths=()
  local batch_sites=()

  for item in "$@"; do
    site="${item%%|*}"
    path="${item##*|}"
    batch_sites+=("$site")
    batch_paths+=("$path")
    cmd+=(trace "$path")
  done

  output="$(timeout "$trace_timeout" "${cmd[@]}" 2>/dev/null || true)"
  [ -z "$output" ] && return

  i=0

  while read -r obj; do

    if jq -e '.error' >/dev/null 2>&1 <<<"$obj"; then
      log "Trace timeout: ${batch_sites[$i]} path ${batch_paths[$i]}"
      i=$((i+1))
      continue
    fi

    site="${batch_sites[$i]}"
    i=$((i+1))

    jq -r \
      --arg site "$site" \
      --arg vt "$vt" \
      --arg rt "$rt" '
      .path as $p |
      ($p|length) as $len |
      ($p[0:$len-1] | map(.hash) | join("-")) as $path |

      if $len < 2 then empty
      else
        (
          range($len-1) as $x |
          "meshcore_trace" +
          ",site=" + $site +
          ",path=" + $path +
          ",from=" +
            (if $x==0 then "home" else $p[$x-1].hash end) +
          ",to=" + $p[$x].hash +
          "," + $vt +
          "," + $rt +
          " snr=" + ($p[$x].snr|tostring)
        ),
        (
          "meshcore_trace" +
          ",site=" + $site +
          ",path=" + $path +
          ",from=" + $p[$len-2].hash +
          ",to=home" +
          "," + $vt +
          "," + $rt +
          " snr=" + ($p[$len-1].snr|tostring)
        )
      end
    ' <<<"$obj"

  done < <(
    printf '%s\n' "$output" | jq -c '.'
  )
}

log "Starting meshcore trace sweep"

vt=$(get_version_tags)
rt=$(get_radio_tags)

mapfile -t shuffled_paths < <(
  printf "%s\n" "${paths[@]}" | shuf
)

index=0
total=${#shuffled_paths[@]}

while [ "$index" -lt "$total" ]; do

  batch=( "${shuffled_paths[@]:index:batch_size}" )

  run_batch "$vt" "$rt" "${batch[@]}"

  index=$((index + batch_size))

  if [ "$index" -lt "$total" ]; then
    sleep "$batch_delay"
  fi

done

log "Finished meshcore trace poll"
