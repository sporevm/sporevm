FROM base
RUN mkdir -p /oracle/missing-interpreter/a /oracle/missing-interpreter/b && printf '#!/missing/interpreter\n' > /oracle/missing-interpreter/a/tool && printf '#!/bin/sh\nprintf wrong > /oracle/missing-interpreter/result\n' > /oracle/missing-interpreter/b/tool && chmod 0755 /oracle/missing-interpreter/a/tool /oracle/missing-interpreter/b/tool
ENV PATH=/oracle/missing-interpreter/a:/oracle/missing-interpreter/b
RUN ["tool"]
