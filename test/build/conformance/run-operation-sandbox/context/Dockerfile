FROM base AS source
RUN printf 'stage-input\n' >/stage-input

FROM base
COPY context-input /oracle/context-input
COPY sandbox_probe.py /oracle/sandbox_probe.py
COPY --from=source /stage-input /oracle/stage-input
RUN set -eu; \
    test -s /etc/resolv.conf; \
    test -r /dev/null; \
    test -r /dev/urandom; \
    test ! -e /proc/1/root/run/sporevm; \
    grep -qx '0::/' /proc/self/cgroup; \
    test ! -e /dev/vda; \
    test ! -e /dev/vdb; \
    test ! -e /dev/vdc; \
    test ! -e /dev/console; \
    test ! -e /dev/hvc0; \
    test ! -e /dev/vsock; \
    grep -Eq '^CapEff:[[:space:]]+00000000a80425fb$' /proc/self/status; \
    grep -Eq '^CapPrm:[[:space:]]+00000000a80425fb$' /proc/self/status; \
    grep -Eq '^CapBnd:[[:space:]]+00000000a80425fb$' /proc/self/status; \
    grep -Eq '^Seccomp:[[:space:]]+2$' /proc/self/status; \
    grep -Eq '^NoNewPrivs:[[:space:]]+0$' /proc/self/status; \
    python3 /oracle/sandbox_probe.py; \
    mknod /tmp/spore-block-probe b 254 0; \
    if dd if=/tmp/spore-block-probe of=/dev/null bs=1 count=1 2>/tmp/spore-block-error; then exit 91; fi; \
    grep -q 'Operation not permitted' /tmp/spore-block-error; \
    mknod /tmp/spore-console-probe c 5 1; \
    if dd if=/tmp/spore-console-probe of=/dev/null bs=1 count=1 2>/tmp/spore-console-error; then exit 93; fi; \
    grep -Eq 'Operation not permitted|No such device' /tmp/spore-console-error; \
    mknod /tmp/spore-hvc-probe c 229 0; \
    if dd if=/tmp/spore-hvc-probe of=/dev/null bs=1 count=1 2>/tmp/spore-hvc-error; then exit 94; fi; \
    grep -Eq 'Operation not permitted|No such device' /tmp/spore-hvc-error; \
    mknod /tmp/spore-vsock-device-probe c 10 241; \
    if dd if=/tmp/spore-vsock-device-probe of=/dev/null bs=1 count=1 2>/tmp/spore-vsock-device-error; then exit 95; fi; \
    grep -Eq 'Operation not permitted|No such device|Inappropriate ioctl' /tmp/spore-vsock-device-error; \
    mkdir -p /tmp/spore-mount-probe; \
    if mount -t proc proc /tmp/spore-mount-probe 2>/tmp/spore-mount-error; then exit 92; fi; \
    grep -Eq 'Operation not permitted|permission denied' /tmp/spore-mount-error; \
    cat /proc/sys/vm/overcommit_memory >/tmp/spore-proc-sys-original; \
    if printf '2\n' 2>/tmp/spore-proc-sys-error >/proc/sys/vm/overcommit_memory; then exit 96; fi; \
    grep -Eq 'Read-only file system|Permission denied' /tmp/spore-proc-sys-error; \
    cmp /tmp/spore-proc-sys-original /proc/sys/vm/overcommit_memory; \
    (sleep 1; printf 'leaked\n' >/oracle/leaked-descendant) & \
    printf 'sandboxed\n' >/oracle/result
COPY transition-input /oracle/transition-input
RUN sleep 2 \
    && test ! -e /oracle/leaked-descendant \
    && test -f /oracle/context-input \
    && test -f /oracle/stage-input \
    && test -s /oracle/transition-input \
    && cmp /tmp/spore-proc-sys-original /proc/sys/vm/overcommit_memory \
    && test "$(cat /oracle/result)" = sandboxed \
    && printf 'clean-next-run\n' >/oracle/next-run
