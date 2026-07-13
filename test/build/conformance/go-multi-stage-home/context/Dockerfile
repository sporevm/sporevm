# syntax=docker/dockerfile:1
FROM --platform=linux/arm64 golang@sha256:8bee1901f1e530bfb4a7850aa7a479d17ae3a18beb6e09064ed54cfd245b7191 AS build
WORKDIR /src
COPY go.mod main.go message.txt ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o /out/app .
ENV HOME=/tmp/explicit-home
RUN test "$HOME" = /tmp/explicit-home && printf 'explicit-home\n' > /out/explicit-home
ENV HOME=
RUN test "$HOME" = /root && printf 'empty-home-defaulted\n' > /out/empty-home-defaulted

FROM scratch
COPY --from=build /out/app /app
COPY --from=build /out/explicit-home /explicit-home
COPY --from=build /out/empty-home-defaulted /empty-home-defaulted
COPY --from=build /out/app /usr/local/bin/spore-build-conformance-scan
ENV APP_FLAVOR=packaged
ENTRYPOINT ["/app"]
