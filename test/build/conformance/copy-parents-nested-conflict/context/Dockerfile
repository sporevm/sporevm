# syntax=docker/dockerfile:1.20
FROM base
RUN mkdir /dest && printf old >/dest/secret
RUN test "$(cat /dest/secret)" = old && mkdir -p /oracle && printf initial >/oracle/result
