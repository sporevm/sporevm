FROM base
ARG VALUE=initial
ENV ENV_VALUE=environment
RUN --mount=type=cache,target=/var/cache/oracle-run-heredoc-a \
    --mount=type=cache,target=/var/cache/oracle-run-heredoc-b \
    --mount=type=cache,target=/var/lib/oracle-run-heredoc-c <<EOF
set -eu
mkdir -p /oracle
printf a > /var/cache/oracle-run-heredoc-a/value
printf b > /var/cache/oracle-run-heredoc-b/value
printf c > /var/lib/oracle-run-heredoc-c/value
printf 'single=%s\n' '$VALUE' > /oracle/shell
printf 'double=%s\n' "$VALUE" >> /oracle/shell
printf 'env=%s\n' "$ENV_VALUE" >> /oracle/shell
printf 'literal=%s\n' "\$VALUE" >> /oracle/shell
printf 'unset=%s\n' "${UNSET-}" >> /oracle/shell
printf 'fallback=%s\n' "${UNSET:-fallback}" >> /oracle/shell
EOF
RUN --mount=type=cache,target=/var/cache/oracle-run-heredoc-a \
    --mount=type=cache,target=/var/cache/oracle-run-heredoc-b \
    --mount=type=cache,target=/var/lib/oracle-run-heredoc-c <<EOF
set -eu
cat /var/cache/oracle-run-heredoc-a/value \
    /var/cache/oracle-run-heredoc-b/value \
    /var/lib/oracle-run-heredoc-c/value > /oracle/cache
EOF
