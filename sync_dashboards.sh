#!/usr/bin/env bash
# Sync Grafana dashboards to/from local JSON files in dashboards/
# Usage: GRAFANA_TOKEN=glsa_... ./sync_dashboards.sh --pull
#        GRAFANA_TOKEN=glsa_... ./sync_dashboards.sh --push
set -euo pipefail

GRAFANA_URL="${GRAFANA_URL:-https://yourenotmyreal.dad}"
TOKEN="${GRAFANA_TOKEN:?GRAFANA_TOKEN environment variable is required}"
OUT_DIR="$(dirname "$0")/dashboards"
API_BASE="$GRAFANA_URL/apis/dashboard.grafana.app/v2/namespaces/default/dashboards"

# Strip volatile fields that change on every save or differ per instance
CLEAN_JQ='del(
  .metadata.uid,
  .metadata.resourceVersion,
  .metadata.generation,
  .metadata.creationTimestamp,
  .metadata.labels["grafana.app/deprecatedInternalID"],
  .metadata.annotations["grafana.app/createdBy"],
  .metadata.annotations["grafana.app/updatedBy"],
  .metadata.annotations["grafana.app/updatedTimestamp"]
)'

# Return folder name for a given dashboard filename
get_folder() {
  local file="$1"
  local base
  base=$(basename "$file")
  case "$base" in
    grafana_trace_*|grafana_mesh_reliability*|grafana_failure_reasons*)
      echo "Traces" ;;
    *)
      echo "Nodes" ;;
  esac
}

# Return uid of a Grafana folder by name, creating it if it doesn't exist
ensure_folder() {
  local folder_name="$1"
  local result
  result=$(curl -sf --max-time 30 \
    -H "Authorization: Bearer $TOKEN" \
    "$GRAFANA_URL/api/folders")
  local uid
  uid=$(printf '%s' "$result" | jq -r --arg n "$folder_name" '.[] | select(.title == $n) | .uid' | head -1)
  if [[ -z "$uid" ]]; then
    echo "  -> Creating folder \"$folder_name\"" >&2
    local create_response
    create_response=$(curl -sf --max-time 30 \
      -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      --data-binary "$(jq -n --arg t "$folder_name" '{"title":$t}')" \
      "$GRAFANA_URL/api/folders")
    uid=$(printf '%s' "$create_response" | jq -r '.uid')
  fi
  echo "$uid"
}

pull() {
  mkdir -p "$OUT_DIR"
  echo "Fetching dashboard list..." >&2
  dashboards=$(curl -sf --max-time 30 \
    -H "Authorization: Bearer $TOKEN" \
    "$GRAFANA_URL/api/search?type=dash-db")

  count=$(printf '%s' "$dashboards" | jq 'length')
  echo "Found $count dashboard(s)" >&2

  printf '%s' "$dashboards" | jq -c '.[]' | while read -r dash; do
    name=$(printf '%s' "$dash" | jq -r '.uid')
    title=$(printf '%s' "$dash" | jq -r '.title')
    slug="grafana_$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '_' | sed 's/_*$//')"

    echo "Pulling: $title -> $OUT_DIR/${slug}.json" >&2

    curl -sf --max-time 30 \
      -H "Authorization: Bearer $TOKEN" \
      "$API_BASE/$name" \
      | jq "$CLEAN_JQ" \
      > "$OUT_DIR/${slug}.json"
  done
}

