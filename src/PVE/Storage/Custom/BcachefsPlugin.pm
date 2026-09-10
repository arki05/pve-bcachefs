# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Julius Arkenberg
#
# Derived from PVE::Storage::BTRFSPlugin (part of pve-storage, AGPL-3.0+);
# see LICENSE.

package PVE::Storage::Custom::BcachefsPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use Fcntl qw(S_ISDIR O_RDONLY O_WRONLY O_CREAT O_EXCL O_DIRECTORY);
use File::Basename qw(basename dirname);
use File::Path qw(mkpath);

use PVE::Tools qw(run_command dir_glob_foreach file_get_contents file_set_contents);

use PVE::Storage::DirPlugin;

use constant {
    BCACHEFS_MAGIC => 0xca451a4e,

    # quotactl(2) / <linux/quota.h>
    Q_GETQUOTA => 0x800007,
    Q_SETQUOTA => 0x800008,
    PRJQUOTA => 2,
    QIF_BLIMITS => 1,
    # <linux/dqblk_xfs.h>
    Q_XGETQSTAT => 0x5805,
    FS_QUOTA_PDQ_ACCT => 0x10,
    # FS_IOC_FS{GET,SET}XATTR, for the inode project id
    FS_IOC_FSGETXATTR => 0x801c581f,
    FS_IOC_FSSETXATTR => 0x401c5820,
};

# Layout (btrfs-plugin parity):
#
#   `subvol-VMID-disk-N.subvol`
#     -> `images/VMID/subvol-VMID-disk-N.subvol/`        (bcachefs subvolume)
#   `vm-VMID-disk-N.raw`
#     -> `images/VMID/vm-VMID-disk-N/disk.raw`           (raw file in its own subvolume)
#
#   snapshots are read-only sibling subvolumes: `<subvolume-dir>@<snapname>`

# Declare the storage API version of the host we run on, clamped to the
# window this plugin is known to work with (the interfaces used here are
# stable across it). PVE::Storage is fully loaded before Custom/ plugins,
# so its APIVER constant is available.
my $API_MIN = 13;
my $API_MAX = 15;

sub api {
    my $host = eval { PVE::Storage::APIVER() } // $API_MAX;
    return $host < $API_MIN ? $API_MIN : $host > $API_MAX ? $API_MAX : $host;
}

sub type {
    return 'bcachefs';
}

sub plugindata {
    return {
        content => [
            {
                images => 1,
                rootdir => 1,
                vztmpl => 1,
                iso => 1,
                backup => 1,
                snippets => 1,
                none => 1,
            },
            { rootdir => 1 },
        ],
        # 'raw' default matters for VM disks (containers always request their
        # format explicitly); a raw image lives in its own subvolume so it
        # snapshots exactly like a container subvolume does
        format => [{ raw => 1, subvol => 1 }, 'raw'],
        'sensitive-properties' => {},
    };
}

# All properties are prefixed with 'bcachefs-' because storage section config
# property names share a single global namespace across every plugin.
sub properties {
    return {
        'bcachefs-compression' => {
            description => "Compression type for foreground writes (e.g. lz4, zstd, zstd:15).",
            type => 'string',
            pattern => '[a-z0-9_]+(:[0-9]+)?',
        },
        'bcachefs-background-compression' => {
            description => "Compression type applied by background rewrites.",
            type => 'string',
            pattern => '[a-z0-9_]+(:[0-9]+)?',
        },
        'bcachefs-data-replicas' => {
            description => "Number of data replicas for volumes on this storage.",
            type => 'integer',
            minimum => 1,
            maximum => 8,
        },
        'bcachefs-data-checksum' => {
            description => "Checksum type for data writes.",
            type => 'string',
            enum => ['none', 'crc32c', 'crc64', 'xxhash'],
        },
        'bcachefs-foreground-target' => {
            description => "Device or label targeted by foreground writes (e.g. ssd).",
            type => 'string',
            pattern => '[A-Za-z0-9._-]+',
        },
        'bcachefs-background-target' => {
            description => "Device or label data is moved to in the background (e.g. hdd).",
            type => 'string',
            pattern => '[A-Za-z0-9._-]+',
        },
        'bcachefs-promote-target' => {
            description => "Device or label hot data is promoted (cached) to on read.",
            type => 'string',
            pattern => '[A-Za-z0-9._-]+',
        },
        'bcachefs-nocow' => {
            description => "Disable copy-on-write for volumes on this storage (also disables"
                . " data checksumming and compression for them). Reduces write amplification"
                . " for VM images.",
            type => 'boolean',
        },
        'bcachefs-erasure-code' => {
            description => "Store data on this storage with erasure coding (parity) rather"
                . " than whole replicas, trading write overhead for usable capacity. Needs"
                . " enough devices to satisfy bcachefs-data-replicas as parity stripes.",
            type => 'boolean',
        },
        'bcachefs-subvol-rootfs' => {
            description => "Place container rootfs volumes as bcachefs subvolumes (folder"
                . " containers) instead of ext4 inside a raw image. Sizes are then enforced"
                . " with project quotas, which requires the filesystem to have prjquota"
                . " enabled; without it sizes are recorded but not enforced. Requires"
                . " patches/patch-pve-container.pl for rootfs volumes with a size.",
            type => 'boolean',
        },
    };
}

sub options {
    return {
        path => { fixed => 1 },
        nodes => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        format => { optional => 1 },
        is_mountpoint => { optional => 1 },
        mkdir => { optional => 1 },
        'create-base-path' => { optional => 1 },
        'create-subdirs' => { optional => 1 },
        'prune-backups' => { optional => 1 },
        'max-protected-backups' => { optional => 1 },
        'bcachefs-compression' => { optional => 1 },
        'bcachefs-background-compression' => { optional => 1 },
        'bcachefs-data-replicas' => { optional => 1 },
        'bcachefs-data-checksum' => { optional => 1 },
        'bcachefs-foreground-target' => { optional => 1 },
        'bcachefs-background-target' => { optional => 1 },
        'bcachefs-promote-target' => { optional => 1 },
        'bcachefs-nocow' => { optional => 1 },
        'bcachefs-erasure-code' => { optional => 1 },
        'bcachefs-subvol-rootfs' => { optional => 1 },
    };
}

