# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

import Config

# No listener in tests; Req goes to a Req.Test stub instead of the socket proxy.
config :docker_guard,
  server: false,
  req_options: [plug: {Req.Test, DockerGuard.Upstream}]

config :logger, level: :warning
