"""How bcachefs reports and accepts its own option xattrs.

Nothing here tests the plugin. These are characterisation tests for the
filesystem: they measure the behaviour the plugin works around, so that the
workaround stays justified by something measured rather than remembered.

bcachefs reports two xattr namespaces on every inode:

  bcachefs.*             the options explicitly set on this inode
  bcachefs_effective.*   the options actually in force, after inheritance -
                         present on every inode below a directory that sets any

Both are returned by listxattr, and setxattr accepts both - but only the
stored namespace does anything. Writing bcachefs_effective.* returns success
and is silently discarded, even when the value differs from the one in force
(measured on bcachefs 1.39.5). No other filesystem accepts either namespace at
all: lsetxattr there returns EOPNOTSUPP.

That asymmetry decides how far the problem reaches, which is the whole reason
these tests exist:

  bcachefs -> foreign    breaks. `rsync -X` reads the effective xattrs off
                         every file and the destination rejects them, so the
                         transfer aborts with exit 23 - late, after copying
                         everything. This is the bug the copy_volume filter in
                         pve-bcachefs exists to avoid.
  bcachefs -> bcachefs   harmless. The writes are accepted and dropped, so
                         inheritance is not turned into per-inode settings.
                         Filtering the namespace is still right, but on the
                         grounds that it is derived state that does not belong
                         in a copy - not because it would corrupt the copy.

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


def _values(path: str) -> dict[str, str]:
    """Names and values, because "did the write take" cannot be answered by
    the presence of a name that was already there."""
    out = subprocess.run(["getfattr", "--absolute-names", "-d", "-m", "-", path],
                         capture_output=True, text=True)
    values = {}
    for line in out.stdout.splitlines():
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        values[name] = value.strip('"')
    return values


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

    def test_writing_an_effective_xattr_is_accepted_and_discarded(self, config):
        """setxattr on the effective namespace succeeds and does nothing.

        Measured on 1.39.5: the write returns 0, no stored `bcachefs.*` is
        created, and the effective value does not change - not even when the
        value written differs from the one currently in force. Compare with
        the stored namespace below, which does take effect, so this is a
        property of the effective namespace rather than of the directory.

        This is what bounds the blast radius of the effective xattrs. Because
        the write is a no-op, an `rsync -X` between two bcachefs filesystems
        cannot replace inheritance with per-inode settings; only a foreign
        destination, which rejects the xattr outright, actually breaks. If
        this ever starts failing, that reasoning is void and the copy_volume
        filter is load-bearing for same-filesystem copies too.
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
            # Deliberately a value the inode does not already have in force:
            # writing back the effective value would be indistinguishable from
            # a no-op even on a filesystem that honoured the write.
            effective = _values(probe).get(EFFECTIVE)
            other = "zstd" if effective != "zstd" else "lz4"
            result = subprocess.run(
                ["setfattr", "-n", EFFECTIVE, "-v", other, probe],
                capture_output=True, text=True)
            assert result.returncode == 0, (
                f"the effective xattrs are not settable on bcachefs after all "
                f"- the problem would then be listing them at all: "
                f"{result.stderr}"
            )
            after = _values(probe)
            assert "bcachefs.compression" not in after, (
                f"writing {EFFECTIVE}={other} left a stored option behind: "
                f"{sorted(after)}. bcachefs now honours writes to the "
                f"effective namespace, so copying it between two bcachefs "
                f"filesystems does pin inherited options after all."
            )
            assert after.get(EFFECTIVE) == effective, (
                f"writing {EFFECTIVE}={other} changed the value in force "
                f"({effective} -> {after.get(EFFECTIVE)}) without storing an "
                f"option"
            )
        finally:
            subprocess.run(["rm", "-rf", probe], check=False)

    def test_writing_a_stored_xattr_takes_effect(self, config):
        """The control for the test above: the stored namespace does work.

        Without this, a no-op result up there could just as well mean the
        probe directory was not writable, or that the option name was wrong.
        """
        mount = config["BCACHEFS_MOUNT"]
        probe = os.path.join(mount, ".xattr-storedprobe")
        subprocess.run(["rm", "-rf", probe], check=False)
        os.makedirs(probe, exist_ok=True)
        try:
            effective = _values(probe).get(EFFECTIVE)
            other = "zstd" if effective != "zstd" else "lz4"
            result = subprocess.run(
                ["setfattr", "-n", "bcachefs.compression", "-v", other, probe],
                capture_output=True, text=True)
            assert result.returncode == 0, (
                f"setting a stored option failed: {result.stderr}")
            after = _values(probe)
            assert after.get("bcachefs.compression") == other, (
                f"bcachefs.compression was not stored: {sorted(after)}")
            assert after.get(EFFECTIVE) == other, (
                f"storing the option did not change the effective value: "
                f"{after.get(EFFECTIVE)}")
        finally:
            subprocess.run(["rm", "-rf", probe], check=False)

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
