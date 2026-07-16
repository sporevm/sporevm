import ctypes
import errno
import os
import socket


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

# Blocking io_uring_setup closes IORING_OP_SOCKET as an alternate AF_VSOCK
# creation path around the direct socket-family rule.
libc = ctypes.CDLL(None, use_errno=True)
result = libc.syscall(425, 8, 0)
assert result == -1
assert ctypes.get_errno() == errno.EPERM

# The operation's procfs exposes only its own PID namespace, and the reduced
# capability set prevents joining even those scoped namespace handles.
namespace_fd = os.open("/proc/1/ns/mnt", os.O_RDONLY | os.O_CLOEXEC)
try:
    result = libc.setns(namespace_fd, 0)
    assert result == -1
    assert ctypes.get_errno() == errno.EPERM
finally:
    os.close(namespace_fd)
