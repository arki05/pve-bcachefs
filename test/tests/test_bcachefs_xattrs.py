"""The bcachefs_effective.* xattrs the copy_volume filter exists for.

bcachefs reports two xattr namespaces on every inode:

  bcachefs.*             the options explicitly set on this inode
  bcachefs_effective.*   the options actually in force, after inheritance -
                         present on every inode below a directory that sets any

listxattr returns both. setxattr accepts both here and neither anywhere else:
a foreign destination returns EOPNOTSUPP, so `rsync -X` off a bcachefs volume
aborts with exit 23 - late, after copying everything. That is what the
copy_volume filter in pve-bcachefs avoids, and PVE's move-volume and offline
migration are both `rsync -X`.

The anchored layout already removed the stored `bcachefs.project` from volume
roots, which is why no bcachefs.* failure appears any more. What remains is
bcachefs_effective.*, present on every file in the tree.
"""

import os
import subprocess

import pytest

from conftest import needs_lxc
from helpers.data_guard import DataGuard

EFFECTIVE = "bcachefs_effective.compression"


def volume_path(pve, node, storage, volid: str) -> str:
    return pve.get(f"/nodes/{node}/storage/{storage}/content/{volid}")["path"]


def listxattr(path: str) -> list[str]:
    out = subprocess.run(["getfattr", "--absolute-names", "-d", "-m", "-", path],
                         capture_output=True, text=True)
    return [line.split("=")[0] for line in out.stdout.splitlines()
            if line and not line.startswith("#")]


class TestEffectiveXattrs:
    def test_effective_xattrs_are_listed(self, config):
        """Established first, because everything else follows from it."""
        mount = config["BCACHEFS_MOUNT"]
        probe = os.path.join(mount, ".xattr-probe")
        os.makedirs(probe, exist_ok=True)
        try:
            names = listxattr(probe)
            assert any(n.startswith("bcachefs_effective.") for n in names), (
                f"no bcachefs_effective.* xattrs listed on {probe}: {names}"
            )
        finally:
            os.rmdir(probe)

    @needs_lxc
    def test_rsync_bcachefs_to_bcachefs(self, create_ct, pve, node, storage, config):
        """bcachefs to bcachefs, same kind of filesystem on both ends.

        This passes: setxattr accepts both namespaces here, so the copy
        completes. It is here to keep that fact measured rather than assumed -
        if it ever starts failing, the bug is far wider than a foreign
        destination.
        """
        destination_mount = config.get("NOQUOTA_MOUNT")
        if not destination_mount:
            pytest.skip("no second bcachefs filesystem in this lab")
        if config.get("BCACHEFS_PRJQUOTA") != "true":
            pytest.skip("no project quotas")

        ct = create_ct(start=True)
        DataGuard(ct.exec()).seed(size_mb=2, count=1)
        ct.stop()

        src = volume_path(pve, node, storage, ct.config()["rootfs"].split(",")[0])
        dst = os.path.join(destination_mount, "rsync-same-fs")
        subprocess.run(["rm", "-rf", dst], check=True)
        result = subprocess.run(
            ["rsync", "-aHAX", "--numeric-ids", f"{src}/", dst],
            capture_output=True, text=True, timeout=900)
        errors = [l for l in result.stderr.splitlines() if "lsetxattr" in l]
        subprocess.run(["rm", "-rf", dst], check=False)

        assert result.returncode == 0, (
            f"rsync -X from bcachefs to bcachefs failed (exit "
            f"{result.returncode}). The effective xattrs break xattr-preserving "
            f"copies even between two bcachefs filesystems:\n"
            + "\n".join(errors[:6])
        )
