"""Plugin behaviour that is not part of any generic storage contract:
subvolume state after clone and rollback, storage option handling, and the
package's own install/upgrade/remove lifecycle.
"""

import os
import subprocess

import pytest

from conftest import needs_lxc, LabCT
from helpers.wait import wait_for_task


def volume_path(pve, node, storage, volid: str) -> str:
    return pve.get(f"/nodes/{node}/storage/{storage}/content/{volid}")["path"]


def rootfs_path(pve, node, storage, ct) -> str:
    return volume_path(pve, node, storage, ct.config()["rootfs"].split(",")[0])


def is_master_subvolume(path: str, mount: str) -> bool:
    """Whether a volume is a master subvolume rather than a snapshot.

    It matters because `bch2_quota_reservation_add()` returns early for
    snapshot inodes: quota enforcement is skipped entirely inside a snapshot
    subvolume. A volume left as a snapshot after a clone or a rollback keeps
    its limit, reports sensible usage, and enforces nothing.

    `bcachefs subvolume show` does not exist; list-snapshots is what there is.
    """
    out = subprocess.run(["bcachefs", "subvolume", "list-snapshots", mount],
                         capture_output=True, text=True)
    if out.returncode != 0:
        pytest.skip(f"cannot enumerate snapshots: {out.stderr.strip()[:200]}")
    relative = os.path.relpath(path, mount)
    for line in out.stdout.splitlines():
        if relative in line or path in line:
            return False
    return True


@needs_lxc
class TestSubvolumeState:
    def test_volume_is_a_master_subvolume_after_create(self, create_ct, pve, node,
                                                       storage, config):
        if config.get("BCACHEFS_PRJQUOTA") != "true":
            pytest.skip("raw-image fallback; no subvolume to inspect")
        ct = create_ct()
        assert is_master_subvolume(rootfs_path(pve, node, storage, ct), config["BCACHEFS_MOUNT"])

    def test_volume_is_still_a_master_subvolume_after_rollback(
            self, create_ct, pve, node, storage, config):
        """Rollback must not leave the live volume as a snapshot. If it does,
        the volume looks fine and quietly stops enforcing its quota."""
        if config.get("BCACHEFS_PRJQUOTA") != "true":
            pytest.skip("raw-image fallback")
        ct = create_ct(start=True)
        wait_for_task(pve, pve.create(f"/nodes/{node}/lxc/{ct.vmid}/snapshot",
                                      snapname="rb"), 300)
        ct.stop()
        wait_for_task(pve, pve.create(
            f"/nodes/{node}/lxc/{ct.vmid}/snapshot/rb/rollback"), 300)
        assert is_master_subvolume(rootfs_path(pve, node, storage, ct), config["BCACHEFS_MOUNT"]), (
            "the volume is a snapshot subvolume after rollback; quota "
            "enforcement is skipped inside snapshot subvolumes"
        )

    def test_clone_is_a_master_subvolume(self, create_ct, pve, node, storage, config):
        if config.get("BCACHEFS_PRJQUOTA") != "true":
            pytest.skip("raw-image fallback")
        source = create_ct(start=True)
        source.stop()
        clone_id = pve.nextid()
        wait_for_task(pve, pve.create(
            f"/nodes/{node}/lxc/{source.vmid}/clone",
            newid=clone_id, hostname=f"clone-{clone_id}", full=1, storage=storage,
        ), timeout=900)
        clone = LabCT(pve, node, clone_id)
        try:
            assert is_master_subvolume(rootfs_path(pve, node, storage, clone), config["BCACHEFS_MOUNT"])
        finally:
            clone.destroy()


