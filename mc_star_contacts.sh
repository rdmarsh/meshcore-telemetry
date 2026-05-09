#!/usr/bin/env bash

# Marks all STATUS_CONTACTS as starred (flag=1) so they are not pruned
# from the local contact database.
# Run manually after adding new nodes or after a node is reflashed.
# No password required — operates on the local contact database only.

set -euo pipefail

readonly device_path="/dev/meshcore0"
readonly STAR_FLAG=1

config_file="${MESHCORE_CONFIG:-/usr/local/etc/meshcore/nodes.conf}"
[[ ! -f "$config_file" ]] && config_file="$(dirname "$0")/nodes.conf"
# shellcheck source=/dev/null
source "$config_file" || { echo "Cannot load config: $config_file" >&2; exit 1; }

ok=0
fail=0

for entry in "${STATUS_CONTACTS[@]}"; do
  alias="${entry%%|*}"
  contact="${entry##*|}"

  printf 'Starring %s ... ' "$alias"

  output=$(
    /usr/local/bin/meshcore-cli \
      -j \
      -s "$device_path" \
      change_flags "$contact" "$STAR_FLAG" \
      2>&1 || true
  )

  if jq -e '.error' >/dev/null 2>&1 <<<"$output"; then
    echo "failed"
    printf '    result: %s\n' "$output"
    ((++fail))
  else
    echo "ok"
    ((++ok))
  fi

done

echo
echo "Completed: $ok ok, $fail failed"
exit "$fail"
