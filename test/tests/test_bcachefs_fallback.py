"""The raw-image fallback.

`bcachefs-subvol-rootfs 1` asks for container rootfs volumes as subvolumes,
whose size is enforced by a project quota. On a filesystem with no project
quotas there is nothing to enforce with, and handing out an unlimited folder
would be worse than ignoring the option - so the plugin falls back to a raw
image, which enforces its own size by construction.

This is the one case where doing what was asked is the wrong behaviour, so it
needs a filesystem without prjquota to test against. The profile formats one
deliberately.
"""

import os
import subprocess

import pytest

from conftest import needs_lxc, LabCT
from helpers.wait import wait_for_task


@pytest.fixture(scope="session")
def noquota_storage(config, pve, node):
    name = config.get("NOQUOTA_STORAGE")
    if not name:
        pytest.skip("profile did not provide a filesystem without project quotas")
    try:
        pve.get(f"/nodes/{node}/storage/{name}/status")
    except Exception:                                  # noqa: BLE001
        pytest.skip(f"storage {name} is not available")
    return name


@needs_lxc
class TestRawFallback:
    def test_rootfs_is_a_raw_image_without_project_quotas(
            self, pve, node, noquota_storage, ct_template):
        vmid = pve.nextid()
        wait_for_task(pve, pve.create(
            f"/nodes/{node}/lxc", vmid=vmid, hostname=f"fallback-{vmid}",
            ostemplate=ct_template, storage=noquota_storage,
            rootfs=f"{noquota_storage}:1", memory=512, cores=1,
            password="pvelab", unprivileged=1, start=0,
        ), timeout=600)
        ct = LabCT(pve, node, vmid)
        try:
            volid = ct.config()["rootfs"].split(",")[0]
            path = pve.get(
                f"/nodes/{node}/storage/{noquota_storage}/content/{volid}")["path"]
            assert os.path.isfile(path), (
                f"expected a raw image on a filesystem without project quotas, "
                f"got {path} (is a directory: {os.path.isdir(path)}) - an "
                f"unenforced subvolume was handed out instead"
            )
            assert path.endswith(".raw"), f"unexpected volume path: {path}"
        finally:
            ct.destroy()

    def test_the_fallback_image_enforces_its_size(
            self, pve, node, noquota_storage, ct_template):
        """A raw image is limited by construction; confirm that actually holds,
        because the point of falling back is enforcement."""
        vmid = pve.nextid()
        wait_for_task(pve, pve.create(
            f"/nodes/{node}/lxc", vmid=vmid, hostname=f"fallback-{vmid}",
            ostemplate=ct_template, storage=noquota_storage,
            rootfs=f"{noquota_storage}:1", memory=512, cores=1,
            password="pvelab", unprivileged=1, start=0,
        ), timeout=600)
        ct = LabCT(pve, node, vmid)
        try:
            ct.start()
            result = ct.exec().exec(
                "for i in $(seq 1 30); do "
                "  dd if=/dev/urandom of=/root/fill-$i bs=1M count=64 conv=fsync "
                "    status=none || exit 42; "
                "done", timeout=600,
            )
            assert result["exitcode"] != 0, (
                "wrote far past the 1G rootfs without hitting a limit"
            )
        finally:
            ct.destroy()
