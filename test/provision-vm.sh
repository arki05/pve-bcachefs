#!/usr/bin/env bash
# Provision a fresh PVE 9 VM as a bcachefs plugin test bed. Run as root INSIDE the VM.
# Expects three extra blank disks: two "hdd" (sdb, sdc) and one "ssd" (sdd).
set -euo pipefail

echo "=== apt repos: disable enterprise, enable no-subscription ==="
rm -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

echo "=== bcachefs repo ==="
curl -fsSL https://apt.bcachefs.org/bcachefs.asc -o /etc/apt/keyrings/bcachefs.asc
echo "deb [signed-by=/etc/apt/keyrings/bcachefs.asc] https://apt.bcachefs.org/trixie bcachefs-tools-release main" \
    > /etc/apt/sources.list.d/bcachefs.list

apt-get update

echo "=== install headers + bcachefs (dkms build takes a few minutes) ==="
DEBIAN_FRONTEND=noninteractive apt-get install -y "proxmox-headers-$(uname -r)" \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y proxmox-default-headers
DEBIAN_FRONTEND=noninteractive apt-get install -y bcachefs-tools bcachefs-kernel-dkms

modprobe bcachefs
bcachefs version

echo "=== format multi-device bcachefs (2x hdd + 1x ssd) ==="
bcachefs format --force \
    --label=hdd.hdd1 /dev/sdb \
    --label=hdd.hdd2 /dev/sdc \
    --label=ssd /dev/sdd

mkdir -p /mnt/tank
UUID=$(bcachefs show-super /dev/sdb | grep -oP '^External UUID:\s+\K\S+')
echo "UUID=$UUID /mnt/tank bcachefs rw,noatime 0 0" >> /etc/fstab
mount /mnt/tank
df -h /mnt/tank

mkdir -p /mnt/tank/pve/fast /mnt/tank/pve/bulk

echo "=== provisioning done ==="