class TestStorageOptions:
    """Options in storage.cfg are applied per-file with `bcachefs
    set-file-option`, not to the superblock, so they read back as the
    `bcachefs_effective.*` xattrs on the volume rather than in show-super."""

    def _effective(self, path: str, name: str) -> str | None:
        out = subprocess.run(
            ["getfattr", "--absolute-names", "--only-values", "-n",
             f"bcachefs_effective.{name}", path],
            capture_output=True, text=True)
        return out.stdout.strip() if out.returncode == 0 else None

    def test_declared_options_are_applied_to_the_volume(self, create_ct, pve, node,
                                                        storage, config):
        declared = pve.get(f"/storage/{storage}").get("bcachefs-compression")
        if not declared:
            pytest.skip("no compression configured on this storage")
        ct = create_ct()
        path = rootfs_path(pve, node, storage, ct)
        effective = self._effective(path, "compression")
        assert effective == declared, (
            f"storage.cfg asks for compression={declared} but the volume "
            f"reports {effective!r}"
        )

    def test_dropping_an_option_clears_it(self, create_ct, pve, node, storage,
                                          config):
        """Removing an option from storage.cfg must clear it on the volume,
        not merely stop re-applying it to new ones."""
        original = pve.get(f"/storage/{storage}").get("bcachefs-compression")
        if not original:
            pytest.skip("no compression configured to drop")
        ct = create_ct()
        path = rootfs_path(pve, node, storage, ct)
        assert self._effective(path, "compression") == original

        try:
            pve.set(f"/storage/{storage}", delete="bcachefs-compression")
            after = create_ct()
            after_path = rootfs_path(pve, node, storage, after)
            effective = self._effective(after_path, "compression")
            assert effective in (None, "", "none"), (
                f"compression survived being removed from storage.cfg: "
                f"{effective!r}"
            )
        finally:
            pve.set(f"/storage/{storage}", **{"bcachefs-compression": original})


def _devices(config) -> list[str]:
    """show-super reads one device, not the whole set - passing them all is a
    usage error, not a multi-device query."""
    import glob
    disks = sorted(glob.glob("/dev/disk/by-id/virtio-labdisk*"))
    if not disks:
        pytest.skip("no lab test disks present")
    return disks


class TestPackageLifecycle:
    def test_pve_container_patch_is_applied(self):
        with open("/usr/share/perl5/PVE/LXC.pm") as handle:
            assert "subvol_rootfs_active" in handle.read(), (
                "the pve-container patch is not applied; sized container "
                "rootfs volumes will be raw images"
            )

    def test_patch_survives_a_pve_container_reinstall(self):
        """The dpkg trigger is what keeps the patch applied across upgrades.
        Reinstalling pve-container overwrites LXC.pm exactly as an upgrade
        does, so it exercises the same path."""
        subprocess.run(
            ["apt-get", "install", "-y", "-q", "--reinstall",
             "-o", "DPkg::Lock::Timeout=600", "pve-container"],
            check=True, capture_output=True, timeout=900,
            env={**os.environ, "DEBIAN_FRONTEND": "noninteractive"},
        )
        with open("/usr/share/perl5/PVE/LXC.pm") as handle:
            assert "subvol_rootfs_active" in handle.read(), (
                "the dpkg trigger did not re-apply the patch after "
                "pve-container was reinstalled"
            )

    def test_copy_volume_excludes_bcachefs_virtual_xattrs(self):
        """Without this filter, moving a container off bcachefs fails.

        bcachefs reports its per-inode IO options as bcachefs.* and
        bcachefs_effective.* virtual xattrs. listxattr returns them, so
        `rsync -X` - which is what PVE's copy_volume runs - reads them and
        tries to set them on the destination, where lsetxattr returns
        EOPNOTSUPP. rsync exits 23 and the move fails, after copying
        everything.
        """
        with open("/usr/share/perl5/PVE/LXC.pm") as handle:
            source = handle.read()
        assert "bcachefs_effective" in source, (
            "PVE::LXC's copy_volume does not exclude the bcachefs virtual "
            "xattrs; moving a container off this storage will fail with "
            "rsync exit 23. patch-pve-container.pl did not apply."
        )

    def test_plugin_loads_cleanly(self):
        out = subprocess.run(["perl", "-e", "use PVE::Storage;"],
                             capture_output=True, text=True, timeout=120)
        assert "BcachefsPlugin" not in out.stderr, (
            f"the plugin failed to load:\n{out.stderr}"
        )
