# pve-bcachefs

LXC-focused bcachefs storage plugin for Proxmox VE 9 (storage APIVER 15).
**Work in progress.**

Containers live as plain bcachefs subvolumes (folders — no image files, no
loop devices), so snapshots, rollbacks and clones are native, instant bcachefs
operations. Per-storage IO policy (compression, replicas, tiering targets,
checksums) is applied via bcachefs per-directory options — multiple "pools"
with different characteristics on a single filesystem, straight from
`storage.cfg`.

## Requirements

- Proxmox VE 9.x
- bcachefs-tools + bcachefs-kernel-dkms ≥ 1.38 (apt.bcachefs.org)
- a mounted bcachefs filesystem

## Install

```
./install.sh                          # plugin only
perl patches/patch-pve-container.pl   # optional, see below
```

## storage.cfg example

```
bcachefs: ct-fast
        path /mnt/tank/pve/fast
        content rootdir
        bcachefs-foreground-target ssd
        bcachefs-promote-target ssd
        bcachefs-compression lz4
        bcachefs-data-replicas 2

bcachefs: ct-bulk
        path /mnt/tank/pve/bulk
        content rootdir,vztmpl,backup
        bcachefs-background-target hdd
        bcachefs-compression zstd
```

Point `path` at any directory on a bcachefs filesystem — the plugin verifies
the filesystem type on activation. Option changes are picked up on the next
storage activation and propagate to existing data in the background
(bcachefs "reconcile").

## Folder containers, sizes, and the pve-container patch

Unpatched Proxmox hardcodes: sized container rootfs on path-based storage →
raw image + ext4 on a loop device. Only **size 0** gets the subvolume (folder)
treatment:

```
pct create 123 ... --rootfs ct-fast:0     # folder container (recommended)
pct create 123 ... --rootfs ct-fast:8     # raw+ext4 fallback, still snapshottable
```

`patches/patch-pve-container.pl` lifts this (sized rootfs → folder on
bcachefs; size enforcement via quotas is TODO) and additionally enables
snapshot-mode vzdump backups for subvolume containers (upstream dies here even
on btrfs). The patch must be re-applied after `pve-container` upgrades; it is
exact-match and refuses to run against unknown code.

## Layout (btrfs-plugin parity)

```
<path>/images/<vmid>/subvol-<vmid>-disk-<n>.subvol/       container rootfs (subvolume)
<path>/images/<vmid>/vm-<vmid>-disk-<n>/disk.raw          sized fallback (raw in subvolume)
<path>/images/<vmid>/<volume>@<snapname>                  snapshots (read-only subvolumes)
```

## VM images

Enable `images` content on a storage to put VM disks on bcachefs: raw images,
each in its own subvolume (btrfs-plugin layout), so VM snapshots (incl. RAM
via vmstate volumes), rollback, templates and instant linked clones are native
subvolume operations. For write-heavy VMs consider a dedicated storage with
`bcachefs-nocow 1` (disables COW/checksums/compression for those images).

## Tested (PVE 9.2, bcachefs-tools/dkms 1.38.8, storage APIVER 13-15)

Unpatched: folder container create (size 0), snapshot / rollback / delete
(instant, with guest fs freeze), full clone of current state, template +
linked clone, sized fallback (raw+ext4 in snapshottable subvolume), extra
mountpoints, move-volume between storages, vzdump (stop/suspend) + restore,
vztmpl/backup content, per-storage IO options incl. tiering targets.

With `patch-pve-container.pl` additionally: sized containers as folders,
clone from snapshot, and snapshot-mode vzdump (~1s freeze; upstream btrfs
cannot do this).

VM lifecycle: create, live snapshot with vmstate, rollback with RAM restore,
full clone, template + linked clone, resize, destroy.

Additionally the [pve-storage-test-lab](https://github.com/arki05/pve-storage-test-lab)
pytest suite passes clean (44 passed, 11 skipped = multi-node/shared-only):
lifecycle, snapshot semantics, resize, storage moves, backup/restore
compositions, data integrity under fio load, regressions.

## Not (yet) supported

- size enforcement / quotas on subvolumes — blocked upstream: bcachefs 1.38.8
  implements no quotactl interface and rejects project IDs (verified
  empirically, even on a fresh fs formatted with `--prjquota=1`); revisit
  after bcachefs re-lands quotas on the new disk-accounting infrastructure
- send/receive-based migration (bcachefs has none; falls back to tar/rsync)
- `snapshot-as-volume-chain`, rename_snapshot, qcow2
