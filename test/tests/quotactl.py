"""Read bcachefs project quotas through quotactl_fd(2).

quota-tools do not understand bcachefs, so `repquota` cannot answer any of
this. The plugin reaches for quotactl_fd(2) directly and so does this - which
also means the test verifies the same kernel interface the plugin depends on,
rather than a userspace tool's opinion of it.

quotactl_fd is the newer, fd-based call. The classic quotactl(2) takes a block
device path and only ever addresses the *first* device of a filesystem, which
is wrong for every multi-device bcachefs.
"""

import ctypes
import ctypes.util
import os

SYS_quotactl_fd = 443          # x86_64
Q_GETQUOTA = 0x800007
PRJQUOTA = 2


def _qcmd(cmd: int, qtype: int) -> int:
    return (cmd << 8) | (qtype & 0xFF)


class IfDqblk(ctypes.Structure):
    _fields_ = [
        ("dqb_bhardlimit", ctypes.c_uint64),
        ("dqb_bsoftlimit", ctypes.c_uint64),
        ("dqb_curspace", ctypes.c_uint64),
        ("dqb_ihardlimit", ctypes.c_uint64),
        ("dqb_isoftlimit", ctypes.c_uint64),
        ("dqb_curinodes", ctypes.c_uint64),
        ("dqb_btime", ctypes.c_uint64),
        ("dqb_itime", ctypes.c_uint64),
        ("dqb_valid", ctypes.c_uint32),
    ]


def project_quota(mount: str, projid: int) -> IfDqblk:
    """Usage and limits for one project ID. Raises OSError on failure."""
    libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
    fd = os.open(mount, os.O_RDONLY | os.O_DIRECTORY)
    try:
        block = IfDqblk()
        ctypes.set_errno(0)
        ret = libc.syscall(
            ctypes.c_long(SYS_quotactl_fd),
            ctypes.c_int(fd),
            ctypes.c_uint(_qcmd(Q_GETQUOTA, PRJQUOTA)),
            ctypes.c_uint(projid),
            ctypes.byref(block),
        )
        if ret != 0:
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err),
                          f"quotactl_fd(Q_GETQUOTA, project {projid}) on {mount}")
        return block
    finally:
        os.close(fd)
