# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM base AS one
COPY one.txt /out/one.txt
RUN mkdir -p /owned /split \
 && printf 'owned\n' > /owned/file \
 && printf 'split\n' > /split/a \
 && ln /split/a /split/b \
 && cp /owned/file /owned/capability \
 # Comments inside continuations must not terminate the shell command.
 && mkdir /owned/nested \
 && ln /owned/file /owned/hard \
 && ln -s file /owned/link \
 && chmod 0751 /owned \
 && chmod 0640 /owned/file \
 && chown 123:456 /owned /owned/file \
 && chown -h 321:654 /owned/link \
 && touch -d @123 /owned/file \
 && touch -h -d @234 /owned/link \
 && touch -d @345 /owned/nested \
 && python3 -c 'import os; os.setxattr("/owned/capability", "security.capability", bytes.fromhex("0100000200040000000000000000000000000000"))'

FROM base AS two
COPY two.txt /out/two.txt

FROM base AS runtime
ARG TOKEN=must-not-leak
ENV RUNTIME_VALUE=runtime
COPY --from=one /out/one.txt /runtime/one.txt
COPY --from=one /owned /runtime/owned
COPY --from=one /split/a /split/b /runtime/split/
COPY --from=two /out/two.txt /runtime/two.txt
ENTRYPOINT ["/runtime/one.txt", "$TOKEN", "$RUNTIME_VALUE"]
CMD echo "${RUNTIME_VALUE:-fallback}"
