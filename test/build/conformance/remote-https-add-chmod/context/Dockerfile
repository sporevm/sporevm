FROM base
RUN mkdir -p /oracle \
 && printf old >/oracle/chmod-file \
 && printf target >/oracle/chmod-target \
 && ln -s /oracle/chmod-target /chmod-link \
 && chmod 0777 /oracle/chmod-file /oracle/chmod-target
ARG MODE=0644
ADD --chmod="${MODE}" https://www.postgresql.org/media/keys/ACCC4CF8.asc /oracle/chmod-file
ADD --chmod=07777 https://www.postgresql.org/media/keys/ACCC4CF8.asc /chmod-link
