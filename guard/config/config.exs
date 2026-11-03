# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

import Config

# The Idejo image forums may run, and the Docker network forum containers must join.
config :docker_guard,
  port: 2375,
  image: "ghcr.io/callisto-rpg/idejo",
  network: "idejo-forums",
  req_options: []

import_config "#{config_env()}.exs"
