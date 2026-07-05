package PVE::Storage::Custom::BcachefsPlugin;

use strict;
use warnings;

use base qw(PVE::Storage::Plugin);

use Fcntl qw(S_ISDIR O_WRONLY O_CREAT O_EXCL);
use File::Basename qw(basename dirname);
use File::Path qw(mkpath);

use PVE::Tools qw(run_command dir_glob_foreach file_get_contents file_set_contents);

use PVE::Storage::DirPlugin;

use constant {
    BCACHEFS_MAGIC => 0xca451a4e,
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
                rootdir => 1,
                vztmpl => 1,
                backup => 1,
                snippets => 1,
                none => 1,
            },
            { rootdir => 1 },
        ],
        format => [{ subvol => 1, raw => 1 }, 'subvol'],
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

my $fs_option_map = {
    'bcachefs-compression' => 'compression',
    'bcachefs-background-compression' => 'background_compression',
    'bcachefs-data-replicas' => 'data_replicas',
    'bcachefs-data-checksum' => 'data_checksum',
    'bcachefs-foreground-target' => 'foreground_target',
    'bcachefs-background-target' => 'background_target',
    'bcachefs-promote-target' => 'promote_target',
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
        $path .= "/$name";
        if ($snapname) {
            $path .= "\@$snapname";
        }
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
    if ($format eq 'raw') {
        $subvol = raw_file_to_subvol($subvol);
        $newsubvol = raw_file_to_subvol($newsubvol);
    }

    # snapshots are writable by default - a clone is simply a snapshot
    $class->bcachefs_cmd(['subvolume', 'snapshot', $subvol, $newsubvol]);

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

    my $path;
    if ($fmt eq 'raw') {
        $path = "$subvol/disk.raw";
    }

    if ($fmt eq 'subvol' && !!$size) {
        # TODO: enforce via bcachefs project quotas once verified to work
        warn "size ${size}k requested for '$name', but size enforcement for bcachefs"
            . " subvolumes is not implemented yet - creating unsized subvolume\n";
    }

    $class->bcachefs_cmd(['subvolume', 'create', $subvol]);

    eval {
        if ($fmt eq 'raw') {
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
        die $err;
    }

    return "$vmid/$name";
}

my $BCACHEFS_SNAPSHOT_REGEX = qr/((?:vm|base|subvol)-\d+-disk-\d+(?:\.subvol)?)(?:\@(\S+))$/;

# Calls `$code->($snap_name)` for each snapshot of the subvolume.
my sub foreach_snapshot_of_subvol : prototype($$) {
    my ($subvol, $code) = @_;

    my $basename = basename($subvol);
    my $dir = dirname($subvol);
    dir_glob_foreach(
        $dir,
        $BCACHEFS_SNAPSHOT_REGEX,
        sub {
            my ($volume, $name, $snap_name) = ($1, $2, $3);
            return if !-d "$dir/$volume";
            return if $name ne $basename;
            $code->($snap_name);
        },
    );
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase, $_format) = @_;

    my ($vtype, undef, $vmid, undef, undef, undef, $format) = $class->parse_volname($volname);

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
    # cleanup: don't leave empty $vmid dirs around after the last image is gone
    my $dir = dirname($subvol);
    rmdir($dir);

    return undef;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $path = $class->filesystem_path($scfg, $volname);

    my $format = ($class->parse_volname($volname))[6];

    if (defined($format) && $format eq 'subvol') {
        my $ctime = (stat($path))[10];
        my ($used, $size) = (0, 0);
        return wantarray ? ($size, 'subvol', $used, undef, $ctime) : $size;
    }

    return PVE::Storage::Plugin::file_size_info($path, $timeout, $format);
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running, $snapname) = @_;

    my $format = ($class->parse_volname($volname))[6];
    if ($format eq 'subvol') {
        die "cannot resize unsized bcachefs subvolume\n";
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
    $class->bcachefs_cmd(['subvolume', 'snapshot', $snap_path, $tmp_path]);
    my $ok = PVE::Tools::renameat2(-1, $tmp_path, -1, $path, &PVE::Tools::RENAME_EXCHANGE);

    eval { $class->bcachefs_cmd(['subvolume', 'delete', $tmp_path]) };
    warn "failed to remove '$tmp_path' subvolume: $@" if $@;

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
            ($used, $size) = (0, 0);
            $format = 'subvol';
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

    my @snapshots;
    foreach_snapshot_of_subvol(
        ($format eq 'raw' ? raw_file_to_subvol("$old_path/disk.raw") : $old_path),
        sub { push @snapshots, $_[0]; },
    );

    rename $old_path, $new_path
        || die "rename '$old_path' to '$new_path' failed - $!\n";

    # move snapshots along with the volume
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
