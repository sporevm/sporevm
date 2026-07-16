FROM base
ARG TARGETOS
ARG TARGETARCH
ARG TERMINAL_TO_HTML_VERSION=3.16.8
ARG SPORE_VERSION=v0.13.1
ADD "https://github.com/buildkite/terminal-to-html/releases/download/v${TERMINAL_TO_HTML_VERSION}/terminal-to-html-${TERMINAL_TO_HTML_VERSION}-${TARGETOS}-${TARGETARCH}.gz" /oracle/terminal-to-html.gz
ADD "https://raw.githubusercontent.com/sporevm/sporevm/${SPORE_VERSION}/LICENSE" /
