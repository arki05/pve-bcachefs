#!/usr/bin/perl

# Patches pve-container's LXC.pm for bcachefs. Two independent changes, each
# applied and reverted on its own:
#
# 1. Sized container rootfs volumes on a bcachefs storage are allocated as
#    subvolumes (folders) rather than as ext4 inside a raw image on a loop
#    device. This mirrors what upstream already does for btrfs, which uses a
#    folder only when the storage declares `quotas` - i.e. only when it can
#    enforce a size on one. The decision is delegated to the plugin
#    (BcachefsPlugin::subvol_rootfs_active), so a storage whose filesystem has
#    no project quotas falls back to a raw image - which enforces its own size
#    - rather than handing out an unlimited folder.
#
# 2. copy_volume's rsync does not try to copy bcachefs's internal virtual
#    xattrs. bcachefs reports its per-inode IO options through listxattr in two
#    namespaces: `bcachefs.*`, which are stored and settable, and
#    `bcachefs_effective.*`, which are computed after inheritance and cannot be
#    set anywhere at all. `rsync -X` reads both and tries to reproduce them on
#    the destination, where lsetxattr returns EOPNOTSUPP - so the transfer
#    aborts with exit 23 after copying everything, and moving a container off
#    bcachefs fails. Both namespaces are filtered: the effective one because it
#    can never be written, the stored one because it describes IO policy that
#    belongs to the source filesystem and means nothing on the destination.
#
#    This lived in pct-move-volume-snapshots until it was recognised as a
#    bcachefs concern rather than a move-volume one: it is needed with stock,
#    unpatched pve-container, and it fixes nothing for any other filesystem.
#
# Mounting snapshots of path-backed subvolumes is not here either. It is not a
# bcachefs concern - it fixes btrfs just as much - and belongs to
# pve-lxc-snapshot-mount, which this package depends on.
#
# Idempotent; keeps a pristine copy; refuses to apply against unrecognised
# code. Re-run after every pve-container upgrade (the package does this via a
# dpkg trigger).
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

# Earlier releases wrote different forms of patch 1. They have to be reverted
# before the current one can apply.
if (!$revert) {
    for my $stale (q~$scfg->{type} ne 'bcachefs'~, q~$scfg->{'bcachefs-subvol-rootfs'}~) {
        next if index($src, $stale) < 0;
        die "an older version of this patch is applied ($stale).\n"
            . "Restore the pristine file first:  cp $orig $file\n";
    }
}

# `->can` keeps patch 1 harmless if the plugin is ever removed while the patch
# stays applied: the call is skipped and bcachefs behaves like any other
# path-based storage.
my @PATCHES = (
    {
        name => 'subvolume rootfs allocation',
        marker => q~subvol_rootfs_active~,
        from => q~if ($size_kb > 0 && !($scfg->{type} eq 'btrfs' && $scfg->{quotas})) {~,
        to => q~if ($size_kb > 0 && !($scfg->{type} eq 'btrfs' && $scfg->{quotas}) && !($scfg->{type} eq 'bcachefs' && PVE::Storage::Custom::BcachefsPlugin->can('subvol_rootfs_active') && PVE::Storage::Custom::BcachefsPlugin::subvol_rootfs_active($scfg))) {~,
    },
    {
        name => 'copy_volume virtual xattr filter',
        marker => q~--filter=-x bcachefs_effective.*~,
        from => join("\n",
            q~            'rsync',~,
            q~            '--stats',~,
            q~            '-X',~,
            q~            '-A',~,
        ),
        to => join("\n",
            q~            'rsync',~,
            q~            '--stats',~,
            q~            '-X',~,
            q~            # filesystem-internal virtual xattrs (bcachefs exposes its~,
            q~            # per-inode IO options this way) cannot be set on other file~,
            q~            # systems and abort the transfer with EOPNOTSUPP on the target~,
            q~            '--filter=-x bcachefs.*',~,
            q~            '--filter=-x bcachefs_effective.*',~,
            q~            '-A',~,
        ),
    },
);

my $changed = 0;
my @done;

for my $patch (@PATCHES) {
    my ($from, $to, $verb) = $revert
        ? ($patch->{to}, $patch->{from}, 'reverted')
        : ($patch->{from}, $patch->{to}, 'applied');

    my $present = index($src, $patch->{marker}) >= 0;
    if ($revert ? !$present : $present) {
        print "$patch->{name}: already $verb\n";
        next;
    }

    # Save a pristine copy before the first change, and only from a file that
    # has not been modified yet by this run.
    if (!$revert && !-e $orig && !$changed) {
        open(my $o, '>', $orig) or die "cannot write $orig: $!\n";
        print {$o} $src;
        close($o);
        print "saved pristine copy to $orig\n";
    }

    my $i = index($src, $from);
    if ($i < 0) {
        die "context for '$patch->{name}' not found in $file"
            . " - unsupported pve-container version?\n";
    }
    if (index($src, $from, $i + 1) >= 0) {
        die "context for '$patch->{name}' found more than once - refusing to patch\n";
    }

    substr($src, $i, length($from)) = $to;
    $changed = 1;
    push @done, "$patch->{name}: $verb";
}

if (!$changed) {
    print "nothing to do\n";
    exit 0;
}

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

print "$_\n" for @done;
print "restart container-related services or reboot to take effect\n";
