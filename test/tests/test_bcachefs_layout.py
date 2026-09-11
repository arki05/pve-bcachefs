"""The anchored layout, and the xattr invariant it exists to preserve.

A volume is `images/<vmid>/<name>/data`: `<name>` is a plain directory holding
the project ID, and `data` is the subvolume, which inherits it. The indirection
is the whole point. Putting the project ID on the subvolume root means a
settable `bcachefs.project` xattr sits on the volume root, and `rsync -X` then
tries to reproduce it on the destination - which is how a move or a migration
fails after copying gigabytes.
"""

import os
import subprocess

import pytest

from conftest import needs_lxc
from helpers.data_guard import DataGuard

SUBVOL_INNER = "data"


def volume_path(pve, node, storage, volid: str) -> str:
    return pve.get(f"/nodes/{node}/storage/{storage}/content/{volid}")["path"]


def rootfs_volid(ct) -> str:
    return ct.config()["rootfs"].split(",")[0]


def xattrs(path: str) -> list[str]:
    out = subprocess.run(["getfattr", "--absolute-names", "-d", "-m", "-", path],
                         capture_output=True, text=True)
    return [line.split("=")[0] for line in out.stdout.splitlines()
            if line and not line.startswith("#")]


@needs_lxc
class TestAnchoredLayout:
    def test_rootfs_is_a_subvolume_named_data(self, create_ct, pve, node, storage,
                                              config):
        if config.get("BCACHEFS_PRJQUOTA") != "true":
            pytest.skip("no project quotas; rootfs falls back to a raw image")
        ct = create_ct()
        path = volume_path(pve, node, storage, rootfs_volid(ct))
        assert os.path.basename(path) == SUBVOL_INNER, (
            f"expected the volume to be the inner '{SUBVOL_INNER}' subvolume, got {path}"
        )
        assert os.path.isdir(path), f"{path} is not a directory"

    def test_no_settable_project_xattr_on_the_volume_root(self, create_ct, pve,
                                                          node, storage, config):
        """The invariant. A settable `bcachefs.project` on the volume root is
        what breaks `rsync -X`, and therefore move-volume and migration."""
        if config.get("BCACHEFS_PRJQUOTA") != "true":
            pytest.skip("no project quotas; nothing to project")
        ct = create_ct()
        path = volume_path(pve, node, storage, rootfs_volid(ct))
        names = xattrs(path)
        assert "bcachefs.project" not in names, (
            f"settable bcachefs.project is present on the volume root {path}: "
            f"{names} - this breaks rsync -X and every path that uses it"
        )

    @pytest.mark.xfail(
        strict=False,
        reason="known bcachefs behaviour: the bcachefs_effective.* virtual "
               "xattrs are reported by listxattr on every inode below one that "
               "sets an option, so rsync -X reads them and tries to reproduce "
               "them on the destination, where lsetxattr returns EOPNOTSUPP. "
               "See bcachefs-findings-and-reports.md. An XPASS here means it "
               "has been fixed and the workaround can go.",
    )
    def test_rsync_with_xattrs_off_the_volume(self, create_ct, pve, node, storage,
                                              config, tmp_path):
        """The concrete consequence of the effective-xattr bug.

        PVE's own move-volume and offline migration are `rsync -X`, so this
        failing means a container cannot be moved off bcachefs - and it fails
        late, after copying everything.
        """
        if config.get("BCACHEFS_PRJQUOTA") != "true":
            pytest.skip("no project quotas")
        ct = create_ct(start=True)
        DataGuard(ct.exec()).seed(size_mb=2, count=2)
        ct.stop()

        src = volume_path(pve, node, storage, rootfs_volid(ct))
        dst = "/var/tmp/rsync-xattr-check"
        subprocess.run(["rm", "-rf", dst], check=True)
        result = subprocess.run(
            ["rsync", "-aHAX", "--numeric-ids", f"{src}/", dst],
            capture_output=True, text=True, timeout=900,
        )
        subprocess.run(["rm", "-rf", dst], check=False)
        assert result.returncode == 0, (
            f"rsync -X off the volume failed (exit {result.returncode}):\n"
            f"{result.stderr[-1500:]}"
        )

    def test_rsync_succeeds_when_effective_xattrs_are_excluded(
            self, create_ct, pve, node, storage, config):
        """The workaround, asserted separately so the bug above and its fix do
        not share a single result. Excluding the virtual xattrs is what makes a
        move off bcachefs work at all today."""
        if config.get("BCACHEFS_PRJQUOTA") != "true":
            pytest.skip("no project quotas")
        ct = create_ct(start=True)
        DataGuard(ct.exec()).seed(size_mb=2, count=2)
        ct.stop()

        src = volume_path(pve, node, storage, rootfs_volid(ct))
        dst = "/var/tmp/rsync-xattr-filtered"
        subprocess.run(["rm", "-rf", dst], check=True)
        result = subprocess.run(
            ["rsync", "-aHAX", "--numeric-ids",
             "--filter=-x bcachefs_effective.*", "--filter=-x bcachefs.*",
             f"{src}/", dst],
            capture_output=True, text=True, timeout=900,
        )
        subprocess.run(["rm", "-rf", dst], check=False)
        assert result.returncode == 0, (
            f"even with the bcachefs xattrs excluded, rsync failed "
            f"(exit {result.returncode}):\n{result.stderr[-1500:]}"
        )

    def test_anchor_holds_the_project_id(self, create_ct, pve, node, storage,
                                         config):
        """The anchor directory - the volume's parent - is where the explicit
        project ID lives, so the subvolume can inherit it without carrying a
        settable xattr of its own."""
        if config.get("BCACHEFS_PRJQUOTA") != "true":
            pytest.skip("no project quotas")
        ct = create_ct()
        path = volume_path(pve, node, storage, rootfs_volid(ct))
        anchor = os.path.dirname(path)

        out = subprocess.run(["lsattr", "-p", "-d", anchor],
                             capture_output=True, text=True)
        assert out.returncode == 0, f"lsattr failed on the anchor: {out.stderr}"
        projid = int(out.stdout.split()[0])
        assert projid != 0, f"anchor {anchor} carries no project ID"
