FROM ruby:3.3-alpine

ARG TARGETPLATFORM

ENV BUNDLE_WITHOUT=development \
    BUNDLE_PATH=/usr/local/bundle \
    RAILS_ENV=test

RUN apk add --no-cache \
      bash \
      ca-certificates \
      postgresql \
      postgresql-client \
      su-exec \
      tzdata \
      libxml2 \
      libxslt \
      openssl \
      yaml \
      zlib

WORKDIR /opt/sporevm-rails-src
COPY app/Gemfile ./Gemfile
RUN apk add --no-cache --virtual .build-deps \
      build-base \
      libxml2-dev \
      libxslt-dev \
      openssl-dev \
      postgresql-dev \
      yaml-dev \
      zlib-dev \
    && bundle lock --add-platform aarch64-linux-musl \
    && bundle install \
    && bundle clean --force \
    && rm -rf /usr/local/bundle/cache/*.gem /root/.bundle \
    && apk del .build-deps

COPY app/ /opt/sporevm-rails-src/

COPY image/bin/sporevm-rails-coordinator /usr/local/bin/sporevm-rails-coordinator
COPY image/bin/sporevm-rspec-shard /usr/local/bin/sporevm-rspec-shard
RUN chmod +x \
      /usr/local/bin/sporevm-rails-coordinator \
      /usr/local/bin/sporevm-rspec-shard

CMD ["/bin/bash", "/usr/local/bin/sporevm-rails-coordinator"]
