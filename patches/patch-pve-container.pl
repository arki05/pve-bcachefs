#!/usr/bin/perl

# Patches pve-container's LXC.pm so that a sized container rootfs on a bcachefs
# storage is allocated as a subvolume (a folder) rather than as ext4 inside a
# raw image on a loop device.
#
# This mirrors what upstream already does for btrfs, which uses a folder only
# when the storage declares `quotas` - i.e. only when it can enforce a size on
# one. The decision is delegated to the plugin
# (BcachefsPlugin::subvol_rootfs_active), so a storage whose filesystem has no
# project quotas falls back to a raw image - which enforces its own size -
# rather than handing out an unlimited folder.
#
# Mounting snapshots of path-backed subvolumes used to live here too. It is not
# a bcachefs concern - it fixes btrfs just as much - and now belongs to
# pve-lxc-snapshot-mount, which this package depends on.
#
# Idempotent; keeps a pristine copy; refuses to apply against unrecognised code.
# Re-run after every pve-container upgrade (the package does this via a dpkg
# trigger).
#
#   patch-pve-container.pl [--revert] [file]

use strict;
use warnings;

use File::Basename qw(basename);

my $revert = 0;
my @args;
for (@ARGV) {
    if ($_ eq '--revert') { $revert = 1; } else { push @args, $_; }
}
my $file = shift(@args) // '/usr/share/perl5/PVE/LXC.pm';

open(my $fh, '<', $file) or die "cannot open $file: $!\n";
my $src = do { local $/; <$fh> };
close($fh);

my $statedir = '/var/lib/pve-bcachefs';
my $orig = -d $statedir ? "$statedir/" . basename($file) . '.orig' : "$file.orig";

# Earlier releases wrote different forms of this condition. They have to be
# reverted before the current one can apply.
if (!$revert) {
    for my $stale (q~$scfg->{type} ne 'bcachefs'~, q~$scfg->{'bcachefs-subvol-rootfs'}~) {
        next if index($src, $stale) < 0;
        die "an older version of this patch is applied ($stale).\n"
            . "Restore the pristine file first:  cp $orig $file\n";
    }
}

my $UNPATCHED =
    q~if ($size_kb > 0 && !($scfg->{type} eq 'btrfs' && $scfg->{quotas})) {~;

# `->can` keeps this harmless if the plugin is ever removed while the patch
# stays applied: the call is skipped and bcachefs behaves like any other
# path-based storage.
my $PATCHED =
    q~if ($size_kb > 0 && !($scfg->{type} eq 'btrfs' && $scfg->{quotas}) && !($scfg->{type} eq 'bcachefs' && PVE::Storage::Custom::BcachefsPlugin->can('subvol_rootfs_active') && PVE::Storage::Custom::BcachefsPlugin::subvol_rootfs_active($scfg))) {~;

my $MARKER = q~subvol_rootfs_active~;

my ($from, $to, $verb) =
    $revert ? ($PATCHED, $UNPATCHED, 'reverted') : ($UNPATCHED, $PATCHED, 'applied');

my $present = index($src, $MARKER) >= 0;
if ($revert ? !$present : $present) {
    print "subvolume rootfs allocation: already $verb\n";
    exit 0;
}

# Only save a pristine copy from a file that is actually pristine.
if (!$revert && !-e $orig) {
    open(my $o, '>', $orig) or die "cannot write $orig: $!\n";
    print {$o} $src;
    close($o);
    print "saved pristine copy to $orig\n";
}

my $i = index($src, $from);
die "context not found in $file - unsupported pve-container version?\n" if $i < 0;
die "context found more than once - refusing to patch\n"
    if index($src, $from, $i + 1) >= 0;

substr($src, $i, length($from)) = $to;

open(my $out, '>', $file) or die "cannot write $file: $!\n";
print {$out} $src;
close($out);

if (system('perl', '-c', $file) != 0) {
    if (-e $orig) {
        open($out, '>', $file) or die "PANIC: cannot restore $file: $!\n";
        open(my $in, '<', $orig) or die "PANIC: cannot read $orig: $!\n";
        print {$out} do { local $/; <$in> };
        close($in);
        close($out);
        die "patched file failed syntax check - restored original\n";
    }
    die "patched file failed syntax check and no pristine copy exists\n";
}

print "subvolume rootfs allocation: $verb\n";
print "restart container-related services or reboot to take effect\n";
