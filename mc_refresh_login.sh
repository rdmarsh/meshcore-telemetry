#!/usr/bin/env bash

# Usage:
#   export MESH_PASSWORD='...'
#   ./mc_refresh_login.sh

set -euo pipefail

readonly device_path="/dev/meshcore0"

mesh_password="${MESH_PASSWORD:?set MESH_PASSWORD}"

config_file="${MESHCORE_CONFIG:-/usr/local/etc/meshcore/nodes.conf}"
[[ ! -f "$config_file" ]] && config_file="$(dirname "$0")/nodes.conf"
# shellcheck source=/dev/null
source "$config_file" || { echo "Cannot load config: $config_file" >&2; exit 1; }

ok=0
fail=0

# --- login sweep --------------------------------------------------------------
for entry in "${STATUS_CONTACTS[@]}"; do

  alias="${entry%%|*}"
  contact="${entry##*|}"

  printf 'Logging into %s ... ' "$alias"

  output="$(
    /usr/local/bin/meshcore-cli \
      -j \
      -s "$device_path" \
      login "$contact" "$mesh_password" \
      2>&1 || true
  )"

  if jq -e '.login_success == true' >/dev/null 2>&1 <<<"$output"; then
    echo "ok"
    ((++ok))
  else
    echo "failed"
    printf '    contact: %s\n' "$contact"
    printf '    result : %s\n' "$output"
    echo
    ((++fail))
  fi

  # small pause so we don't hammer the mesh
  sleep 2

done

echo
echo "Completed: $ok ok, $fail failed"

# return number of peers that failed login
exit "$fail"