sub check_config {
    my ($self, $sectionId, $config, $create, $skipSchemaCheck) = @_;
    return PVE::Storage::DirPlugin::check_config($self, $sectionId, $config, $create,
        $skipSchemaCheck);
}

my sub getfsmagic($) {
    my ($path) = @_;
    # only the first field (f_type) of struct statfs is needed
    my $buf = pack('x160');
    if (0 != syscall(&PVE::Syscall::SYS_statfs, $path, $buf)) {
        die "statfs on '$path' failed - $!\n";
    }

    return unpack('L!', $buf);
}

my sub assert_bcachefs($) {
    my ($path) = @_;
    die "'$path' is not on a bcachefs file system\n"
        if getfsmagic($path) != BCACHEFS_MAGIC;
}

# The nominal size of a subvolume volume is tracked in an xattr on the
# subvolume root (there is nothing to enforce it against until bcachefs
# regains quota support, but PVE relies on volume_size_info for resize
# arithmetic and display). The 'trusted' namespace keeps it out of reach
# of (unprivileged) container root.
my $SIZE_XATTR = 'trusted.pve.size';

# The quota project id of a volume, recorded on its anchor directory. It is
# stored rather than derived from the volume name because `rename_volume` can
# move a volume to a different vmid, while project inheritance is applied at
# creation only and never retroactively - a derived id would silently start
# pointing at a project the data was never charged to.
my $PROJID_XATTR = 'trusted.pve.projid';

my sub set_num_xattr($$$) {
    my ($path, $attr, $value) = @_;
    my $str = "$value";
    if (
        0 != syscall(
            &PVE::Syscall::SYS_setxattr, $path, $attr, $str, length($str), 0,
        )
    ) {
        die "failed to set '$attr' on '$path' - $!\n";
    }
}

my sub get_num_xattr($$) {
    my ($path, $attr) = @_;
    my $buf = pack('x32');
    my $len = syscall(&PVE::Syscall::SYS_getxattr, $path, $attr, $buf, 32);
    return undef if $len <= 0;
    my $value = substr($buf, 0, $len);
    return $value =~ /^(\d+)$/ ? $1 : undef;
}

my sub set_size_xattr($$) {
    my ($path, $size_bytes) = @_;
    set_num_xattr($path, $SIZE_XATTR, $size_bytes);
}

my sub get_size_xattr($) {
    my ($path) = @_;
    return get_num_xattr($path, $SIZE_XATTR);
}

# --- project quotas ---------------------------------------------------------
#
# bcachefs enforces user/group/project quotas, but ONLY for inodes in a
# non-snapshot ("master") subvolume: bch2_quota_reservation_add() returns early
# for anything carrying EI_INODE_SNAPSHOT, so writes to a subvolume created by
# `bcachefs subvolume snapshot` are never charged and can never hit -EDQUOT.
# That is why clone/rollback below build a fresh master subvolume and reflink
# the data in, rather than taking a snapshot: a volume that is written to must
# always be a master. Snapshots themselves stay O(1) - nothing writes to them.
#
# Caveat worth knowing: hard limits are ignored for callers holding
# CAP_SYS_RESOURCE, so a *privileged* container escapes enforcement entirely.
#
# quotactl(2) addresses a filesystem by block device, which cannot work for a
# multi-device bcachefs (it only accepts the first device and returns ENODEV
# for the others), so we use quotactl_fd(2) with a directory fd on the mount.

# Two deliberate details here, both of them Perl syscall(2) footguns:
#
#  - The buffer is passed by reference. Commands that read data back have the
#    kernel write into the scalar's own storage, so it must be the caller's
#    scalar rather than the copy `my (...) = @_` would make.
#
#  - $cmd and $id are forced to integers. syscall() passes an SV that only
#    holds a string as a POINTER to those bytes, so a project id that arrived
#    as a string (from a regex capture, say) would silently address a garbage
#    quota id instead of the intended one. The failure is self-consistent -
#    reading back with the same string returns what you just wrote - so it
#    looks like it works right up until something reads with an integer.
my sub quotactl_fd($$$$) {
    my ($path, $cmd, $id, $bufref) = @_;

    sysopen(my $fh, $path, O_RDONLY | O_DIRECTORY)
        or die "failed to open '$path' - $!\n";
    my $ret = syscall(
        &PVE::Syscall::SYS_quotactl_fd, fileno($fh), int($cmd), int($id), $$bufref,
    );
    close($fh);

    return $ret;
}

my sub qcmd($$) {
    my ($cmd, $type) = @_;
    return ($cmd << 8) | ($type & 0xff);
}

# Is project-quota accounting actually active on this filesystem? Without it
# Q_SETQUOTA still *succeeds* and silently enforces nothing, so this has to be
# checked explicitly rather than inferred from a successful set.
my sub prjquota_enabled($) {
    my ($path) = @_;

    # struct fs_quota_stat: qs_version (in) at offset 0, qs_flags at offset 2
    my $buf = pack('C x511', 1);
    my $ret = eval { quotactl_fd($path, qcmd(Q_XGETQSTAT, PRJQUOTA), 0, \$buf) };
    return 0 if $@ || !defined($ret) || $ret != 0;

    return (unpack('x2 S', $buf) & FS_QUOTA_PDQ_ACCT) ? 1 : 0;
}

