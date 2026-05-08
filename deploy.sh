#!/usr/bin/env bash
set -euo pipefail

DEST=/usr/local/bin
CONF_DEST=/usr/local/etc/meshcore/nodes.conf
SCRIPTS=(mc_trace.sh mc_status.sh mc_refresh_login.sh mc_neighbours.sh)

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (sudo ./deploy.sh)" >&2
    exit 1
fi

for script in "${SCRIPTS[@]}"; do
    install -m 755 -o root -g root "$script" "$DEST/$script"
    echo "Installed $DEST/$script"
done

mkdir -p "$(dirname "$CONF_DEST")"
if [[ ! -f "$CONF_DEST" ]]; then
    install -m 644 -o root -g root nodes.conf "$CONF_DEST"
    echo "Installed $CONF_DEST"
else
    echo "Config already exists, not overwriting: $CONF_DEST"
    echo "  -> To update: sudo install -m 644 nodes.conf $CONF_DEST"
fi

TELEGRAF_DROP_IN=/etc/telegraf/telegraf.d/mc_neighbours.conf
install -m 644 -o root -g root telegraf-neighbours.conf "$TELEGRAF_DROP_IN"
echo "Installed $TELEGRAF_DROP_IN"
echo "Restarting telegraf..."
systemctl restart telegraf
