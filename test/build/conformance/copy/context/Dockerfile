FROM base
RUN mkdir -p /oracle/preserved && chmod 0700 /oracle/preserved
COPY files /oracle/files/
COPY files /oracle/preserved/
COPY files[/]plain.txt /oracle/class-separator.txt
COPY links/plain-link /oracle/plain-link
COPY empty-dir /oracle/empty/
WORKDIR /oracle
CMD ["/bin/sh","-c","printf ready"]