# struct if_dqblk: 8 x __u64 followed by __u32 dqb_valid, padded to 72 bytes.
# Block limits are in 1024-byte units; dqb_curspace is in bytes.
my sub set_project_limit($$$) {
    my ($path, $projid, $bytes) = @_;

    my $blocks = int(($bytes + 1023) / 1024);
    my $buf = pack('Q8 L x4', $blocks, $blocks, 0, 0, 0, 0, 0, 0, QIF_BLIMITS);
    my $ret = quotactl_fd($path, qcmd(Q_SETQUOTA, PRJQUOTA), $projid, \$buf);
    die "failed to set project quota $projid on '$path' - $!\n" if $ret != 0;
}

# Returns ($limit_bytes, $used_bytes), or the empty list if unavailable.
my sub get_project_usage($$) {
    my ($path, $projid) = @_;

    my $buf = pack('x72');
    my $ret = eval { quotactl_fd($path, qcmd(Q_GETQUOTA, PRJQUOTA), $projid, \$buf) };
    return () if $@ || !defined($ret) || $ret != 0;

    my ($bhard, undef, $curspace) = unpack('Q3', $buf);
    return ($bhard * 1024, $curspace);
}

# Project IDs are derived from the volume name so that they are stable across
# reboots and need no separate bookkeeping: `<prefix>-<vmid>-disk-<n>`.
my $PROJID_DISKS_PER_VMID = 16;

my sub projid_for_name($) {
    my ($name) = @_;

    return undef if $name !~ /^(?:subvol|vm|base)-(\d+)-disk-(\d+)/;
    my ($vmid, $idx) = ($1, $2);

    die "disk index $idx exceeds the $PROJID_DISKS_PER_VMID disks per guest that"
        . " quota project ids can address\n"
        if $idx >= $PROJID_DISKS_PER_VMID;

    my $projid = $vmid * $PROJID_DISKS_PER_VMID + $idx;
    die "vmid $vmid is too large to map onto a quota project id\n"
        if $projid > 0xffffffff;

    return $projid;
}

# struct fsxattr is 5 x __u32 followed by 8 pad bytes; fsx_projid is the 4th.
my sub get_projid($) {
    my ($path) = @_;

    sysopen(my $fh, $path, O_RDONLY | O_DIRECTORY)
        or die "failed to open '$path' - $!\n";
    my $fsx = pack('x28');
    my $ok = eval { ioctl($fh, FS_IOC_FSGETXATTR, $fsx) };
    close($fh);
    return undef if !$ok;

    return (unpack('L5', $fsx))[3];
}

my sub set_projid($$) {
    my ($path, $projid) = @_;

    sysopen(my $fh, $path, O_RDONLY | O_DIRECTORY)
        or die "failed to open '$path' - $!\n";
    my $fsx = pack('x28');
    my $ok = eval {
        ioctl($fh, FS_IOC_FSGETXATTR, $fsx) or die "FS_IOC_FSGETXATTR failed - $!\n";
        my ($xflags, $extsize, $nextents, undef, $cowextsize) = unpack('L5', $fsx);
        $fsx = pack('L5 x8', $xflags, $extsize, $nextents, $projid, $cowextsize);
        ioctl($fh, FS_IOC_FSSETXATTR, $fsx) or die "FS_IOC_FSSETXATTR failed - $!\n";
        1;
    };
    my $err = $@;
    close($fh);
    die $err if !$ok;
}

# A clone/rollback target must be a master subvolume, so the data is reflinked
# in rather than snapshotted. Extents stay shared - this costs a metadata walk,
# not disk space.
my sub reflink_copy_tree($$) {
    my ($src, $dst) = @_;

    run_command(
        ['cp', '-a', '--reflink=always', "$src/.", "$dst/"],
        errmsg => "failed to reflink '$src' into '$dst'",
    );
}

# --- volume layout ------------------------------------------------------------
#
# A subvol volume is a bcachefs subvolume named `data` inside a plain "anchor"
# directory named after the volume:
#
#   images/<vmid>/subvol-<vmid>-disk-<N>.subvol/            anchor (plain dir)
#   images/<vmid>/subvol-<vmid>-disk-<N>.subvol/data        the subvolume
#   images/<vmid>/subvol-<vmid>-disk-<N>.subvol/data@<snap> snapshots
#
# The anchor exists so the quota project id can live on a directory the volume
# *inherits* from rather than on the volume root itself. bcachefs grows a
# settable `bcachefs.project` xattr on any inode whose project id was set
# explicitly, and rejects setxattr on it (upstream declares the option
# OPT_BOOL, so only 0/1 parse) - which makes `rsync -X`, what PVE uses for full
# container clones, fail with exit 23. An inherited project id exposes only the
# read-only `bcachefs_effective.project`, which rsync leaves alone.
#
# An alternative that needs no anchor is to set the project id explicitly and
# then demote it to inherited with removexattr('bcachefs.project') - see
# projid_set_inherited() below. It is used for migration, and is the route to
# take if this layout ever needs to be flattened again.
#
# Volumes created before the anchor existed are still read in place:
#
#   images/<vmid>/subvol-<vmid>-disk-<N>.subvol             the subvolume itself
#
# so an existing storage keeps working untouched. Only new volumes get an
# anchor; flat volumes simply have no project id and are not enforced.
#
# Raw volumes are unchanged and never get a project id: a raw image is already
# limited by its own file size.

my $SUBVOL_INNER = 'data';

# Returns ($anchor, $volume_path) for a subvol volume, honouring both layouts.
my sub subvol_paths($$) {
    my ($imagedir, $name) = @_;

    my $anchor = "$imagedir/$name";
    return ($anchor, "$anchor/$SUBVOL_INNER") if -d "$anchor/$SUBVOL_INNER";
    return (undef, $anchor);
}

