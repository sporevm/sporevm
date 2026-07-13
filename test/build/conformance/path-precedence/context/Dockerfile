ARG PATH=/global-default
FROM base
RUN mkdir -p /oracle \
    && mv /usr/local/bin/spore-build-conformance-scan /usr/local/bin/spore-build-conformance-scan.py \
    && printf '#!/bin/sh\nexec /usr/local/bin/python3 /usr/local/bin/spore-build-conformance-scan.py "$@"\n' > /usr/local/bin/spore-build-conformance-scan \
    && chmod 0755 /usr/local/bin/spore-build-conformance-scan \
    && printf '%s\n' "$PATH" > /oracle/implicit
ENV IMPLICIT_SNAPSHOT=$PATH
ARG PATH
RUN printf '%s\n' "$PATH" > /oracle/declared-arg
ENV DECLARED_ARG_SNAPSHOT=$PATH
ENV PATH=/env-after-arg
RUN printf '%s\n' "$PATH" > /oracle/arg-then-env
ENV ARG_THEN_ENV_SNAPSHOT=$PATH
ARG PATH
RUN printf '%s\n' "$PATH" > /oracle/env-then-arg
ENV ENV_THEN_ARG_SNAPSHOT=$PATH
ENV PATH=
RUN printf '<%s>\n' "$PATH" > /oracle/empty-env
ENV EMPTY_ENV_SNAPSHOT=$PATH
