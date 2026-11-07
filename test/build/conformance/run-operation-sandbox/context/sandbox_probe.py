import ctypes
import errno
import os
import platform
import signal
import socket
import tempfile


def expect_denied(operation, accepted=(errno.EPERM,)):
    try:
        operation()
    except OSError as error:
        if error.errno in accepted:
            return
        raise
    raise AssertionError("operation unexpectedly succeeded")


expect_denied(lambda: socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM))
expect_denied(
    lambda: socket.socketpair(socket.AF_VSOCK, socket.SOCK_STREAM),
    (errno.EPERM, errno.EOPNOTSUPP),
)

# Linux arm64 io_uring_setup. Blocking it closes IORING_OP_SOCKET as an
# alternate AF_VSOCK creation path around the direct socket-family rule.
libc = ctypes.CDLL(None, use_errno=True)
result = libc.syscall(425, 8, 0)
assert result == -1
assert ctypes.get_errno() == errno.EPERM

# The scoped procfs exposes only this operation's PID namespace. Even those
# namespace handles cannot be joined after the BuildKit-compatible capability
# reduction, so there is no usable setns path into a broader view.
namespace_fd = os.open("/proc/1/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
try:
    result = libc.setns(namespace_fd, 0)
    assert result == -1
    assert ctypes.get_errno() == errno.EPERM
finally:
    os.close(namespace_fd)

# RUN keeps BuildKit's CAP_SYS_CHROOT, but a chroot cannot leave the operation
# root. A chroot into a subdirectory leaves the working directory outside the
# new root, so ".." from there must still stop at the operation root.
escape_dir = tempfile.mkdtemp()
root = os.stat("/")
pid = os.fork()
if pid == 0:
    try:
        os.chdir("/")
        os.chroot(escape_dir)
        for _ in range(64):
            os.chdir("..")
        os.chroot(".")
        after = os.stat("/")
        os._exit(0 if (after.st_dev, after.st_ino) == (root.st_dev, root.st_ino) else 1)
    except BaseException:
        os._exit(2)
_, status = os.waitpid(pid, 0)
os.rmdir(escape_dir)
assert os.waitstatus_to_exitcode(status) == 0, "chroot left the operation root"

# Nor can RUN create a user namespace, which would hold capabilities the
# sandbox dropped. clone3 hides its flags from seccomp, so it is unavailable
# and libc falls back to clone, as under BuildKit's default profile.
CLONE_NEWUSER = 0x10000000
pid = os.fork()
if pid == 0:
    os._exit(0 if libc.unshare(CLONE_NEWUSER) == -1 and ctypes.get_errno() == errno.EPERM else 1)
_, status = os.waitpid(pid, 0)
assert os.waitstatus_to_exitcode(status) == 0, "unshare(CLONE_NEWUSER) was not denied"
SYS_clone = {"x86_64": 56, "aarch64": 220}[platform.machine()]
pid = libc.syscall(SYS_clone, CLONE_NEWUSER | signal.SIGCHLD, None, None, None, None)
if pid == 0:
    os._exit(0)
if pid > 0:
    os.waitpid(pid, 0)
assert pid == -1 and ctypes.get_errno() == errno.EPERM, "clone(CLONE_NEWUSER) was not denied"
assert libc.syscall(435, None, 0) == -1
assert ctypes.get_errno() == errno.ENOSYS
