FROM base
RUN mkdir -p /owned/cache
RUN --mount=type=cache,target=/owned/cache sh -euxc 'printf cache >/owned/cache/value; mv /owned /moved; ln -s /moved /owned'
