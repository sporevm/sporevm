# syntax=docker/dockerfile:1.20
FROM base
WORKDIR /work
COPY --parents \
    lib/x.rb \
    app/helpers/ \
    public/*.html \
    ./
COPY --parents lib/x.rb public/*.html /no-slash
RUN test "$(cat lib/x.rb)" = ruby \
    && test "$(cat app/helpers/value.rb)" = helper \
    && test "$(cat public/a.html)" = a \
    && test "$(cat public/z.html)" = z \
    && test "$(cat /no-slash/lib/x.rb)" = ruby \
    && test "$(cat /no-slash/public/a.html)" = a \
    && test "$(cat /no-slash/public/z.html)" = z \
    && mkdir -p /oracle \
    && printf ready >/oracle/result
