FROM base
ARG SSH_TIMEOUT_DELAY=0
RUN --mount=type=ssh \
    --mount=type=cache,target=/var/cache/oracle-ssh-a \
    --mount=type=cache,target=/var/cache/oracle-ssh-b \
    sh -euxc 'test "$SSH_AUTH_SOCK" = /run/buildkit/ssh_agent.0; test ! -e "$SSH_AUTH_SOCK"; test ! -e /run/buildkit; for fd in /proc/self/fd/*; do test ! -S "$fd"; done; if [ "$SSH_TIMEOUT_DELAY" != 0 ]; then (sleep 2; printf leaked > /var/cache/oracle-ssh-a/timeout-leak) & fi; sleep "$SSH_TIMEOUT_DELAY"; mkdir -p /oracle; printf default > /oracle/default-env; printf cache-a > /var/cache/oracle-ssh-a/value; printf cache-b > /var/cache/oracle-ssh-b/value'
ENV SSH_AUTH_SOCK=/image/agent
RUN --mount=type=ssh sh -euxc 'test "$SSH_AUTH_SOCK" = /image/agent; test ! -e "$SSH_AUTH_SOCK"; printf image > /oracle/image-env'
ARG SSH_AUTH_SOCK=/arg/agent
RUN --mount=type=ssh sh -euxc 'test "$SSH_AUTH_SOCK" = /arg/agent; test ! -e "$SSH_AUTH_SOCK"; printf arg > /oracle/arg-env'
RUN --mount=type=cache,target=/var/cache/oracle-ssh-a \
    --mount=type=ssh \
    --mount=type=cache,target=/var/cache/oracle-ssh-b \
    sh -euxc 'test "$SSH_AUTH_SOCK" = /arg/agent; test "$(cat /var/cache/oracle-ssh-a/value)" = cache-a; test "$(cat /var/cache/oracle-ssh-b/value)" = cache-b; test ! -e /var/cache/oracle-ssh-a/timeout-leak; cat /var/cache/oracle-ssh-a/value /var/cache/oracle-ssh-b/value > /oracle/cache'