# The anchor of an existing volume path, or undef for a flat (pre-anchor) one.
my sub anchor_of($) {
    my ($volume_path) = @_;
    return basename($volume_path) eq $SUBVOL_INNER ? dirname($volume_path) : undef;
}

# True when this storage should place container rootfs volumes as subvolumes
# (and manage project quotas for them) rather than as ext4-in-a-raw-image.
my sub use_subvol_rootfs($) {
    my ($scfg) = @_;
    return $scfg->{'bcachefs-subvol-rootfs'} ? 1 : 0;
}

# Quota management is active only when this storage places rootfs volumes as
# subvolumes AND the filesystem can actually enforce. When it cannot, clone and
# rollback keep their cheap O(1) snapshot behaviour - there is nothing to
# protect, so there is no reason to pay for a reflink walk.
my sub quota_mode($) {
    my ($scfg) = @_;
    return (use_subvol_rootfs($scfg) && prjquota_enabled($scfg->{path})) ? 1 : 0;
}

# Called from the patched pve-container to decide whether a sized container
# rootfs on this storage is placed as a subvolume or as a raw image.
#
# This mirrors the test upstream already applies to btrfs, which uses a folder
# only when the storage declares `quotas` - i.e. only when it can enforce a size
# on the result. If the filesystem cannot enforce one, falling back to a raw
# image is the safer answer: the image enforces its own size, whereas a folder
# would silently be unlimited. Existing subvolume volumes are unaffected and
# keep working; they simply are not enforced.
#
# Public on purpose: this is the plugin's interface to patch 1.
sub subvol_rootfs_active {
    my ($scfg) = @_;

    return 0 if !$scfg->{'bcachefs-subvol-rootfs'};
    return 1 if quota_mode($scfg);

    warn "bcachefs: project quotas are unavailable on '$scfg->{path}', so a raw"
        . " image is being allocated instead of a subvolume - its size can be"
        . " enforced, a subvolume's could not. Enable prjquota on the"
        . " filesystem to get folder containers.\n";

    return 0;
}

# The project id of a volume, taken from its anchor. Allocated from the volume
# name on first use and then recorded, so it survives a rename to another vmid.
my sub anchor_projid($$) {
    my ($anchor, $name) = @_;

    return undef if !defined($anchor);

    my $projid = get_num_xattr($anchor, $PROJID_XATTR);
    return $projid if defined($projid);

    $projid = projid_for_name($name);
    return undef if !defined($projid);

    set_num_xattr($anchor, $PROJID_XATTR, $projid);
    return $projid;
}

# Stamp the project id on the anchor. Must run BEFORE the subvolume inside it is
# created, so that the subvolume - and everything later created within it -
# inherits the id instead of carrying it explicitly.
my sub attach_anchor_project($$$) {
    my ($scfg, $anchor, $name) = @_;

    return if !quota_mode($scfg);

    my $projid = anchor_projid($anchor, $name);
    return if !defined($projid);

    set_projid($anchor, $projid);
}

my sub set_volume_limit($$$$) {
    my ($scfg, $anchor, $name, $bytes) = @_;

    return if !quota_mode($scfg);

    my $projid = anchor_projid($anchor, $name);
    return if !defined($projid);

    set_project_limit($scfg->{path}, $projid, $bytes);
}

# A rollback has to lift the volume's limit while the old and new copies
# coexist (see volume_snapshot_rollback). If we die in between, the limit would
# stay lifted, so the intent is recorded here and replayed on next activation.
my $QUOTA_INFLIGHT = '.pve-bcachefs-quota-inflight';

my sub quota_inflight_mark($$$) {
    my ($scfg, $projid, $bytes) = @_;
    eval { file_set_contents("$scfg->{path}/$QUOTA_INFLIGHT", "$projid $bytes\n") };
    warn "failed to record in-flight quota state: $@" if $@;
}

my sub quota_inflight_repair($) {
    my ($scfg) = @_;

    my $file = "$scfg->{path}/$QUOTA_INFLIGHT";
    return if !-e $file;

    my $content = eval { file_get_contents($file) } // '';
    for my $line (split(/\n/, $content)) {
        next if $line !~ /^(\d+)\s+(\d+)$/;
        my ($projid, $bytes) = (int($1), int($2));
        eval { set_project_limit($scfg->{path}, $projid, $bytes) };
        warn "failed to restore quota project $projid: $@" if $@;
    }
    unlink($file);
}

my sub clear_volume_quota($$$) {
    my ($scfg, $anchor, $name) = @_;

    return if !quota_mode($scfg);

    my $projid = eval { anchor_projid($anchor, $name) };
    return if !defined($projid);

    # a zero limit means "unlimited", i.e. the id is free for reuse
    eval { set_project_limit($scfg->{path}, $projid, 0) };
    warn "failed to release quota project $projid: $@" if $@;
}

# Demote an explicitly-set project id to an inherited one. bcachefs implements
# removexattr('bcachefs.project') as "take the parent directory's project and
# clear the explicitly-set bit", performing the quota transfer on the way, so
# this leaves the id intact while removing the settable xattr that breaks
# `rsync -X`. Used to fold pre-anchor volumes into the anchored layout.
my sub projid_set_inherited($$) {
    my ($volume_path, $projid) = @_;

    my $parent = dirname($volume_path);
    my $saved = eval { get_projid($parent) } // 0;

    set_projid($parent, $projid);
    my $err;
    if (0 != syscall(&PVE::Syscall::SYS_removexattr, $volume_path, 'bcachefs.project')) {
        $err = "failed to demote project id on '$volume_path' - $!\n";
    }
    eval { set_projid($parent, $saved) };
    warn "failed to restore project id on '$parent': $@" if $@;

    die $err if $err;
}

