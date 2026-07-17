FROM base
WORKDIR /work
RUN --mount=type=cache,target=relative-cache sh -euxc 'mkdir -p /oracle; printf relative >/oracle/relative'
RUN --mount=type=cache,target=/equal,id=/equal,sharing=shared sh -euxc 'printf explicit >/oracle/explicit'
