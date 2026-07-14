FROM base
WORKDIR /oracle/empty-path
RUN printf '#!/bin/sh\nprintf wrong > /oracle/empty-path-result\n' > tool && chmod 0755 tool
ENV PATH=
RUN ["tool"]