my $fs_option_map = {
    'bcachefs-compression' => 'compression',
    'bcachefs-background-compression' => 'background_compression',
    'bcachefs-data-replicas' => 'data_replicas',
    'bcachefs-data-checksum' => 'data_checksum',
    'bcachefs-foreground-target' => 'foreground_target',
    'bcachefs-background-target' => 'background_target',
    'bcachefs-promote-target' => 'promote_target',
    'bcachefs-nocow' => 'nocow',
    'bcachefs-erasure-code' => 'erasure_code',
};

# Apply the configured IO-path options to the storage base directory. bcachefs
# propagates them recursively and new files inherit them. Since propagation
# walks the whole tree, only re-run when the configured set actually changed
# (activate_storage is called by pvestatd every few seconds).
my sub apply_fs_options {
    my ($class, $storeid, $scfg) = @_;

    my $path = $scfg->{path};

    my @args;
    for my $prop (sort keys %$fs_option_map) {
        my $value = $scfg->{$prop};
        next if !defined($value);
        push @args, "--$fs_option_map->{$prop}=$value";
    }
    return if !@args;

    my $desired = join(' ', @args);
    my $statefile = "$path/.pve-bcachefs-options";
    my $current = eval { file_get_contents($statefile) } // '';
    chomp $current;
    return if $current eq $desired;

    run_command(
        ['bcachefs', 'set-file-option', @args, $path],
        errmsg => "failed to apply bcachefs options on '$path'",
    );
    file_set_contents($statefile, "$desired\n");
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $path = $scfg->{path};
    $class->config_aware_base_mkdir($scfg, $path);

    my $mp = PVE::Storage::DirPlugin::parse_is_mountpoint($scfg);
    if (defined($mp) && !PVE::Storage::DirPlugin::path_is_mounted($mp, $cache->{mountdata})) {
        die "unable to activate storage '$storeid' - directory is expected to be a mount point but"
            . " is not mounted: '$mp'\n";
    }

    assert_bcachefs($path);

    # Warn rather than die: new volumes fall back to raw images, which enforce
    # their own size, and existing subvolume volumes keep working unenforced.
    # Failing activation would take the whole storage offline instead.
    if (use_subvol_rootfs($scfg) && !prjquota_enabled($path)) {
        warn "storage '$storeid': project quotas are not enabled on the filesystem at"
            . " '$path' - new container rootfs volumes will be allocated as raw images"
            . " rather than subvolumes, and any existing subvolume volumes are NOT"
            . " size-enforced. Enable quotas by adding 'prjquota' to the mount options,"
            . " or offline with 'bcachefs set-fs-option --prjquota=1 <device>'.\n";
    }

    eval { quota_inflight_repair($scfg) if quota_mode($scfg) };
    warn "storage '$storeid': $@" if $@;

    eval { apply_fs_options($class, $storeid, $scfg) };
    warn "storage '$storeid': $@" if $@;

    $class->SUPER::activate_storage($storeid, $scfg, $cache);
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    return PVE::Storage::DirPlugin::status($class, $storeid, $scfg, $cache);
}

sub get_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute) = @_;
    return PVE::Storage::DirPlugin::get_volume_attribute($class, $scfg, $storeid, $volname,
        $attribute);
}

sub update_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute, $value) = @_;
    return PVE::Storage::DirPlugin::update_volume_attribute(
        $class, $scfg, $storeid, $volname, $attribute, $value,
    );
}

sub __error {
    my ($msg) = @_;
    my (undef, $f, $n) = caller(1);
    die "$msg at $f: $n\n";
}

sub raw_name_to_dir($) {
    my ($raw) = @_;

    if ($raw =~ /^(.*)\.raw$/) {
        return $1;
    }

    __error "internal error: bad disk name: $raw";
}

