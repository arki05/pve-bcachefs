#!/usr/bin/env bash
# Runs on every lab: the test disks are recreated each time, so formatting and
# registering the storage belongs here rather than in bake.sh.
#
# Formats a multi-device bcachefs across every lab disk. Multi-device is not a
# nicety: data-replicas, the foreground/background/promote targets and erasure
# coding are all untestable on a single device, and the quota code path differs
# too - classic quotactl(2) only ever addresses the first device, which is why
# the plugin uses quotactl_fd(2).
set -euo pipefail
CONFIG="${LAB_TEST_CONFIG:-/root/lab-test.env}"
NAME="${BCACHEFS_STORAGE:-lab-bcachefs}"
MOUNT=/mnt/lab-bcachefs

mapfile -t ALL_DISKS < <(ls /dev/disk/by-id/virtio-labdisk* 2>/dev/null | sort)
[ "${#ALL_DISKS[@]}" -ge 2 ] || { echo "need at least 2 lab test disks" >&2; exit 1; }

# The last disk is held back for a second filesystem formatted *without*
# project quotas. The plugin is supposed to notice and allocate a raw image
# instead of an unlimited subvolume, and that fallback is only testable if a
# filesystem without prjquota actually exists.
NOQUOTA_DISK="${ALL_DISKS[-1]}"
NOQUOTA_NAME="${NAME}-noquota"
NOQUOTA_MOUNT=/mnt/lab-bcachefs-noquota
DISKS=("${ALL_DISKS[@]:0:${#ALL_DISKS[@]}-1}")

modprobe bcachefs
mkdir -p "$MOUNT"

# ── The plugin under test ────────────────────────────────────────────────────
#
# bake.sh installed the last published pve-bcachefs so the derived image has a
# working baseline. If a working tree was shipped, build it and install over
# the top - otherwise the run tests whatever was released, which defeats the
# point of running it against a branch.
if [ -d /root/lab-source ]; then
    echo "building pve-bcachefs from the working tree"
    ( cd /root/lab-source && dpkg-buildpackage -us -uc -b >/tmp/build.log 2>&1 ) || {
        echo "building the plugin failed:" >&2
        tail -30 /tmp/build.log >&2
        exit 1
    }
    deb=$(ls -t /root/*.deb 2>/dev/null | head -1)
    [ -n "$deb" ] || { echo "no .deb produced by the build" >&2; exit 1; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        -o DPkg::Lock::Timeout=600 --allow-downgrades "$deb"
    echo "installed $(basename "$deb")"
    dpkg-query -W -f='${Version}\n' pve-bcachefs
fi

# The subvolume-rootfs path and the copy_volume xattr filter both come from the
# package's patch script, applied by its postinst and kept applied by a dpkg
# trigger. Verify rather than assume - a plugin installed without its patches
# silently allocates raw images and cannot move a volume off bcachefs.
grep -q subvol_rootfs_active /usr/share/perl5/PVE/LXC.pm \
    || { echo "the subvolume-rootfs patch is not applied" >&2; exit 1; }
grep -q bcachefs_effective /usr/share/perl5/PVE/LXC.pm \
    || { echo "the copy_volume xattr filter is not applied" >&2; exit 1; }

if ! findmnt -rno TARGET "$MOUNT" >/dev/null 2>&1; then
    for d in "${DISKS[@]}"; do wipefs -aq "$d" || true; done
    # --prjquota at format time: project quotas are what enforce container
    # sizes, and without them the plugin deliberately falls back to raw images.
    # Label the devices so target-related options have something to point at.
    args=()
    i=0
    for d in "${DISKS[@]}"; do
        i=$((i + 1))
        if [ "$i" -le 2 ]; then args+=(--label "fast.d$i" "$d")
        else                    args+=(--label "slow.d$i" "$d"); fi
    done
    bcachefs format --prjquota --force "${args[@]}"
    mount -t bcachefs "$(IFS=:; echo "${DISKS[*]}")" "$MOUNT"
fi

findmnt -rno TARGET "$MOUNT" >/dev/null || { echo "bcachefs did not mount" >&2; exit 1; }

# Prove project quotas are actually live before the suite assumes it.
QUOTA=false
if bcachefs subvolume create "$MOUNT/.quota-probe" >/dev/null 2>&1; then
    if chattr -p 1 "$MOUNT/.quota-probe" >/dev/null 2>&1; then QUOTA=true; fi
    bcachefs subvolume delete "$MOUNT/.quota-probe" >/dev/null 2>&1 || \
        rm -rf "$MOUNT/.quota-probe"
fi

pvesm status 2>/dev/null | grep -q "^${NAME}" || \
    pvesm add bcachefs "$NAME" \
        --path "$MOUNT" \
        --content images,rootdir \
        --bcachefs-subvol-rootfs 1 \
        --bcachefs-compression lz4 \
        --bcachefs-data-replicas 2

# ── The no-prjquota filesystem, for the raw-image fallback ───────────────────

mkdir -p "$NOQUOTA_MOUNT"
if ! findmnt -rno TARGET "$NOQUOTA_MOUNT" >/dev/null 2>&1; then
    wipefs -aq "$NOQUOTA_DISK" || true
    bcachefs format --force "$NOQUOTA_DISK"
    mount -t bcachefs "$NOQUOTA_DISK" "$NOQUOTA_MOUNT"
fi

pvesm status 2>/dev/null | grep -q "^${NOQUOTA_NAME}" || \
    pvesm add bcachefs "$NOQUOTA_NAME" \
        --path "$NOQUOTA_MOUNT" \
        --content images,rootdir \
        --bcachefs-subvol-rootfs 1

cat >> "$CONFIG" <<CFG
STORAGE_NAME=$NAME
NOQUOTA_STORAGE=$NOQUOTA_NAME
NOQUOTA_MOUNT=$NOQUOTA_MOUNT
STORAGE_TYPE=bcachefs
BCACHEFS_MOUNT=$MOUNT
BCACHEFS_DEVICES=${#DISKS[@]}
BCACHEFS_PRJQUOTA=$QUOTA
CFG
