FROM base
WORKDIR /oracle/relative-path
RUN mkdir tools && printf '#!/bin/sh\nprintf wrong > /oracle/relative-path-result\n' > tools/tool && chmod 0755 tools/tool
ENV PATH=tools:/bin
RUN ["tool"]
