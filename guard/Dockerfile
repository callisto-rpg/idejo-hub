# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only
#
# docker-guard (HN-04). Build from the repository root, so the licence files are in context:
#
#   docker build -f guard/Dockerfile -t idejo-docker-guard .
#
# Same pinned Elixir, Erlang and Debian as the Hub's Dockerfile. Runs as nobody (65534), the
# user the socket proxy's Unix socket belongs to (deploy/docker-compose.yml).

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261027-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

# copy_licence/1 in guard/mix.exs reads them from the parent directory.
WORKDIR /src
COPY LICENSE NOTICE ./
COPY LICENSES LICENSES

WORKDIR /src/guard
COPY guard/mix.exs guard/mix.lock ./
RUN mix deps.get --only $MIX_ENV
COPY guard/config config
RUN mix deps.compile
COPY guard/lib lib
RUN mix compile && mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app
COPY --from=builder --chown=nobody:root /src/guard/_build/prod/rel/docker_guard ./

USER nobody

EXPOSE 2375
CMD ["/app/bin/docker_guard", "start"]
