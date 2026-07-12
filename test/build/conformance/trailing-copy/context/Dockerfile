FROM base
WORKDIR /oracle
RUN printf 'stable\n' > stable.txt
COPY ./payload.txt /oracle/payload.txt
CMD ["/bin/sh","-c","printf ready"]
