"""Project quotas: enforcement, and accounting of data that already exists.

Two separate assertions, and the second is the one that matters. A volume can
have a quota limit set and enforce nothing, because the usage it accounts for
is zero - which is exactly what a tree that was never reinherited looks like.
It reports a correct-looking layout and a correct-looking limit while silently
enforcing nothing at all.
"""

import os
import subprocess

import pytest

from conftest import needs_lxc

pytestmark = pytest.mark.skipif(
    os.environ.get("BCACHEFS_PRJQUOTA", "") == "false",
    reason="project quotas unavailable",
)


def _require_quota(config):
    if config.get("BCACHEFS_PRJQUOTA") != "true":
        pytest.skip("project quotas unavailable on this filesystem")


def volume_path(pve, node, storage, volid: str) -> str:
    return pve.get(f"/nodes/{node}/storage/{storage}/content/{volid}")["path"]


def projid_of(path: str) -> int:
    out = subprocess.run(["lsattr", "-p", "-d", path], capture_output=True, text=True)
    assert out.returncode == 0, f"lsattr failed on {path}: {out.stderr}"
    return int(out.stdout.split()[0])


def quota_usage(mount: str, projid: int):
    """Usage and limit for a project, straight from the kernel."""
    from quotactl import project_quota
    return project_quota(mount, projid)


@needs_lxc
class TestQuotaEnforcement:
    def test_writing_past_the_limit_fails(self, create_ct, config):
        """The container must not be able to exceed its configured size."""
        _require_quota(config)
        ct = create_ct(start=True, disk_gb=1)
        guest = ct.exec()

        # Well past 1 GiB, in chunks, so the failure is a write error rather
        # than a single allocation the filesystem might short-circuit.
        # Incompressible: the storage sets compression=lz4, and a fill of
        # zeros would measure the compressor rather than the quota. bcachefs
        # happens to charge this quota before compression - which is why the
        # zero fill passed here while the same test failed on ZFS - but a test
        # that only works because of that is not testing what it claims to.
        result = guest.exec(
            "for i in $(seq 1 40); do "
            "  dd if=/dev/urandom of=/root/fill-$i bs=1M count=64 conv=fsync "
            "    status=none || exit 42; "
            "done", timeout=900,
        )
        assert result["exitcode"] != 0, (
            "wrote well past the container's 1G size without hitting a limit - "
            "the quota is not being enforced"
        )

    def test_usage_accounts_for_data_already_written(self, create_ct, pve, node,
                                                     storage, config):
        """A limit with zero accounted usage enforces nothing. This is the
        signature of a tree that carries the project ID on its root but was
        never reinherited - it looks converted and is not."""
        _require_quota(config)
        mount = config["BCACHEFS_MOUNT"]
        ct = create_ct(start=True, disk_gb=2)
        # Incompressible, so "128 MiB written" and "128 MiB charged" are the
        # same question. With compressible data the two diverge on any backend
        # that charges post-compression, and the assertion below would be
        # measuring the compressor.
        ct.exec().run(
            "dd if=/dev/urandom of=/root/ballast bs=1M count=128 conv=fsync "
            "status=none")
        ct.exec().run("sync")

        path = volume_path(pve, node, storage, ct.config()["rootfs"].split(",")[0])
        projid = projid_of(os.path.dirname(path))
        assert projid != 0, "volume has no project ID"

        quota = quota_usage(mount, projid)
        assert quota.dqb_bhardlimit > 0, (
            f"project {projid} has no block limit; the size is not enforced"
        )
        # 128 MiB of ballast, so anything near zero means nothing is being
        # accounted against the project at all.
        assert quota.dqb_curspace >= 64 * 1024 * 1024, (
            f"project {projid} accounts only {quota.dqb_curspace} bytes after "
            f"writing 128 MiB - the limit is set but the data is not charged "
            f"against it, so nothing is actually enforced"
        )
        assert quota.dqb_curinodes > 0, (
            f"project {projid} accounts zero inodes; the tree was never "
            f"reinherited into the project"
        )


@needs_lxc
class TestProjectIdAllocation:
    def test_each_volume_gets_a_distinct_project_id(self, create_ct, pve, node,
                                                     storage, config):
        _require_quota(config)
        ids = []
        for _ in range(3):
            ct = create_ct()
            path = volume_path(pve, node, storage, ct.config()["rootfs"].split(",")[0])
            ids.append(projid_of(os.path.dirname(path)))
        assert len(set(ids)) == len(ids), f"project IDs collided: {ids}"
        assert 0 not in ids, f"a volume was left at project 0: {ids}"

    def test_derived_id_is_stable_across_a_restart(self, create_ct, pve, node,
                                                    storage, config):
        """The ID is derived from the volume, so it must not drift."""
        _require_quota(config)
        ct = create_ct(start=True)
        path = volume_path(pve, node, storage, ct.config()["rootfs"].split(",")[0])
        before = projid_of(os.path.dirname(path))
        ct.stop()
        ct.start()
        assert projid_of(os.path.dirname(path)) == before
