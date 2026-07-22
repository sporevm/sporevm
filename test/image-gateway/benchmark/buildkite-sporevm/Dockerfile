FROM base

RUN apt-get update \
  && apt-get install --assume-yes --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    iproute2 \
    netcat-openbsd \
    openjdk-17-jre-headless \
    postgresql-client \
    redis-tools \
  && install -m 0755 -d /etc/apt/keyrings \
  && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
  && chmod a+r /etc/apt/keyrings/docker.asc \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" > /etc/apt/sources.list.d/docker.list \
  && apt-get update \
  && apt-get install --assume-yes --no-install-recommends \
    containerd.io \
    docker-ce \
    docker-ce-cli \
    docker-compose-plugin \
  && rm -rf /var/lib/apt/lists/*

COPY compose.yaml /usr/local/share/sporevm-buildkite/compose.yaml
COPY compose-initdb/ /usr/local/share/sporevm-buildkite/initdb/
COPY dynamodb-local/ /opt/sporevm-buildkite-dynamodb/
COPY image/deps/ /opt/sporevm-buildkite-deps/
COPY image/bin/setup-spore /usr/local/bin/setup-spore

RUN chmod +x /usr/local/bin/setup-spore

CMD ["/usr/local/bin/setup-spore"]
