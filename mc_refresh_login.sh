#!/usr/bin/env bash

# Usage:
#   export MESH_PASSWORD='...'
#   ./mc_refresh_login.sh

set -euo pipefail

readonly device_path="/dev/meshcore0"

mesh_password="${MESH_PASSWORD:?set MESH_PASSWORD}"

# --- contacts ----------------------------------------------------------------
contacts=(
  "qh_corb|🦷 Quakers Hill Corb"
  "qh_wold|🦷 Quakers Hill Wold"
  "qh_mid|🦷 Quakers Hill Mid"
  "qh_paterson|🦷 QH Paterson"
  "acaciagardens|🦷 Acacia Gardens"
)

ok=0
fail=0

# --- login sweep --------------------------------------------------------------
for entry in "${contacts[@]}"; do

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
