#!/usr/bin/env bash
set -euo pipefail

DEST=/usr/local/bin
SCRIPTS=(mc_trace.sh mc_status.sh mc_refresh_login.sh)

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo ./deploy.sh)" >&2
    exit 1
fi

for script in "${SCRIPTS[@]}"; do
    install -m 755 -o root -g root "$script" "$DEST/$script"
    echo "Installed $DEST/$script"
done
