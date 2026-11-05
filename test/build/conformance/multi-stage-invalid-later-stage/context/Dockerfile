# syntax=docker/dockerfile:1.20
FROM base AS build
RUN mkdir -p /oracle && printf one >/oracle/built
FROM build
COPY src/payload /out/
