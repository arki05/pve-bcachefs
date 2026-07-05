#!/usr/bin/env bash
# Install the bcachefs storage plugin on a PVE node (run as root on the node).
set -euo pipefail

cd "$(dirname "$0")"

DEST=/usr/share/perl5/PVE/Storage/Custom

install -D -m 0644 src/PVE/Storage/Custom/BcachefsPlugin.pm "$DEST/BcachefsPlugin.pm"

# compile check before restarting anything (PVE::Storage loads Custom/ plugins;
# loading the plugin directly instead would hit plugin-registration ordering)
perl -e 'use PVE::Storage;' || {
    echo "plugin failed to compile, removing" >&2
    rm -f "$DEST/BcachefsPlugin.pm"
    exit 1
}

systemctl try-reload-or-restart pvedaemon pvestatd pveproxy pvescheduler

echo "installed. optional (sized folder containers + snapshot-mode vzdump):"
echo "  perl patches/patch-pve-container.pl"
