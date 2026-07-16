FROM base AS one
RUN mkdir -p /out && printf one >/out/one
FROM base AS two
RUN mkdir -p /out && printf two >/out/two
FROM base
COPY payload /context-payload
COPY --from=one /out/one /one
COPY --from=two /out/two /two
RUN --mount=type=cache,target=/cache true
