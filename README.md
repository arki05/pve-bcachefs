# pve-bcachefs

[![storage lab](https://github.com/arki05/pve-bcachefs/actions/workflows/storage-lab.yml/badge.svg)](https://github.com/arki05/pve-bcachefs/actions/workflows/storage-lab.yml)

LXC-focused bcachefs storage plugin for Proxmox VE 9 (storage APIVER 15).
**Work in progress.**

The suite runs against real Proxmox nodes under QEMU via
[pve-storage-lab](https://github.com/arki05/pve-storage-lab). Each run attaches
a `summary.md` artifact with the full breakdown: what passed, what is a known
issue and why it is tolerated, and anything that failed without being declared
- which is the only thing that turns the run red.

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

From the apt repository (recommended):

```
install -d -m0755 /etc/apt/keyrings
curl -fsSL https://apt.arki05.com/pubkey.asc \
    | gpg --dearmor -o /etc/apt/keyrings/arki05.gpg
echo "deb [signed-by=/etc/apt/keyrings/arki05.gpg] https://apt.arki05.com trixie main" \
    > /etc/apt/sources.list.d/arki05.list
apt update && apt install pve-bcachefs
```

Signed, and carries both `amd64` and `arm64` indices — the package itself is
`Architecture: all`, so one build serves both. Every released version stays
installable, so `apt install pve-bcachefs=<version>` can pin an older one.

Or from a downloaded `.deb`, if you would rather not add a repository —
[releases](https://github.com/arki05/pve-bcachefs/releases):

```
apt install ./pve-bcachefs_<version>_all.deb
```

The package installs the storage plugin, patches `PVE::LXC`, and re-applies
that patch automatically after every `pve-container` upgrade via a dpkg
trigger — the patch does not survive upgrades on its own. Removing the package
restores the original `PVE::LXC`.

Mounting snapshots of those subvolumes — which snapshot-mode vzdump and
`pct mount --snap` need — is handled by
[pve-lxc-snapshot-mount](https://github.com/arki05/pve-lxc-snapshot-mount),
pulled in as a dependency. That fix is not bcachefs-specific (it repairs the
same gap for btrfs) so it lives in its own package rather than being duplicated
here.

To build the package:

```
make deb          # produces ../pve-bcachefs_<version>_all.deb
```

From a checkout, without packaging:

```
./install.sh                          # plugin only
perl patches/patch-pve-container.pl   # optional, see below
```

## Configuration

### Example

```
# fast tier: folder containers, enforced sizes, writes land on SSD and hot
# data is cached there, bulk data drifts down to spinning rust in the
# background
bcachefs: ct-fast
        path /mnt/tank/pve/fast
        content rootdir
        bcachefs-subvol-rootfs 1
        bcachefs-foreground-target ssd
        bcachefs-promote-target ssd
        bcachefs-background-target hdd
        bcachefs-compression lz4
        bcachefs-background-compression zstd:15
        bcachefs-data-replicas 2

# bulk tier: heavier compression, single replica, no folder containers so
# rootfs volumes are raw images
bcachefs: ct-bulk
        path /mnt/tank/pve/bulk
        content rootdir,vztmpl,backup
        bcachefs-background-target hdd
        bcachefs-compression zstd

# VM images; erasure coded rather than replicated, and the plugin keeps its
# hands off the filesystem options entirely
bcachefs: vm-store
        path /mnt/tank/pve/vm
        content images,iso
        bcachefs-erasure-code 1
        bcachefs-manage-options 0
```

Point `path` at any directory on a bcachefs filesystem — the plugin verifies
the filesystem type on activation. Several storages can share one filesystem,
each with different characteristics, which is the point of applying the options
per directory rather than per filesystem.

### Layout options

| option | type | default | effect |
|---|---|---|---|
| `bcachefs-subvol-rootfs` | boolean | off | Place container rootfs volumes as bcachefs subvolumes (folders) with sizes enforced by project quotas, instead of ext4 in a raw image. Requires `patches/patch-pve-container.pl`, and falls back to raw images if the filesystem has no project quotas. See [Size enforcement](#size-enforcement). |
| `bcachefs-manage-options` | boolean | on | Whether the plugin applies the IO options below to the storage directory. Set to `0` to manage bcachefs file options yourself. |

### bcachefs IO options

Each maps directly onto the corresponding `bcachefs set-file-option` option,
applied to the storage directory and inherited by everything inside it.

| option | type | maps to | effect |
|---|---|---|---|
| `bcachefs-compression` | e.g. `lz4`, `zstd`, `zstd:15` | `compression` | Compression for foreground writes. |
| `bcachefs-background-compression` | as above | `background_compression` | Compression applied later by background rewrites — lets you write fast and compress hard afterwards. |
| `bcachefs-data-replicas` | 1–8 | `data_replicas` | Number of replicas kept of the data. |
| `bcachefs-data-checksum` | `none`, `crc32c`, `crc64`, `xxhash` | `data_checksum` | Checksum algorithm for data writes. |
| `bcachefs-foreground-target` | device or label | `foreground_target` | Where foreground writes land. |
| `bcachefs-background-target` | device or label | `background_target` | Where data is migrated to in the background. |
| `bcachefs-promote-target` | device or label | `promote_target` | Where hot data is cached on read. |
| `bcachefs-erasure-code` | boolean | `erasure_code` | Store data with parity rather than whole replicas, trading write overhead for usable capacity. |
| `bcachefs-nocow` | boolean | `nocow` | Disable copy-on-write, and with it checksumming and compression, for data on this storage. See the warning below. |

Targets name a device (`/dev/sda`) or a device label/group assigned at format
time (`bcachefs format --label ssd.ssd1 …`). Combining
`foreground-target`/`promote-target` on flash with `background-target` on disk
is how you get a writeback-cached tier out of a single filesystem.

> **`bcachefs-nocow` is not a routine tuning knob.** Disabling copy-on-write is
> the usual advice on COW filesystems for write-heavy VM images, but on bcachefs
> it is the least settled code path, with an unresolved history of corruption
> and deadlock reports — including a hang in `bch2_fsync` when running
> `mkfs.ext4` against a nocow image, which is exactly the raw container rootfs
> path. Do not combine it with raw container volumes, and treat it as
> experimental generally.

### How they are applied

Option changes are picked up on the next storage activation and propagate to
existing data in the background (bcachefs "reconcile"). Options removed from
`storage.cfg` are cleared from the filesystem again.

Only the storage directory itself is managed. Options set explicitly on a
subdirectory — per guest, say — are never touched, at any depth, so manual
tuning coexists with what the plugin applies. `bcachefs-manage-options 0` keeps
the plugin away from the storage directory as well: it then never calls
`set-file-option` and never resets what it finds.

Options can be set at creation or changed later:

```
pvesm add bcachefs ct-fast --path /mnt/tank/pve/fast --content rootdir \
        --bcachefs-subvol-rootfs 1 --bcachefs-compression lz4

pvesm set ct-fast --bcachefs-data-replicas 2
pvesm set ct-fast --delete bcachefs-compression     # reset it on the filesystem too
```

To see what is actually in effect on disk:

```
bcachefs get-file-option /mnt/tank/pve/fast
```

## Folder containers, sizes, and the pve-container patch

Unpatched Proxmox hardcodes: sized container rootfs on path-based storage →
raw image + ext4 on a loop device. Only **size 0** gets the subvolume (folder)
treatment:

```
pct create 123 ... --rootfs ct-fast:0     # folder container (recommended)
pct create 123 ... --rootfs ct-fast:8     # raw+ext4 fallback, still snapshottable
```

`patches/patch-pve-container.pl` lifts this for storages that set
`bcachefs-subvol-rootfs 1`. It carries two independent changes to
`PVE::LXC`, each applied and reverted on its own. Both must be re-applied after
`pve-container` upgrades — the package does that automatically via a dpkg
trigger — and both are exact-match, refusing to run against unknown code.

The second change stops `copy_volume`'s `rsync -X` from trying to copy
bcachefs's internal virtual xattrs. bcachefs reports its per-inode IO options
through `listxattr` in two namespaces:

| namespace | what it is | appears on | settable |
|---|---|---|---|
| `bcachefs.*` | the options set on this inode | inodes that set one | bcachefs only |
| `bcachefs_effective.*` | the options in force after inheritance | **every** inode below one that sets any | bcachefs only |

`rsync -X` reads both and tries to reproduce them on the destination, where
`lsetxattr` returns `EOPNOTSUPP`. The transfer then aborts with exit 23 —
after copying everything — and moving a container off bcachefs fails.

Both are filtered, for different reasons. `bcachefs.*` describes IO policy
belonging to the source filesystem and means nothing on the destination.
`bcachefs_effective.*` should not be copied even *between two bcachefs
filesystems*: the values are derived, and writing them back pins what was
inherited as an explicit per-inode setting on every file, quietly replacing
inheritance with thousands of individual options.

This lived in
[pct-move-volume-snapshots](https://github.com/arki05/pct-move-volume-snapshots)
until it was recognised as a bcachefs concern rather than a move-volume one:
it is needed with stock, unpatched `pve-container`, and fixes nothing for any
other filesystem. If an older version of that package already applied it, this
patch adopts it rather than duplicating it.

Snapshot-mode vzdump backups of subvolume containers need a third, unrelated
fix: upstream cannot mount snapshots of path-backed subvolumes at all, on btrfs
or bcachefs. That one repairs btrfs just as much, so it is not ours either — it
lives in
[pve-lxc-snapshot-mount](https://github.com/arki05/pve-lxc-snapshot-mount).

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
subvolume operations.

Note that a raw VM image needs no project quota: it is already limited by its
own file size, so `bcachefs-subvol-rootfs` does not apply to it and no project
id is ever placed on one. The usual advice of disabling COW for write-heavy VM
images is deliberately **not** repeated here — see the `bcachefs-nocow` warning
under [Configuration](#bcachefs-io-options).

## Tested

### Quota mode — PVE 9.2.11, bcachefs 1.39.5, storage APIVER 15

Sized container create (lands as a folder, project id assigned, limit set);
enforcement from inside an unprivileged container (3000 MB requested into a 2 GB
volume yielded exactly 2.0 GB); resize; snapshot (~0.5 s, including at 100%
quota); rollback (data restored, the volume stays a master subvolume, limit
restored, enforcement still live); full clone (0.8 s) and enforcement on the
clone; rename across vmids (project id preserved rather than recomputed,
snapshots carried along); destroy (quota released, directories cleaned);
pre-anchor flat volumes still listed, started and freed (including one with 9
snapshots); and the raw-image fallback on a filesystem without project quotas.

Package lifecycle: install onto a hand-patched host, `pve-container` reinstall
re-applying the patch via the dpkg trigger, and removal reversing it.

### Earlier — PVE 9.2, bcachefs-tools/dkms 1.38.8, storage APIVER 13-15

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