push() {
  echo "Pushing dashboards to Grafana..." >&2
  for file in "$OUT_DIR"/*.json; do
    name=$(jq -r '.metadata.name' "$file")
    title=$(jq -r '.spec.title' "$file")

    echo "Pushing: $title <- $file" >&2

    # Look up dashboard by title in search API to get the canonical UID
    echo "  -> Looking up \"$title\" in Grafana" >&2
    search_result=$(curl -sf --max-time 30 \
      -H "Authorization: Bearer $TOKEN" \
      "$GRAFANA_URL/api/search?type=dash-db&query=$(printf '%s' "$title" | jq -sRr @uri)")
    grafana_uid=$(printf '%s' "$search_result" | jq -r --arg t "$title" '.[] | select(.title == $t) | .uid' | head -1)

    if [[ -n "$grafana_uid" ]]; then
      echo "  -> Found uid=$grafana_uid, fetching resourceVersion" >&2
      existing=$(curl -sf --max-time 30 \
        -H "Authorization: Bearer $TOKEN" \
        "$API_BASE/$grafana_uid")
      resource_version=$(printf '%s' "$existing" | jq -r '.metadata.resourceVersion')

      # Update local file with correct name if it differs
      if [[ "$grafana_uid" != "$name" ]]; then
        jq --arg n "$grafana_uid" '.metadata.name = $n' "$file" > /tmp/grafana_updated.json
        mv /tmp/grafana_updated.json "$file"
        echo "  -> Updated local name to $grafana_uid" >&2
      fi

      # Set folder on every PUT so existing dashboards get moved if needed
      folder_name=$(get_folder "$file")
      folder_uid=$(ensure_folder "$folder_name")

      echo "  -> Sending PUT (folder: $folder_name)" >&2
      payload=$(jq --arg rv "$resource_version" --arg f "$folder_uid" \
        '.metadata.resourceVersion = $rv | .metadata.annotations["grafana.app/folder"] = $f' "$file")
      response=$(printf '%s' "$payload" | curl -s --max-time 30 -o /tmp/grafana_push_response.json -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "$API_BASE/$grafana_uid")
    else
      # Dashboard not found in search — create a stub via the classic API, which
      # produces a properly-indexed dashboard the k8s API can subsequently update.
      folder_name=$(get_folder "$file")
      folder_uid=$(ensure_folder "$folder_name")
      echo "  -> Not found in Grafana, creating stub in folder \"$folder_name\"" >&2
      stub=$(jq -n --arg t "$title" --arg f "$folder_uid" '{"dashboard":{"title":$t,"schemaVersion":38,"panels":[]},"folderUid":$f,"overwrite":false}')
      stub_response=$(printf '%s' "$stub" | curl -s --max-time 30 \
        -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "$GRAFANA_URL/api/dashboards/db")
      grafana_uid=$(printf '%s' "$stub_response" | jq -r '.uid // empty')
      if [[ -z "$grafana_uid" ]]; then
        echo "  -> ERROR: classic API stub creation failed:" >&2
        printf '%s' "$stub_response" | jq '.' >&2
        exit 1
      fi
      echo "  -> Created stub uid=$grafana_uid, fetching resourceVersion" >&2

      # GET the new dashboard via k8s API to obtain its resourceVersion
      existing=$(curl -sf --max-time 30 \
        -H "Authorization: Bearer $TOKEN" \
        "$API_BASE/$grafana_uid")
      resource_version=$(printf '%s' "$existing" | jq -r '.metadata.resourceVersion')

      # Update local file with the assigned uid
      jq --arg n "$grafana_uid" '.metadata.name = $n' "$file" > /tmp/grafana_updated.json
      mv /tmp/grafana_updated.json "$file"
      name="$grafana_uid"

      # PUT full dashboard content via k8s API, including folder assignment
      echo "  -> Sending PUT with full content (folder: $folder_name)" >&2
      payload=$(jq --arg rv "$resource_version" --arg f "$folder_uid" \
        '.metadata.resourceVersion = $rv | .metadata.annotations["grafana.app/folder"] = $f' "$file")
      response=$(printf '%s' "$payload" | curl -s --max-time 30 -o /tmp/grafana_push_response.json -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "$API_BASE/$grafana_uid")
    fi

    if [[ "$response" =~ ^2 ]]; then
      echo "  -> OK ($response)" >&2
      # Save name Grafana assigned on creation back to local file
      new_name=$(jq -r '.metadata.name // empty' /tmp/grafana_push_response.json)
      if [[ -n "$new_name" && "$new_name" != "$name" ]]; then
        jq --arg n "$new_name" '.metadata.name = $n' "$file" > /tmp/grafana_updated.json
        mv /tmp/grafana_updated.json "$file"
        echo "  -> Assigned name: $new_name" >&2
      fi
    elif [[ "$response" == "409" ]]; then
      # Dashboard exists but wasn't found via search — try PUT to update it
      conflict_name=$(jq -r '.details.name' /tmp/grafana_push_response.json)
      echo "  -> Already exists as \"$conflict_name\", attempting PUT" >&2

      # Try to get resourceVersion; may return 403 for API-created dashboards
      existing=$(curl -s --max-time 30 \
        -H "Authorization: Bearer $TOKEN" \
        "$API_BASE/$conflict_name")
      resource_version=$(printf '%s' "$existing" | jq -r '.metadata.resourceVersion // empty')

      if [[ -n "$resource_version" ]]; then
        payload=$(jq --arg n "$conflict_name" --arg rv "$resource_version" \
          '.metadata.name = $n | .metadata.resourceVersion = $rv' "$file")
      else
        # Can't read resourceVersion — try PUT without it
        echo "  -> Cannot read resourceVersion, trying PUT without it" >&2
        payload=$(jq --arg n "$conflict_name" 'del(.metadata.resourceVersion) | .metadata.name = $n' "$file")
      fi

      response=$(printf '%s' "$payload" | curl -s --max-time 30 -o /tmp/grafana_push_response.json -w "%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        --data-binary @- \
        "$API_BASE/$conflict_name")
      if [[ "$response" =~ ^2 ]]; then
        jq --arg n "$conflict_name" '.metadata.name = $n' "$file" > /tmp/grafana_updated.json
        mv /tmp/grafana_updated.json "$file"
        echo "  -> OK ($response)" >&2
      else
        echo "  -> ERROR ($response)" >&2
        jq '.' /tmp/grafana_push_response.json >&2
        exit 1
      fi
    else
      echo "  -> ERROR ($response)" >&2
      jq '.' /tmp/grafana_push_response.json >&2
      exit 1
    fi
  done
}

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 --push | --pull" >&2
  exit 1
fi

case "$1" in
  --push) push ;;
  --pull) pull ;;
  *) echo "Unknown option: $1. Use --push or --pull." >&2; exit 1 ;;
esac

echo "Done." >&2
