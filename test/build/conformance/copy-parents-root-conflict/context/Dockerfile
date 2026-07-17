# syntax=docker/dockerfile:1.20
FROM base
RUN printf old >/dest
RUN test "$(cat /dest)" = old && mkdir -p /oracle && printf initial >/oracle/result
