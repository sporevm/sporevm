FROM base
RUN --mount=type=cache,target=/one,id=same,sharing=shared true
RUN --mount=type=cache,target=/two,id=same,sharing=locked true
