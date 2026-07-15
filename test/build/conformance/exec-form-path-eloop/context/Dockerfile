FROM base
RUN mkdir -p /oracle/eloop/a /oracle/eloop/b && ln -s /oracle/eloop/a/tool /oracle/eloop/a/tool && printf '#!/bin/sh\nprintf right > /oracle/eloop/result\n' > /oracle/eloop/b/tool && chmod 0755 /oracle/eloop/b/tool
ENV PATH=/oracle/eloop/a:/oracle/eloop/b
RUN ["tool"]
ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin
