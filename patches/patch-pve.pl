#!/usr/bin/perl

# Patches PVE for bcachefs. Four independent changes across three files and two
# packages, each applied and reverted on its own:
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
#    namespaces: `bcachefs.*`, the options explicitly set on an inode, and
#    `bcachefs_effective.*`, the options actually in force after inheritance -
#    which appear on every inode below a directory that sets any. Both are
#    accepted by setxattr on bcachefs and rejected with EOPNOTSUPP everywhere
#    else, so `rsync -X` reads them and aborts the transfer with exit 23 after
#    copying everything: moving a container off bcachefs fails.
#
#    Both are filtered, for different reasons. `bcachefs.*` describes IO policy
#    belonging to the source filesystem and means nothing on the destination.
#    `bcachefs_effective.*` should not be copied even between two bcachefs
#    filesystems: the values are derived, and writing them back pins what was
#    inherited as an explicit per-inode setting on every file, quietly
#    replacing inheritance with thousands of individual options.
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
# 3. Container and 4. VM migration accept bcachefs volumes. Both migration
#    paths decide whether a local volume can be migrated by consulting a
#    hardcoded list of storage types - `dir`, `btrfs`, `zfspool`, `lvmthin`,
#    `lvm` - which no third-party plugin can join. The machinery itself is
#    fine: PVE::Storage::Plugin already implements volume_export_formats, and
#    returns `tar+size` for exactly the subvolume format a bcachefs container
#    volume uses. It is simply never reached, and the failure reads as though
#    the plugin were at fault:
#
#      can't migrate local volume '...': storage type 'bcachefs' not supported
#
#    Both sites carry upstream's own TODO saying the check belongs in the
#    storage layer. Adding bcachefs to the lists is the local fix; asking the
#    plugin instead is the upstream one, and would make this patch unnecessary.
#
#   patch-pve.pl [--revert] [file]

use strict;
use warnings;

use File::Basename qw(basename);

my $revert = 0;
# --root prefixes every path, so the series can be exercised against a tree of
# fixtures rather than only against a live node.
my $root = '';
my @args;
while (defined(my $arg = shift @ARGV)) {
    if    ($arg eq '--revert') { $revert = 1; }
    elsif ($arg eq '--root')   { $root = shift @ARGV // ''; }
    else                       { push @args, $arg; }
}
my $only = shift(@args);

my $statedir = $root ? "$root/var/lib/pve-bcachefs" : '/var/lib/pve-bcachefs';

# A pristine copy per file. The name is flattened because two of these are
# called Migrate.pm and LXC.pm in different directories.
sub pristine_for {
    my ($path) = @_;
    (my $flat = $path) =~ s{^.*/usr/share/perl5/}{};
    $flat =~ s{/}{_}g;
    return -d $statedir ? "$statedir/$flat.orig" : "$path.orig";
}

my @FILES = (
    {
        path => '/usr/share/perl5/PVE/LXC.pm',
        owner => 'pve-container',
        patches => [
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
        ],
    },
    {
        path => '/usr/share/perl5/PVE/LXC/Migrate.pm',
        owner => 'pve-container',
        patches => [
            {
                name => 'container migration accepts bcachefs',
                marker => q~'bcachefs',~,
                from => join("\n",
                    q~            my $migratable_storages = [~,
                    q~                'dir', 'zfspool', 'lvmthin', 'lvm', 'btrfs',~,
                    q~            ];~,
                ),
                to => join("\n",
                    q~            my $migratable_storages = [~,
                    q~                'dir', 'zfspool', 'lvmthin', 'lvm', 'btrfs',~,
                    q~                # A third-party plugin cannot join this list, though the~,
                    q~                # machinery behind it is generic: Plugin.pm already exports~,
                    q~                # a subvolume as tar+size, which is exactly what a bcachefs~,
                    q~                # container volume is.~,
                    q~                'bcachefs',~,
                    q~            ];~,
                ),
            },
        ],
    },
    {
        path => '/usr/share/perl5/PVE/QemuMigrate.pm',
        owner => 'qemu-server',
        patches => [
            {
                name => 'VM migration accepts bcachefs',
                marker => q~lvm|bcachefs)~,
                # Brace-quoted: these contain `=~`, and a tilde would end a
                # q~...~ literal half way through.
                from => q{my $migratable = $scfg->{type} =~ /^(?:dir|btrfs|zfspool|lvmthin|lvm)$/;},
                to => q{my $migratable = $scfg->{type} =~ /^(?:dir|btrfs|zfspool|lvmthin|lvm|bcachefs)$/;},
            },
        ],
    },
);

# Earlier releases wrote different forms of patch 1. They have to be reverted
# before the current one can apply.
my @STALE = (q~$scfg->{type} ne 'bcachefs'~, q~$scfg->{'bcachefs-subvol-rootfs'}~);

my $changed_any = 0;
my @done;

for my $file (@FILES) {
    my $path = $root . $file->{path};
    next if defined($only) && $only ne $path && $only ne $file->{path};

    if (!-e $path) {
        # qemu-server need not be installed on a container-only host.
        print "$path is not present (from $file->{owner}); skipping\n";
        next;
    }

    open(my $fh, '<', $path) or die "cannot open $path: $!\n";
    my $src = do { local $/; <$fh> };
    close($fh);

    my $orig = pristine_for($path);

    if (!$revert) {
        for my $stale (@STALE) {
            next if index($src, $stale) < 0;
            die "an older version of this patch is applied to $path ($stale).\n"
                . "Restore the pristine file first:  cp $orig $path\n";
        }
    }

    my $changed = 0;
    for my $patch (@{ $file->{patches} }) {
        my ($from, $to, $verb) = $revert
            ? ($patch->{to}, $patch->{from}, 'reverted')
            : ($patch->{from}, $patch->{to}, 'applied');

        my $present = index($src, $patch->{marker}) >= 0;
        if ($revert ? !$present : $present) {
            print "$patch->{name}: already $verb\n";
            next;
        }

        # Save a pristine copy before the first change to this file, and only
        # from a file this run has not modified yet.
        if (!$revert && !-e $orig && !$changed) {
            open(my $o, '>', $orig) or die "cannot write $orig: $!\n";
            print {$o} $src;
            close($o);
            print "saved pristine copy to $orig\n";
        }

        my $i = index($src, $from);
        die "context for '$patch->{name}' not found in $path"
            . " - unsupported $file->{owner} version?\n" if $i < 0;
        die "context for '$patch->{name}' found more than once in $path"
            . " - refusing to patch\n" if index($src, $from, $i + 1) >= 0;

        substr($src, $i, length($from)) = $to;
        $changed = 1;
        push @done, "$patch->{name}: $verb";
    }

    next if !$changed;
    $changed_any = 1;

    open(my $out, '>', $path) or die "cannot write $path: $!\n";
    print {$out} $src;
    close($out);

    if (system('perl', '-c', $path) != 0) {
        if (-e $orig) {
            open($out, '>', $path) or die "PANIC: cannot restore $path: $!\n";
            open(my $in, '<', $orig) or die "PANIC: cannot read $orig: $!\n";
            print {$out} do { local $/; <$in> };
            close($in);
            close($out);
            die "patched $path failed its syntax check - restored the original\n";
        }
        die "patched $path failed its syntax check and no pristine copy exists\n";
    }
}

if (!$changed_any) {
    print "nothing to do\n";
    exit 0;
}

print "$_\n" for @done;
print "restart container-related services or reboot to take effect\n";
