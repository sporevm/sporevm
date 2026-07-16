FROM base
WORKDIR /work
ENV CACHE_TARGET=/cache/../oracle-cache-default-a
ARG TOKEN=one
RUN --mount=type=cache,target=$CACHE_TARGET --mount=type=cache,target=oracle-cache-default-relative sh -euxc 'absolute=0; relative=0; test ! -f /oracle-cache-default-a/count || absolute=$(cat /oracle-cache-default-a/count); test ! -f oracle-cache-default-relative/count || relative=$(cat oracle-cache-default-relative/count); absolute=$((absolute+1)); relative=$((relative+1)); printf %s $absolute >/oracle-cache-default-a/count; printf %s $relative >oracle-cache-default-relative/count; printf %s $TOKEN >/oracle-cache-default-a/token'
RUN --mount=type=cache,target=/oracle-cache-default-a --mount=type=cache,target=./oracle-cache-default-relative/ sh -euxc 'mkdir -p /oracle; cp /oracle-cache-default-a/count /oracle/absolute-count; cp oracle-cache-default-relative/count /oracle/relative-count; cp /oracle-cache-default-a/token /oracle/token'