sub raw_file_to_subvol($) {
    my ($file) = @_;

    if ($file =~ m|^(.*)/disk\.raw$|) {
        return "$1";
    }

    __error "internal error: bad raw path: $file";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    my ($vtype, $name, $vmid, undef, undef, $isBase, $format) = $class->parse_volname($volname);

    my $path = $class->get_subdir($scfg, $vtype);

    $path .= "/$vmid" if $vtype eq 'images';

    if ($vtype eq 'images' && defined($format) && $format eq 'raw') {
        my $dir = raw_name_to_dir($name);
        if ($snapname) {
            $dir .= "\@$snapname";
        }
        $path .= "/$dir/disk.raw";
    } elsif ($vtype eq 'images' && defined($format) && $format eq 'subvol') {
        my (undef, $volume_path) = subvol_paths($path, $name);
        $path = $volume_path;
        $path .= "\@$snapname" if $snapname;
    } else {
        $path .= "/$name";
    }

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub bcachefs_cmd {
    my ($class, $cmd, $outfunc) = @_;

    my $msg = '';
    my $func;
    if (defined($outfunc)) {
        $func = sub {
            my $part = &$outfunc(@_);
            $msg .= $part if defined($part);
        };
    } else {
        $func = sub { $msg .= "$_[0]\n" };
    }
    run_command(
        ['bcachefs', @$cmd],
        errmsg => "command 'bcachefs @$cmd' failed",
        outfunc => $func,
    );

    return $msg;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format) =
        $class->parse_volname($volname);

    if ($format ne 'raw' && $format ne 'subvol') {
        return PVE::Storage::Plugin::create_base(@_);
    }

    my $newname = $name;
    $newname =~ s/^(vm|subvol)-/base-/;

    my $path = $class->filesystem_path($scfg, $volname);
    my $newvolname = $basename ? "$basevmid/$basename/$vmid/$newname" : "$vmid/$newname";
    my $newpath = $class->filesystem_path($scfg, $newvolname);

    my $subvol = $path;
    my $newsubvol = $newpath;
    if ($format eq 'raw') {
        $subvol = raw_file_to_subvol($subvol);
        $newsubvol = raw_file_to_subvol($newsubvol);
    }

    rename($subvol, $newsubvol)
        || die "rename '$subvol' to '$newsubvol' failed - $!\n";

    # NOTE: unlike btrfs there is no way to flip an existing subvolume to
    # read-only; base volume immutability is enforced at the PVE level only.

    return $newvolname;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my ($vtype, $basename, $basevmid, undef, undef, $isBase, $format) =
        $class->parse_volname($volname);

    if ($format ne 'raw' && $format ne 'subvol') {
        return PVE::Storage::DirPlugin::clone_image(@_);
    }

    my $imagedir = $class->get_subdir($scfg, 'images');
    $imagedir .= "/$vmid";
    mkpath $imagedir;

    my $path = $class->filesystem_path($scfg, $volname, $snap);
    my $newname = $class->find_free_diskname($storeid, $scfg, $vmid, $format, 1);

    my $newvolname = "$vmid/$newname";
    my $newpath = $class->filesystem_path($scfg, $newvolname);

    my $subvol = $path;
    my $newsubvol = $newpath;
    my $anchor;
    if ($format eq 'raw') {
        $subvol = raw_file_to_subvol($subvol);
        $newsubvol = raw_file_to_subvol($newsubvol);
    } else {
        $anchor = "$imagedir/$newname";
        mkdir($anchor)
            or die "failed to create '$anchor' - $!\n";
        eval { attach_anchor_project($scfg, $anchor, $newname) };
        if (my $err = $@) {
            rmdir($anchor);
            die $err;
        }
        $newsubvol = "$anchor/$SUBVOL_INNER";
    }

    my $bytes = $format eq 'subvol' ? get_size_xattr($subvol) : undef;

    eval {
        if ($format eq 'subvol' && quota_mode($scfg)) {
            # A snapshot subvolume can never be quota-enforced, so build a
            # master and reflink the data in. Extents are shared either way -
            # this costs a metadata walk, not disk space.
            $class->bcachefs_cmd(['subvolume', 'create', $newsubvol]);
            reflink_copy_tree($subvol, $newsubvol);
        } else {
            # snapshots are writable by default - a clone is simply a snapshot
            $class->bcachefs_cmd(['subvolume', 'snapshot', $subvol, $newsubvol]);
        }
        set_volume_limit($scfg, $anchor, $newname, $bytes) if defined($bytes);
    };
    if (my $err = $@) {
        eval { $class->bcachefs_cmd(['subvolume', 'delete', $newsubvol]) };
        warn $@ if $@;
        rmdir($anchor) if defined($anchor);
        die $err;
    }

    return $newvolname;
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    if ($fmt ne 'raw' && $fmt ne 'subvol') {
        return $class->SUPER::alloc_image($storeid, $scfg, $vmid, $fmt, $name, $size);
    }

    my $imagedir = $class->get_subdir($scfg, 'images') . "/$vmid";

    mkpath $imagedir;

    $name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt, 1) if !$name;

    my (undef, $tmpfmt) = PVE::Storage::Plugin::parse_name_dir($name);

    die "illegal name '$name' - wrong extension for format ('$tmpfmt != '$fmt')\n"
        if $tmpfmt ne $fmt;

    my $subvol = "$imagedir/$name";
    # .raw is not part of the directory name
    $subvol =~ s/\.raw$//;

    die "disk image '$subvol' already exists\n" if -e $subvol;

    my ($path, $anchor);
    if ($fmt eq 'raw') {
        $path = "$subvol/disk.raw";
    } else {
        # New subvol volumes are always anchored: the anchor carries the project
        # id and must exist, and be stamped, before the subvolume is created so
        # that the subvolume inherits it rather than owning it explicitly.
        $anchor = $subvol;
        mkdir($anchor)
            or die "failed to create '$anchor' - $!\n";
        eval { attach_anchor_project($scfg, $anchor, $name) };
        if (my $err = $@) {
            rmdir($anchor);
            die $err;
        }
        $subvol = "$anchor/$SUBVOL_INNER";
    }

    $class->bcachefs_cmd(['subvolume', 'create', $subvol]);

    eval {
        if ($fmt eq 'subvol' && !!$size) {
            set_size_xattr($subvol, $size * 1024);
            set_volume_limit($scfg, $anchor, $name, $size * 1024);
        } elsif ($fmt eq 'raw') {
            sysopen my $fh, $path, O_WRONLY | O_CREAT | O_EXCL
                or die "failed to create raw file '$path' - $!\n";
            truncate($fh, $size * 1024)
                or die "failed to set file size for '$path' - $!\n";
            close($fh);
        }
    };

    if (my $err = $@) {
        eval { $class->bcachefs_cmd(['subvolume', 'delete', $subvol]); };
        warn $@ if $@;
        rmdir($anchor) if defined($anchor);
        die $err;
    }

    return "$vmid/$name";
}

