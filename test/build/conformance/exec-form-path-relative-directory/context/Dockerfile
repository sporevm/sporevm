FROM base
WORKDIR /oracle/relative-directory
RUN mkdir -p tools/echo
ENV PATH=tools:/bin
RUN ["echo","relative directory skipped"]
ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin
