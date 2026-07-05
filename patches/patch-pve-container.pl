#!/usr/bin/perl

# Patches pve-container's LXC.pm for native bcachefs folder containers:
#
#   1. alloc_disk: allocate sized container rootfs as 'subvol' (folder) on
#      bcachefs storages instead of raw+ext4-on-loop.
#   2. mountpoint_mount: allow mounting snapshots of path-backed subvolumes
#      (read-only bind mount of the `name@snap` sibling directory) instead of
#      dying. Needed for vzdump snapshot-mode backups and `pct mount --snap`.
#
# Idempotent; keeps a pristine copy at LXC.pm.orig; refuses to apply on
# context mismatch (e.g. after a pve-container upgrade changed the code).
# Re-run after every pve-container package upgrade.
#
# Verified against: pve-container 6.1.10

use strict;
use warnings;

my $file = shift // '/usr/share/perl5/PVE/LXC.pm';

open(my $fh, '<', $file) or die "cannot open $file: $!\n";
my $src = do { local $/; <$fh> };
close($fh);

my $orig = "$file.orig";
if (!-e $orig) {
    open(my $o, '>', $orig) or die "cannot write $orig: $!\n";
    print {$o} $src;
    close($o);
    print "saved pristine copy to $orig\n";
}

my $changed = 0;

my $apply = sub {
    my ($name, $old, $new, $applied_marker) = @_;

    if (index($src, $applied_marker) >= 0) {
        print "$name: already applied\n";
        return;
    }
    my $i = index($src, $old);
    die "$name: context not found - unsupported pve-container version?\n" if $i < 0;
    die "$name: context found more than once - refusing to patch\n"
        if index($src, $old, $i + 1) >= 0;

    substr($src, $i, length($old)) = $new;
    $changed++;
    print "$name: applied\n";
};

# --- patch 1: alloc_disk ----------------------------------------------------

my $p1_old =
    q~if ($size_kb > 0 && !($scfg->{type} eq 'btrfs' && $scfg->{quotas})) {~;
my $p1_new =
    q~if ($size_kb > 0 && !($scfg->{type} eq 'btrfs' && $scfg->{quotas}) && $scfg->{type} ne 'bcachefs') {~;

$apply->('patch 1 (alloc_disk)', $p1_old, $p1_new, q~$scfg->{type} ne 'bcachefs'~);

# --- patch 2: mountpoint_mount ----------------------------------------------

my $p2_old = <<'EOF';
                    } else {
                        die "cannot mount subvol snapshots for storage type '$scfg->{type}'\n";
                    }
EOF

my $p2_new = <<'EOF';
                    } elsif ($scfg->{path}) {
                        # snapshot is a read-only sibling subvolume directory
                        # (btrfs/bcachefs style `name@snap`); $path already
                        # points at it, so a read-only bind mount suffices
                        bindmount(
                            $path,
                            $parentfd,
                            $last_dir // $rootdir,
                            $mount_path,
                            1,
                            @extra_opts,
                        );
                    } else {
                        die "cannot mount subvol snapshots for storage type '$scfg->{type}'\n";
                    }
EOF

$apply->('patch 2 (mountpoint_mount)', $p2_old, $p2_new,
    'points at it, so a read-only bind mount suffices');

# -----------------------------------------------------------------------------

if ($changed) {
    open(my $out, '>', $file) or die "cannot write $file: $!\n";
    print {$out} $src;
    close($out);

    if (system('perl', '-c', $file) != 0) {
        open($out, '>', $file) or die "PANIC: cannot restore $file: $!\n";
        open(my $in, '<', $orig) or die "PANIC: cannot read $orig: $!\n";
        print {$out} do { local $/; <$in> };
        close($in);
        close($out);
        die "patched file failed syntax check - restored original\n";
    }
    print "done - $changed patch(es) written, syntax check passed\n";
    print "restart container-related services or reboot to take effect\n";
} else {
    print "nothing to do\n";
}
