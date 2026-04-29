#!/usr/bin/env bash

set -euo pipefail

DEBUG="${DEBUG:-0}"

log() {
  if [ "$DEBUG" = "1" ]; then
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
  fi
}

# --- config ------------------------------------------------------------------
readonly device_path="/dev/meshcore0"

# single-path probing keeps duration as true per-path latency
readonly trace_delay=10
readonly trace_timeout=45

# --- trace targets -----------------------------------------------------------
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

# --- version tags ------------------------------------------------------------
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

# --- radio tags --------------------------------------------------------------
get_radio_tags() {
  /usr/local/bin/meshcore-cli -j -s "$device_path" infos 2>/dev/null |
  jq -r '
    "radio_freq=" + (.radio_freq|tostring) +
    ",radio_bw="   + (.radio_bw|tostring) +
    ",radio_sf="   + (.radio_sf|tostring) +
    ",radio_cr="   + (.radio_cr|tostring)
  ' 2>/dev/null ||
  echo "radio_freq=0,radio_bw=0,radio_sf=0,radio_cr=0"
}

# --- emit path result --------------------------------------------------------
emit_trace_result() {
  local site="$1"
  local path="$2"
  local success="$3"
  local duration="$4"
  local vt="$5"
  local rt="$6"
  local failure_reason="${7:-}"

  local tags="site=${site},path=${path//,/-},${vt},${rt}"

  if [ -n "$failure_reason" ]; then
    tags="${tags},failure_reason=${failure_reason}"
  fi

  printf \
'meshcore_trace_result,%s success=%si,duration=%s\n' \
    "$tags" \
    "$success" \
    "$duration"
}

# --- run one trace -----------------------------------------------------------
run_trace() {
  local item="$1"
  local vt="$2"
  local rt="$3"

  local site="${item%%|*}"
  local path="${item##*|}"

  local start end duration output

  start=$(date +%s.%N)

  output="$(
    timeout "$trace_timeout" \
      /usr/local/bin/meshcore-cli -j -s "$device_path" trace "$path" \
      2>/dev/null || true
  )"

  end=$(date +%s.%N)

  duration=$(
    awk -v s="$start" -v e="$end" \
      'BEGIN{printf "%.2f", (e-s)}'
  )

  # command-level timeout (no response at all)
  if [ -z "$output" ]; then
    log "Trace timeout (${trace_timeout}s): $site path $path"

    emit_trace_result \
      "$site" \
      "$path" \
      0 \
      "${trace_timeout}.00" \
      "$vt" \
      "$rt" \
      "command_timeout"

    return
  fi

  # mesh returned explicit trace failure
  if jq -e '.error' >/dev/null 2>&1 <<<"$output"; then
    reason="$(
      jq -r '.error
        | ascii_downcase
        | gsub("[^a-z0-9]+";"_")
        | sub("_$";"")
      ' <<<"$output"
    )"

    log "Trace failed ($reason): $site path $path"

    emit_trace_result \
      "$site" \
      "$path" \
      0 \
      "$duration" \
      "$vt" \
      "$rt" \
      "$reason"

    return
  fi

  emit_trace_result \
    "$site" \
    "$path" \
    1 \
    "$duration" \
    "$vt" \
    "$rt"

  jq -r \
    --arg site "$site" \
    --arg vt "$vt" \
    --arg rt "$rt" '
    .path as $p |
    ($p | length) as $len |
    ($p[0:$len-1] | map(.hash) | join("-")) as $path |

    if $len < 2 then
      empty
    else
      (
        range($len - 1) as $x |
        "meshcore_trace" +
        ",site=" + $site +
        ",path=" + $path +
        ",from=" +
          (if $x == 0 then "home"
           else $p[$x-1].hash end) +
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
  ' <<<"$output"
}

# --- main --------------------------------------------------------------------
log "Starting meshcore trace sweep"

vt=$(get_version_tags)
rt=$(get_radio_tags)

mapfile -t shuffled_paths < <(
  printf "%s\n" "${paths[@]}" | shuf
)

total=${#shuffled_paths[@]}

for i in "${!shuffled_paths[@]}"; do
  item="${shuffled_paths[$i]}"

  run_trace \
    "$item" \
    "$vt" \
    "$rt"

  # skip final delay; no point sleeping before exit
  if [ "$i" -lt $((total - 1)) ]; then
    sleep "$trace_delay"
  fi
done

log "Finished meshcore trace poll"
