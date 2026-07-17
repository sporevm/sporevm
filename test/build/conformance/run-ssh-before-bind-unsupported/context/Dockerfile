FROM base
RUN --mount=type=ssh \
    --mount=type=cache,target=/cache \
    --mount=type=bind,source=payload,target=payload \
    test "$(cat payload)" = payload
