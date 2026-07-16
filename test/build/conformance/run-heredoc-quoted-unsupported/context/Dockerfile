FROM base
ENV VALUE=expanded-by-shell
RUN --mount=type=cache,target=/var/cache/oracle-run-heredoc-quoted <<'EOF'
printf '%s\n' "$VALUE" > /oracle
EOF
