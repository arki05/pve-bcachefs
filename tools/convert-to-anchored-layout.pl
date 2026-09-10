#!/usr/bin/perl

# One-time migration: convert flat subvol volumes to the anchored layout.
#
#   images/<vmid>/subvol-<vmid>-disk-<n>.subvol         (the subvolume itself)
#     ->
#   images/<vmid>/subvol-<vmid>-disk-<n>.subvol/data    (inside an anchor dir)
#
# Only volumes created before the anchored layout existed need this. A fresh
# install never produces the flat form, so this is a migration tool rather than
# part of the plugin - run it once and forget it.
#
# No data is copied: the volume and its snapshots are renamed into place, which
# is why this takes seconds regardless of volume size.
#
#   convert-to-anchored-layout.pl [--dry-run] [--force] <storage-path> [vmid ...]
#
# --force skips the "is the container stopped" check. Don't.

use strict;
use warnings;

use File::Basename qw(basename dirname);
use File::Find ();
use PVE::Syscall;

my ($dry, $force) = (0, 0);
my @rest;
for (@ARGV) {
    if    ($_ eq '--dry-run') { $dry = 1 }
    elsif ($_ eq '--force')   { $force = 1 }
    else                      { push @rest, $_ }
}
my $base = shift(@rest) or die "usage: $0 [--dry-run] [--force] <storage-path> [vmid ...]\n";
my %only = map { $_ => 1 } @rest;

my $imagedir = "$base/images";
-d $imagedir or die "no images/ under '$base'\n";

# BCHFS_IOC_REINHERIT_ATTRS = _IOR(0xbc, 64, const char *)
#
# Re-applies the parent directory's inode options to a child that has not set
# them itself - marking them *inherited*, not explicit. That distinction is the
# whole point: a recursive `chattr -p` would fix accounting too, but would leave
# a settable `bcachefs.project` xattr on every file, which aborts `rsync -X`.
use constant BCHFS_IOC_REINHERIT_ATTRS => 0x8008bc40;

my $PROJID_DISKS_PER_VMID = 256;   # low 8 bits = disk index, covers mp0..mp255

sub projid_for_name {
    my ($name) = @_;
    return undef if $name !~ /^subvol-(\d+)-disk-(\d+)/;
    my ($vmid, $idx) = ($1, $2);
    return undef if $idx >= $PROJID_DISKS_PER_VMID;
    return $vmid * $PROJID_DISKS_PER_VMID + $idx;
}

sub run {
    my (@cmd) = @_;
    if ($dry) { print "    would run: @cmd\n"; return 1 }
    return system(@cmd) == 0;
}

# Reinherit one child of $dir by name.
sub reinherit_one {
    my ($dir, $name) = @_;
    open(my $dh, '<', $dir) or return 0;
    my $ok = ioctl($dh, BCHFS_IOC_REINHERIT_ATTRS, $name);
    close($dh);
    return $ok ? 1 : 0;
}

sub reinherit_tree {
    my ($root) = @_;
    return if $dry;

    # The root of the walk must be done first and from *its* parent - it is the
    # inode that adopts the anchor's project, and everything beneath it can only
    # inherit once it has. Skipping it leaves the whole tree at project 0.
    reinherit_one(dirname($root), basename($root));

    my $n = 1;
    File::Find::find({
        no_chdir => 1,
        wanted => sub {
            my $path = $File::Find::name;
            return if $path eq $root;
            # Failure here is not fatal: an inode that already carries an
            # explicit setting is skipped by the ioctl by design.
            reinherit_one(dirname($path), basename($path));
            $n++;
        },
    }, $root);
    return $n;
}

# The volume's nominal size, from whichever mountpoint entry references it.
sub size_from_config {
    my ($vmid, $name) = @_;
    my $cfg = `pct config $vmid 2>/dev/null` // '';
    for my $line (split /\n/, $cfg) {
        next if index($line, $name) < 0;
        next if $line !~ /size=(\d+)([KMGT])/;
        my ($n, $unit) = ($1, $2);
        my %mult = (K => 1024, M => 1024**2, G => 1024**3, T => 1024**4);
        return $n * $mult{$unit};
    }
    return undef;
}

