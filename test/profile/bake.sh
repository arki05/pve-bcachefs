#!/usr/bin/env bash
# Baked once into a derived lab image: everything that belongs to the machine
# rather than to the disks.
#
# bcachefs ships as a DKMS module, so this compiles a kernel module against the
# running kernel - minutes of work that must not happen on every lab boot.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

install -d -m 0755 /etc/apt/keyrings
curl -fsSL -o /etc/apt/keyrings/bcachefs.asc https://apt.bcachefs.org/apt.bcachefs.org.asc
echo "deb [signed-by=/etc/apt/keyrings/bcachefs.asc] https://apt.bcachefs.org/trixie bcachefs-tools-release main" \
    > /etc/apt/sources.list.d/bcachefs.list

curl -fsSL -o /etc/apt/keyrings/arki05.asc https://apt.arki05.com/pubkey.asc
echo "deb [signed-by=/etc/apt/keyrings/arki05.asc] https://apt.arki05.com trixie main" \
    > /etc/apt/sources.list.d/arki05.list

APT="apt-get -o DPkg::Lock::Timeout=600"
$APT update -qq

# DKMS needs headers for the running kernel, and the running kernel here is
# whatever the base image ended up with.
$APT install -y -qq "proxmox-headers-$(uname -r)" || $APT install -y -qq proxmox-default-headers
$APT install -y -qq bcachefs-tools bcachefs-kernel-dkms
# getfattr, for the xattr invariant the anchored layout exists to protect.
# Deliberately not the `quota` package: quota-tools do not understand bcachefs,
# so the tests read quotas through quotactl_fd(2) directly, exactly as the
# plugin does.
$APT install -y -qq attr

# Build dependencies, so setup.sh can build the plugin from the working tree
# rather than testing the last published release.
$APT install -y -qq build-essential debhelper devscripts dpkg-dev

# Fail here rather than leaving a derived image whose module only fails to load
# once a test tries to format something.
modprobe bcachefs
grep -qw bcachefs /proc/filesystems || { echo "bcachefs not registered after modprobe" >&2; exit 1; }

$APT install -y -qq pve-bcachefs

# Deliberately NOT installing pct-move-volume-snapshots: the copy_volume xattr
# filter moved into pve-bcachefs, and the point of leaving the other package
# out is to prove that pve-bcachefs alone is enough to move a container off
# bcachefs. If the move tests fail here, the patch did not come across.

bcachefs version
dpkg -l | grep -E 'bcachefs|pve-bcachefs|snapshot-mount'
