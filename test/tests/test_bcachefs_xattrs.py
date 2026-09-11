"""The bcachefs_effective.* virtual xattrs, and what they break.

bcachefs reports two xattr namespaces on every inode:

  bcachefs.*             stored, settable - the options set on this inode
  bcachefs_effective.*   computed - the options actually in force, after
                         inheritance from the parent and the filesystem

Both are returned by listxattr. `rsync -X` therefore reads both and tries to
reproduce them on the destination. The stored ones are legitimate; the
effective ones are a derived view with nothing behind them to write.

The anchored layout already removed the stored `bcachefs.project` from volume
roots, which is why no bcachefs.* failure appears any more. Everything that
still breaks is bcachefs_effective.*, so these tests pin down exactly how far
that reaches - which decides whether this is a "copying to a foreign
filesystem" problem or something wider.
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

    def test_effective_xattrs_cannot_be_set_even_on_bcachefs(self, config):
        """The crux.

        If a listed xattr cannot be written back on the very filesystem that
        reported it, then listing it is the bug - not the destination's
        inability to accept it. It also means this is not a cross-filesystem
        problem: any `rsync -X` that reads them breaks, bcachefs to bcachefs
        included.
        """
        mount = config["BCACHEFS_MOUNT"]
        probe = os.path.join(mount, ".xattr-setprobe")
        os.makedirs(probe, exist_ok=True)
        try:
            result = subprocess.run(
                ["setfattr", "-n", EFFECTIVE, "-v", "lz4", probe],
                capture_output=True, text=True)
            if result.returncode == 0:
                pytest.skip(
                    "the effective xattrs are settable on bcachefs after all; "
                    "the problem is confined to foreign destinations")
            assert "not supported" in result.stderr.lower() \
                or "permitted" in result.stderr.lower(), result.stderr
        finally:
            os.rmdir(probe)

    @needs_lxc
    def test_rsync_bcachefs_to_bcachefs(self, create_ct, pve, node, storage, config):
        """bcachefs to bcachefs, same kind of filesystem on both ends.

        If this fails, the bug is not about copying to ext4 - it breaks any
        xattr-preserving copy of a bcachefs tree, and the workaround is needed
        far more widely than just move-volume.
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
