FROM base
RUN mkdir -p /tmp/oracle /run/oracle && printf 'tmp-state\n' >/tmp/oracle/state && printf 'run-state\n' >/run/oracle/state
COPY trigger.txt /oracle/trigger.txt
RUN test "$(cat /tmp/oracle/state)" = tmp-state && test "$(cat /run/oracle/state)" = run-state && cp /tmp/oracle/state /oracle/tmp-state && cp /run/oracle/state /oracle/run-state
WORKDIR /oracle
CMD ["/bin/sh","-c","printf ready"]