# quotactl_fd(2): quotactl(2) takes a block device, useless for a multi-device
# bcachefs; this takes a directory fd on the mount instead.
sub set_project_limit {
    my ($path, $projid, $bytes) = @_;

    my $Q_SETQUOTA = 0x800008;
    my $PRJQUOTA   = 2;
    my $QIF_BLIMITS = 1;

    sysopen(my $fh, $path, 0)  or return 0;   # O_RDONLY
    my $blocks = int(($bytes + 1023) / 1024);
    # struct if_dqblk: 8 x __u64 then __u32 dqb_valid, padded to 72 bytes
    my $buf = pack('Q8 L x4', $blocks, $blocks, 0, 0, 0, 0, 0, 0, $QIF_BLIMITS);
    my $cmd = ($Q_SETQUOTA << 8) | $PRJQUOTA;
    my $ret = syscall(&PVE::Syscall::SYS_quotactl_fd, fileno($fh), $cmd, int($projid), $buf);
    close($fh);

    return $ret == 0 ? 1 : 0;
}

sub container_running {
    my ($vmid) = @_;
    my $out = `pct status $vmid 2>/dev/null` // '';
    return $out =~ /running/ ? 1 : 0;
}

my @converted;
for my $vmdir (sort glob("$imagedir/[0-9]*")) {
    my $vmid = basename($vmdir);
    next if %only && !$only{$vmid};

    for my $path (sort glob("$vmdir/subvol-*-disk-*.subvol")) {
        my $name = basename($path);
        next if $name =~ /\@/;                 # a snapshot, handled with its volume
        next if -d "$path/data";               # already anchored

        print "$vmid/$name\n";

        my $projid = projid_for_name($name);
        if (!defined($projid)) {
            print "    skipped: cannot derive a project id from the name\n";
            next;
        }

        if (!$force && container_running($vmid)) {
            print "    skipped: container $vmid is running (stop it, or --force)\n";
            next;
        }

        my $marker = "$vmdir/.pve-converting-$name";
        if (-e $marker) {
            print "    skipped: a previous run was interrupted here.\n";
            print "             Inspect $vmdir before retrying.\n";
            next;
        }

        my @snaps = map { basename($_) } glob("$vmdir/$name\@*");
        printf "    projid %d, %d snapshot(s)\n", $projid, scalar(@snaps);

        my $tmp = "$vmdir/.pve-convert-$name";
        if (!$dry) {
            open(my $mh, '>', $marker) or die "    cannot write marker\n";
            close($mh);
        }

        # Everything below is rename-only until the anchor is projected, so
        # source and destination both sit at project 0 and bcachefs never has to
        # reinherit anything across a directory boundary - which it refuses to
        # do (-EXDEV) for a directory whose inherited attributes would change.
        run('mv', $path, $tmp)                or die "    rename aside failed\n";
        run('mkdir', $path)                   or die "    mkdir anchor failed\n";
        run('mv', $tmp, "$path/data")         or die "    move into anchor failed\n";
        for my $snap (@snaps) {
            my ($sfx) = $snap =~ /\@(.+)$/;
            run('mv', "$vmdir/$snap", "$path/data\@$sfx")
                or warn "    could not move snapshot $sfx\n";
        }

        # Project the anchor, then push it down. Inheritance is applied at
        # creation only, so existing files keep project 0 until reinherited -
        # without this the volume reports zero usage and enforces nothing.
        run('chattr', '-p', $projid, $path)   or die "    chattr on anchor failed\n";
        run('setfattr', '-n', 'trusted.pve.projid', '-v', $projid, $path)
            or warn "    could not record trusted.pve.projid\n";

        my $n = reinherit_tree("$path/data");
        unless ($dry) {
            print "    reprojected " . ($n // 0) . " inodes\n";
            # Verify rather than trust: the ioctl's return value is not a
            # reliable success signal, and a volume that silently stayed at
            # project 0 would report no usage and enforce nothing.
            my $got = `lsattr -p -d "$path/data" 2>/dev/null`;
            $got = ($got =~ /^\s*(\d+)/) ? $1 : -1;
            warn "    WARNING: '$path/data' has project $got, expected $projid\n"
                if $got != $projid;
        }

        # Set the size and quota limit too. Volumes this old predate
        # trusted.pve.size, so the nominal size has to come from the container
        # config - without it the volume reports zero and enforces nothing,
        # which looks converted but is not.
        if (!$dry) {
            my $bytes = size_from_config($vmid, $name);
            if (defined($bytes)) {
                run('setfattr', '-n', 'trusted.pve.size', '-v', $bytes, "$path/data")
                    or warn "    could not record trusted.pve.size\n";
                set_project_limit($base, $projid, $bytes)
                    or warn "    could not set the quota limit\n";
                printf "    limit %.0f GiB applied\n", $bytes / (1024**3);
            } else {
                warn "    no size found in the config for $vmid - set it with pct resize\n";
            }
        }

        unlink($marker) unless $dry;
        push @converted, "$vmid/$name";
    }
}

print "\n" . scalar(@converted) . " volume(s) converted"
    . ($dry ? " (dry run, nothing changed)" : "") . "\n";
