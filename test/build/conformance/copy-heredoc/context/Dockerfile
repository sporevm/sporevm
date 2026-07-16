FROM base
ARG VALUE=initial
ARG DEST=/oracle/plain
RUN mkdir -p /oracle/directory && printf old >/oracle/plain
COPY <<EOF ${DEST}
plain=$VALUE
single='$VALUE'
double="$VALUE"
literal=\$VALUE
unset=${UNSET}
fallback=${UNSET:-fallback}
EOF
COPY <<DOCUMENT /oracle/directory/
named=$VALUE
DOCUMENT
COPY <<EMPTY /oracle/empty
EMPTY
