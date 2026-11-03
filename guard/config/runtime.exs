# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

import Config

# docker-guard's settings (HN-04), all optional; see deploy/docker-compose.yml.
if config_env() == :prod do
  config :docker_guard,
    port: String.to_integer(System.get_env("DOCKER_GUARD_PORT", "2375")),
    image: System.get_env("DOCKER_GUARD_IMAGE", "ghcr.io/callisto-rpg/idejo"),
    network: System.get_env("DOCKER_GUARD_NETWORK", "idejo-forums"),
    req_options: [
      unix_socket: System.get_env("DOCKER_GUARD_UPSTREAM_SOCKET", "/run/socket-proxy/proxy.sock")
    ]
end
