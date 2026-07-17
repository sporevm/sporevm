FROM base
RUN --mount=type=bind,source=input,target=/input test "$(cat /input/value)" = directory