# Calls `$code->($snap_name)` for each snapshot of the subvolume. Snapshots are
# siblings of the volume named `<volume>@<snapshot>`, so this works for both the
# anchored and the flat layout without needing to know which is in use.
my sub foreach_snapshot_of_subvol : prototype($$) {
    my ($subvol, $code) = @_;

    my $basename = basename($subvol);
    my $dir = dirname($subvol);
    dir_glob_foreach(
        $dir,
        qr/\Q$basename\E\@(\S+)/,
        sub {
            # dir_glob_foreach matches against `^($regex)$`, wrapping the caller's
            # pattern in a capture of its own, so the arguments are the whole
            # entry followed by our own captures.
            my ($entry, $snap_name) = @_;
            return if !defined($snap_name);
            return if !-d "$dir/$entry";
            $code->($snap_name);
        },
    );
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $_format) = @_;

    my ($vtype, $name, $vmid, undef, undef, undef, $format) = $class->parse_volname($volname);

    if (!defined($format) || $vtype ne 'images' || ($format ne 'subvol' && $format ne 'raw')) {
        return $class->SUPER::free_image($storeid, $scfg, $volname, $isBase, $_format);
    }

    my $path = $class->filesystem_path($scfg, $volname);

    my $subvol = $path;
    if ($format eq 'raw') {
        $subvol = raw_file_to_subvol($path);
    }

    my @snapshot_vols;
    foreach_snapshot_of_subvol(
        $subvol,
        sub {
            my ($snap_name) = @_;
            push @snapshot_vols, "$subvol\@$snap_name";
        },
    );

    for my $vol (@snapshot_vols, $subvol) {
        $class->bcachefs_cmd(['subvolume', 'delete', $vol]);
    }
    my $anchor = $format eq 'subvol' ? anchor_of($subvol) : undef;
    clear_volume_quota($scfg, $anchor, $name) if $format eq 'subvol';
    rmdir($anchor) if defined($anchor);
    # cleanup: don't leave empty $vmid dirs around after the last image is gone
    my $dir = dirname(defined($anchor) ? $anchor : $subvol);
    rmdir($dir);

    return undef;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $path = $class->filesystem_path($scfg, $volname);

    my $format = ($class->parse_volname($volname))[6];

    if (defined($format) && $format eq 'subvol') {
        my $ctime = (stat($path))[10];
        my $size = get_size_xattr($path) // 0;
        my $used = 0;

        # where quotas are in play the kernel tracks real usage, and its limit
        # is authoritative; the xattr only records the size we asked for
        if (use_subvol_rootfs($scfg)) {
            my $name = ($class->parse_volname($volname))[1];
            my $projid = eval { anchor_projid(anchor_of($path), $name) };
            if (defined($projid)) {
                my ($limit, $curspace) = get_project_usage($scfg->{path}, $projid);
                $used = $curspace if defined($curspace);
                $size = $limit if $limit;
            }
        }

        return wantarray ? ($size, 'subvol', $used, undef, $ctime) : $size;
    }

    return PVE::Storage::Plugin::file_size_info($path, $timeout, $format);
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;

    my ($name, $format) = ($class->parse_volname($volname))[1, 6];
    if ($format eq 'subvol') {
        die "resizing a snapshot is not supported\n" if $snapname;
        my $path = $class->filesystem_path($scfg, $volname);
        set_size_xattr($path, $size);
        # a no-op unless this storage enforces sizes with project quotas
        set_volume_limit($scfg, anchor_of($path), $name, $size);
        return undef;
    }

    return PVE::Storage::Plugin::volume_resize(@_);
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my ($name, $vmid, $format) = ($class->parse_volname($volname))[1, 2, 6];
    if ($format ne 'subvol' && $format ne 'raw') {
        return PVE::Storage::Plugin::volume_snapshot(@_);
    }

    my $path = $class->filesystem_path($scfg, $volname);
    my $snap_path = $class->filesystem_path($scfg, $volname, $snap);

    if ($format eq 'raw') {
        $path = raw_file_to_subvol($path);
        $snap_path = raw_file_to_subvol($snap_path);
    }

    $class->bcachefs_cmd(['subvolume', 'snapshot', '--read-only', $path, $snap_path]);
    return undef;
}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;

    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my ($name, $format) = ($class->parse_volname($volname))[1, 6];

    if ($format ne 'subvol' && $format ne 'raw') {
        return PVE::Storage::Plugin::volume_snapshot_rollback(@_);
    }

    my $path = $class->filesystem_path($scfg, $volname);
    my $snap_path = $class->filesystem_path($scfg, $volname, $snap);

    if ($format eq 'raw') {
        $path = raw_file_to_subvol($path);
        $snap_path = raw_file_to_subvol($snap_path);
    }

    # create the new (writable) state first, then atomically exchange it with
    # the current subvolume, so a failure can never leave us without a volume
    my $tmp_path = "$path.tmp.$$";

    my ($projid, $limit_bytes);
    if ($format eq 'subvol' && quota_mode($scfg)) {
        $projid = anchor_projid(anchor_of($path), $name);
        $limit_bytes = get_size_xattr($path);

        # Rolling back into a snapshot would permanently disable enforcement for
        # this volume, so the new state is built as a master and reflinked from
        # the snapshot instead. Both copies are charged to the same project
        # while they coexist, hence the temporary lift.
        if (defined($projid) && $limit_bytes) {
            quota_inflight_mark($scfg, $projid, $limit_bytes);
            set_project_limit($scfg->{path}, $projid, 0);
        }

        # $tmp_path is a sibling of $path, so under the anchored layout it
        # inherits the anchor's project id on creation - it must never be set
        # explicitly here, or the volume would grow the settable
        # `bcachefs.project` xattr that breaks `rsync -X`.
        $class->bcachefs_cmd(['subvolume', 'create', $tmp_path]);
        eval {
            reflink_copy_tree($snap_path, $tmp_path);
        };
        if (my $err = $@) {
            eval { $class->bcachefs_cmd(['subvolume', 'delete', $tmp_path]) };
            warn $@ if $@;
            quota_inflight_repair($scfg);
            die $err;
        }
    } else {
        $class->bcachefs_cmd(['subvolume', 'snapshot', $snap_path, $tmp_path]);
    }

    my $ok = PVE::Tools::renameat2(-1, $tmp_path, -1, $path, &PVE::Tools::RENAME_EXCHANGE);

    eval { $class->bcachefs_cmd(['subvolume', 'delete', $tmp_path]) };
    warn "failed to remove '$tmp_path' subvolume: $@" if $@;

    quota_inflight_repair($scfg) if defined($projid);

    if (!$ok) {
        die "failed to rotate '$tmp_path' into place at '$path' - $!\n";
    }

    return undef;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my ($name, $vmid, $format) = ($class->parse_volname($volname))[1, 2, 6];

    if ($format ne 'subvol' && $format ne 'raw') {
        return PVE::Storage::Plugin::volume_snapshot_delete(@_);
    }

    my $path = $class->filesystem_path($scfg, $volname, $snap);

    if ($format eq 'raw') {
        $path = raw_file_to_subvol($path);
    }

    $class->bcachefs_cmd(['subvolume', 'delete', $path]);

    return undef;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
        snapshot => {
            current => { raw => 1, subvol => 1 },
            snap => { raw => 1, subvol => 1 },
        },
        clone => {
            base => { raw => 1, subvol => 1 },
            current => { raw => 1, subvol => 1 },
            snap => { raw => 1, subvol => 1 },
        },
        template => {
            current => { raw => 1, subvol => 1 },
        },
        copy => {
            base => { raw => 1, subvol => 1 },
            current => { raw => 1, subvol => 1 },
            snap => { raw => 1, subvol => 1 },
        },
        sparseinit => {
            base => { raw => 1 },
            current => { raw => 1 },
        },
        rename => {
            current => { raw => 1, subvol => 1 },
        },
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format) =
        $class->parse_volname($volname);

    my $key = undef;
    if ($snapname) {
        $key = 'snap';
    } else {
        $key = $isBase ? 'base' : 'current';
    }

    return 1 if defined($features->{$feature}->{$key}->{$format});

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    my $imagedir = $class->get_subdir($scfg, 'images');

    my $res = [];
    my $subvol_quotas = use_subvol_rootfs($scfg);

    foreach my $fn (<$imagedir/[0-9][0-9]*/*>) {
        # the regex excludes '@' so snapshots are not listed as volumes
        next if $fn !~ m@^(/.+/(\d+)/([^/\@.]+(?:\.(subvol))?))$@;
        $fn = $1; # untaint

        my $owner = $2;
        my $name = $3;
        my $ext = $4;

        next if !$vollist && defined($vmid) && ($owner ne $vmid);

        my $volid = "$storeid:$owner/$name";
        my ($size, $format, $used, $parent, $ctime);

        if (!$ext) { # raw
            $volid .= '.raw';
            $format = 'raw';
            ($size, undef, $used, $parent, $ctime) =
                PVE::Storage::Plugin::file_size_info("$fn/disk.raw", undef, $format);
        } else {
            $format = 'subvol';
            # $fn is the anchor for volumes that have one, the subvolume itself
            # for pre-anchor ones
            my $anchored = -d "$fn/$SUBVOL_INNER";
            my $volume_path = $anchored ? "$fn/$SUBVOL_INNER" : $fn;
            ($size, $used) = (get_size_xattr($volume_path) // 0, 0);
            if ($subvol_quotas && $anchored) {
                my $projid = eval { anchor_projid($fn, $name) };
                if (defined($projid)) {
                    my ($limit, $curspace) = get_project_usage($scfg->{path}, $projid);
                    $used = $curspace if defined($curspace);
                    $size = $limit if $limit;
                }
            }
        }
        next if !defined($size);

        if ($vollist) {
            next if !grep { $_ eq $volid } @$vollist;
        }

        my $info = {
            volid => $volid,
            format => $format,
            size => $size,
            vmid => $owner,
            used => $used,
            parent => $parent,
        };

        $info->{ctime} = $ctime if $ctime;

        push @$res, $info;
    }

    return $res;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;
    die "no path found\n" if !$scfg->{path};

    my $format = ($class->parse_volname($source_volname))[6];

    if ($format ne 'raw' && $format ne 'subvol') {
        return $class->SUPER::rename_volume(
            $scfg, $storeid, $source_volname, $target_vmid, $target_volname,
        );
    }

    $target_volname = $class->find_free_diskname($storeid, $scfg, $target_vmid, $format, 1)
        if !$target_volname;
    $target_volname = "$target_vmid/$target_volname";

    my $basedir = $class->get_subdir($scfg, 'images');

    mkpath "${basedir}/${target_vmid}";

    my $source_dir = $source_volname;
    my $target_dir = $target_volname;
    if ($format eq 'raw') {
        $source_dir = raw_name_to_dir($source_volname);
        $target_dir = raw_name_to_dir($target_volname);
    }

    my $old_path = "${basedir}/${source_dir}";
    my $new_path = "${basedir}/${target_dir}";

    die "target volume '${target_volname}' already exists\n" if -e $new_path;

    # An anchored subvol volume keeps its snapshots inside the anchor, so moving
    # the anchor moves them too - and the anchor carries the recorded project
    # id, so the volume stays charged to the same project across the rename.
    # Pre-anchor volumes keep their snapshots as siblings and need them moved.
    my $anchored = $format eq 'subvol' && -d "$old_path/$SUBVOL_INNER";

    my @snapshots;
    if (!$anchored) {
        foreach_snapshot_of_subvol(
            ($format eq 'raw' ? raw_file_to_subvol("$old_path/disk.raw") : $old_path),
            sub { push @snapshots, $_[0]; },
        );
    }

    rename $old_path, $new_path
        || die "rename '$old_path' to '$new_path' failed - $!\n";

    for my $snap (@snapshots) {
        rename "$old_path\@$snap", "$new_path\@$snap"
            or warn "failed to move snapshot '$old_path\@$snap' - $!\n";
    }

    return "${storeid}:$target_volname";
}

sub rename_snapshot {
    my ($class, $scfg, $storeid, $volname, $source_snap, $target_snap) = @_;

    die "rename_snapshot is not supported for $class";
}

sub get_import_metadata {
    return PVE::Storage::DirPlugin::get_import_metadata(@_);
}

1;
