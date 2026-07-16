# syntax=docker/dockerfile:1.20
FROM alpine:3.22 AS tools
FROM scratch
COPY --from=tools /bin /bin
COPY --from=tools /lib /lib
COPY proc-file /proc
RUN ["/bin/busybox","true"]
