FROM public.ecr.aws/docker/library/alpine@sha256:45e09956dc667c5eff3583c9d94830261fb1ca0be10a0a7db36266edf5de9e1d AS resolver-shape
RUN mkdir -p /rootfs/etc && ln -s /run/systemd/resolve/stub-resolv.conf /rootfs/etc/resolv.conf

FROM public.ecr.aws/docker/library/python@sha256:e81548ac35b07a3bd4805f275107592ef458b1e893c0e04d45aedaa19416cca5
COPY scan.py /usr/local/bin/spore-build-conformance-scan
RUN chmod 0755 /usr/local/bin/spore-build-conformance-scan
WORKDIR /
COPY --from=resolver-shape /rootfs/ /
