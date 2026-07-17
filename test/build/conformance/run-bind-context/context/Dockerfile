FROM base
WORKDIR /work
ARG PRIMARY=./Gemfile
ARG BIND_TIMEOUT_DELAY=0
RUN mkdir -p /work /oracle && printf lower >/work/existing
RUN --mount=type=ssh \
    --mount=type=cache,target=/var/cache/oracle-bind-a \
    --mount=type=cache,target=/var/cache/oracle-bind-b \
    --mount=type=bind,source=$PRIMARY,target=Gemfile \
    --mount=type=bind,source=Gemfile.lock,target=existing \
    --mount=type=bind,source=Gemfile_next.lock,target=nested/input \
    sh -euxc 'test "$SSH_AUTH_SOCK" = /run/buildkit/ssh_agent.0; test ! -e "$SSH_AUTH_SOCK"; test ! -e /run/buildkit; test ! -e /mnt/build-context; for device in /dev/vd?; do test ! -e "$device"; done; test "$(cat existing)" = "gemfile lock" || test "$(cat existing)" = "gemfile lock changed"; test "$(cat nested/input)" = "gemfile next lock"; if printf changed >Gemfile; then exit 91; fi; if [ "$BIND_TIMEOUT_DELAY" != 0 ]; then (sleep 2; printf leaked >/var/cache/oracle-bind-a/timeout-leak) & fi; sleep "$BIND_TIMEOUT_DELAY"; printf cache-a >/var/cache/oracle-bind-a/value; printf cache-b >/var/cache/oracle-bind-b/value; printf sibling >nested/sibling; cat Gemfile existing nested/input > /oracle/result; stat -c %a Gemfile > /oracle/source-mode; stat -c %y Gemfile > /oracle/source-mtime'
RUN sh -euxc 'test ! -e Gemfile; test "$(cat existing)" = lower; test ! -e nested/input; test "$(cat nested/sibling)" = sibling; test ! -e /mnt/build-context; for device in /dev/vd?; do test ! -e "$device"; done; test ! -e /var/cache/oracle-bind-a; test ! -e /var/cache/oracle-bind-a/timeout-leak; test ! -e /var/cache/oracle-bind-b'
