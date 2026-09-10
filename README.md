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
- for enforced container sizes: project quotas enabled on that filesystem
  (see [Size enforcement](#size-enforcement)) — no `quota` package needed,
  the plugin talks to `quotactl_fd(2)` directly

## Install

From the package (recommended):

```
apt install ./pve-bcachefs_<version>_all.deb
```

The package installs the storage plugin, patches `PVE::LXC`, and re-applies
that patch automatically after every `pve-container` upgrade via a dpkg
trigger — the patch does not survive upgrades on its own. Removing the package
restores the original `PVE::LXC`.

Set `APPLY_LXC_PATCH=no` in `/etc/default/pve-bcachefs` to install the storage
plugin without touching `pve-container`; sized container rootfs volumes then
land as raw images, which works and enforces its own size.

To build the package:

```
make deb          # produces ../pve-bcachefs_<version>_all.deb
```

From a checkout, without packaging:

```
./install.sh                          # plugin only
perl patches/patch-pve-container.pl   # optional, see below
```

## storage.cfg example

```
bcachefs: ct-fast
        path /mnt/tank/pve/fast
        content rootdir
        bcachefs-subvol-rootfs 1
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

`patches/patch-pve-container.pl` lifts this for storages that set
`bcachefs-subvol-rootfs 1`, and additionally enables snapshot-mode vzdump
backups for subvolume containers (upstream dies here even on btrfs). The patch
must be re-applied after `pve-container` upgrades; it is exact-match and
refuses to run against unknown code.

The option is the single switch between the two layouts:

| `bcachefs-subvol-rootfs` | prjquota on the fs | container rootfs | size enforcement |
|---|---|---|---|
| unset (default) | — | ext4 in a raw image, on a loop device | hard, by the image size |
| `1` | yes | bcachefs subvolume (folder) | project quotas, see below |
| `1` | no | ext4 in a raw image (fallback) | hard, by the image size |

The option asks for folder containers; it only gets them where the filesystem
can enforce a size on one. If project quotas are unavailable the plugin falls
back to a raw image rather than handing out an unlimited folder, and warns on
every activation and every allocation. Subvolume volumes created earlier keep
working, unenforced.

## Layout

```
<path>/images/<vmid>/subvol-<vmid>-disk-<n>.subvol/            anchor directory
<path>/images/<vmid>/subvol-<vmid>-disk-<n>.subvol/data        container rootfs (subvolume)
<path>/images/<vmid>/subvol-<vmid>-disk-<n>.subvol/data@<snap> snapshots (read-only subvolumes)
<path>/images/<vmid>/vm-<vmid>-disk-<n>/disk.raw               raw image (in a subvolume)
<path>/images/<vmid>/vm-<vmid>-disk-<n>@<snap>/disk.raw        raw snapshots
```

Container rootfs volumes live one level down, inside an **anchor** directory
named after the volume. The anchor exists so the quota project ID can sit on a
directory the volume *inherits* from, rather than on the volume root itself —
see [Size enforcement](#size-enforcement). It also keeps each volume's
snapshots in their own directory instead of sharing one with every sibling
volume. Raw volumes are unchanged: they keep btrfs-plugin parity and never get
a project ID, because a raw image is already limited by its own file size.

Volumes created before the anchor existed are still read in place, so an
existing storage keeps working after an upgrade — only newly created volumes
are anchored. Pre-anchor volumes carry no project ID and are therefore not
size-enforced; recreate or clone them to convert.

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

## Size enforcement

With `bcachefs-subvol-rootfs 1`, each container rootfs gets a bcachefs project
ID derived from its volume name, and its size is enforced as a project quota.
This needs project quotas enabled on the filesystem — one of:

```
# per mount (add `prjquota` to the fstab options; applies on next mount)
UUID=…  /mnt/tank  bcachefs  defaults,noatime,prjquota  0 0

# or persistently in the superblock, with the filesystem UNMOUNTED
bcachefs set-fs-option --prjquota=1 /dev/…

# or at format time
bcachefs format --prjquota …
```

Verify with `bcachefs show-super <dev> | grep prjquota`, or just watch for the
plugin's warning: if the option is on but the filesystem cannot enforce, sizes
are still recorded and reported but **not** enforced, and `activate_storage`
says so on every activation. It warns rather than fails, so a misconfigured
filesystem degrades instead of taking the storage offline.

### Why the anchor directory

bcachefs grows a settable `bcachefs.project` xattr on any inode whose project
ID was set *explicitly*, and then rejects `setxattr` on it (upstream declares
the option `OPT_BOOL`, so only 0/1 parse). `rsync -X` — which PVE uses for full
container clones — dutifully tries to copy that xattr and fails with exit 23,
breaking `pct clone`. A project ID that is *inherited* exposes only the
read-only `bcachefs_effective.project`, which rsync leaves alone. Putting the
ID on an anchor directory the volume inherits from therefore keeps clones
working, at no runtime cost.

The alternative, if this layout is ever flattened again: set the ID explicitly
and then demote it to inherited with `removexattr("bcachefs.project")`, which
bcachefs implements as "adopt the parent's project and clear the explicitly-set
bit", quota transfer included. `projid_set_inherited()` in the plugin does
exactly this and is used to fold pre-anchor volumes into the new layout.

The project ID is recorded in a `trusted.pve.projid` xattr on the anchor rather
than derived from the volume name, so that a volume renamed to another guest
stays charged to the project its data was actually accounted to.

Three consequences of how bcachefs implements this:

- **Privileged containers are not limited.** Hard limits are ignored for
  callers holding `CAP_SYS_RESOURCE`, which a privileged container's root has.
  Unprivileged containers are enforced normally.
- **Clone and rollback are no longer O(1).** bcachefs never enforces quotas on
  a subvolume created by `subvolume snapshot`, so a volume that gets written to
  must be a "master" subvolume. Clone and rollback therefore create a master
  and reflink the data into it, which costs a metadata walk — measured at
  ~12,700 files/sec, so ~3 s for a 38k-file, 2.3 GB rootfs. Extents stay
  shared, so this costs no disk space. Taking and deleting snapshots is
  unaffected and stays instant.

- **`rsync -X` to a non-bcachefs storage fails.** Every inode on a bcachefs
  filesystem that has any file option set reports `bcachefs_effective.*`
  xattrs, and a filesystem that does not know that namespace rejects them with
  `EOPNOTSUPP`. This is not specific to quotas — it already applies to any
  storage using `bcachefs-compression` and friends — but enabling quotas adds
  `bcachefs_effective.project` to the set. It affects moving a volume to a
  storage on a different filesystem type.

Without the option, sizes are enforced by the raw image and none of the above
applies.

## Not (yet) supported
- send/receive-based migration (bcachefs has none; falls back to tar/rsync)
- `snapshot-as-volume-chain`, rename_snapshot, qcow2

## License

AGPL-3.0-or-later (see [LICENSE](LICENSE)). `BcachefsPlugin.pm` is a derivative
work of Proxmox's `PVE::Storage::BTRFSPlugin` (part of pve-storage, AGPL-3.0+),
so it carries the same license.
