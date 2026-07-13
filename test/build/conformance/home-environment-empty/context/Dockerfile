FROM base AS matrix
RUN mkdir -p /oracle && test "$HOME" = /root && printf '<%s>\n' "$HOME" | tee /oracle/absent
ENV HOME=
RUN test "$HOME" = /root && printf '<%s>\n' "$HOME" | tee /oracle/empty-env
ENV HOME=/explicit-home
RUN test "$HOME" = /explicit-home && printf '<%s>\n' "$HOME" | tee /oracle/explicit-env
ARG HOME=/arg-default
ARG EXPECTED_HOME_AFTER_ARG=/arg-default
RUN test "$HOME" = "$EXPECTED_HOME_AFTER_ARG" && printf '<%s>\n' "$HOME" | tee /oracle/env-then-arg
ENV HOME=/env-after-arg
RUN test "$HOME" = /env-after-arg && printf '<%s>\n' "$HOME" | tee /oracle/arg-then-env

FROM matrix
ENV HOME=
