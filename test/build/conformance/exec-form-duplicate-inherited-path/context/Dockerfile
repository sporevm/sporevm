FROM base AS prepared
RUN /bin/mkdir -p /oracle/duplicate-env/a /oracle/duplicate-env/b && printf '#!/bin/sh\nprintf wrong > /oracle/duplicate-env/result\n' > /oracle/duplicate-env/a/tool && printf '#!/bin/sh\nprintf right > /oracle/duplicate-env/result\n' > /oracle/duplicate-env/b/tool && /bin/chmod 0755 /oracle/duplicate-env/a/tool /oracle/duplicate-env/b/tool
RUN ["tool"]
ENV PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/bin
RUN ["sh","-c","test \"$PATH\" = /usr/local/bin:/usr/local/sbin:/usr/bin:/bin"]

FROM prepared
RUN ["sh","-c","test \"$PATH\" = /oracle/duplicate-env/b:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin"]
