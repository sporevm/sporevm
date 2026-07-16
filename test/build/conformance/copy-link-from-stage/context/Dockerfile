FROM base AS source
COPY payload.txt /source/file
RUN mkdir -p /source/tree/nested \
 && printf 'child\n' > /source/tree/child \
 && printf 'nested\n' > /source/tree/nested/value \
 && ln /source/tree/child /source/tree/hard \
 && ln -s file /source/link \
 && chmod 0640 /source/file \
 && chmod 0751 /source/tree \
 && chmod 0711 /source/tree/nested

FROM base
RUN mkdir -p /oracle /redirect /oracle/file-target /oracle/merge \
 && printf 'redirect-sentinel\n' > /redirect/sentinel \
 && printf 'stale\n' > /oracle/file-target/stale \
 && mkdir /oracle/symlink-target \
 && printf 'stale\n' > /oracle/symlink-target/stale \
 && printf 'existing\n' > /oracle/directory-target \
 && printf 'preserved\n' > /oracle/merge/preserved \
 && chmod 0710 /oracle \
 && chmod 0700 /oracle/merge \
 && ln -s /redirect /oracle/link-ancestor
COPY --link --from=source /source/file /oracle/link-ancestor/file
COPY --from=source --link=TRUE /source/file /oracle/file-target
COPY --link=true --from=source /source/tree /oracle/directory-target
COPY --link --from=source /source/tree /oracle/merge
COPY --link --from=source /source/link /oracle/symlink-target
COPY --link=false --from=source /source/file /oracle/ordinary-file
