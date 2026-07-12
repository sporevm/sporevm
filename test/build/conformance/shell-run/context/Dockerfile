FROM base
WORKDIR /oracle
RUN test -s /etc/resolv.conf && printf 'shell-run\n' > output.txt && chmod 0640 output.txt && mkdir empty
RUN test -s /etc/resolv.conf && printf 'resolver-after-checkpoint\n' > resolver.txt
CMD ["/bin/sh","-c","printf ready"]
