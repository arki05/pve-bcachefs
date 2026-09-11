"""The bcachefs_effective.* virtual xattrs, and what they break.

bcachefs reports two xattr namespaces on every inode:

  bcachefs.*             the options explicitly set on this inode
  bcachefs_effective.*   the options actually in force, after inheritance -
                         present on every inode below a directory that sets any

Both are returned by listxattr and both are accepted by setxattr on bcachefs;
neither is accepted anywhere else. `rsync -X` therefore reads them and aborts
on the first foreign destination it meets.

The anchored layout already removed the stored `bcachefs.project` from volume
roots, which is why no bcachefs.* failure appears any more. What still breaks
is bcachefs_effective.*, present on every file in the tree.

These tests pin down how far it reaches, because that decides what kind of bug
it is: confined to foreign destinations, or something that also corrupts a
bcachefs-to-bcachefs copy by turning inherited options into explicit ones.
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

    def test_writing_an_effective_xattr_creates_a_stored_one(self, config):
        """Measured, not assumed: the effective xattrs *are* settable on
        bcachefs, and writing one sets the underlying option - so the inode
        comes away with a stored `bcachefs.*` it did not have before.

        That is why they must not be copied even between two bcachefs
        filesystems. An `rsync -X` reproduces the effective value of every file
        as an explicit setting, replacing inheritance with a per-inode option
        on everything in the tree.
        """
        mount = config["BCACHEFS_MOUNT"]
        probe = os.path.join(mount, ".xattr-setprobe")
        subprocess.run(["rm", "-rf", probe], check=False)
        os.makedirs(probe, exist_ok=True)
        try:
            # A new directory already carries effective xattrs, because the
            # storage sets options and every inode inherits them - that is what
            # "effective" means. Only the stored namespace should be absent.
            before = listxattr(probe)
            assert not [n for n in before if n.startswith("bcachefs.")], (
                f"a fresh directory already carries stored options: {before}"
            )
            result = subprocess.run(
                ["setfattr", "-n", EFFECTIVE, "-v", "lz4", probe],
                capture_output=True, text=True)
            assert result.returncode == 0, (
                f"the effective xattrs are not settable on bcachefs after all "
                f"- the problem would then be listing them at all: "
                f"{result.stderr}"
            )
            names = listxattr(probe)
            assert "bcachefs.compression" in names, (
                f"writing {EFFECTIVE} did not leave a stored option behind: "
                f"{names}"
            )
        finally:
            subprocess.run(["rm", "-rf", probe], check=False)

    @needs_lxc
    def test_rsync_bcachefs_to_bcachefs(self, create_ct, pve, node, storage, config):
        """bcachefs to bcachefs, same kind of filesystem on both ends.

        This passes: both namespaces are settable on bcachefs, so the copy
        itself succeeds. It is here to keep that fact measured rather than
        assumed - if it ever starts failing, the bug is far wider than a
        foreign destination.
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
