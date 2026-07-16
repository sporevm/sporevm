FROM base
RUN mkdir -p /real && ln -s /real /alias
RUN --mount=type=cache,target=/alias/cache sh -euxc 'printf should-not-run >/oracle-ran'
