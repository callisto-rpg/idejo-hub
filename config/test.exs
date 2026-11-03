# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :idejo_hub, IdejoHub.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  # The root docker-compose.yml publishes PostgreSQL on 5433, so it can run beside Idejo's
  # development database on 5432.
  port: 5433,
  database: "idejo_hub_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :idejo_hub, IdejoHubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YUhyYoEuogyBLtiBRPWbWbwQZu4lYoeLH3waQ4w7Kq40sIZc6Ebl8Av2I2JSiGOd",
  server: false

# Tests never reach Docker: an in-memory fake stands in for the engine (HN-04).
config :idejo_hub, IdejoHub.Hosting, docker_adapter: IdejoHub.Hosting.Docker.Fake

# The engine adapter's own tests stub docker-guard with Req.Test.
config :idejo_hub, :docker_req_options, plug: {Req.Test, IdejoHub.Hosting.Docker.Engine}

# Forum health checks go to a Req.Test stub, and the wait does not sleep long.
config :idejo_hub, :health_req_options, plug: {Req.Test, IdejoHub.Hosting.Health}
config :idejo_hub, :health_wait, timeout: 200, interval: 10

config :idejo_hub, IdejoHub.Forums.Export, dir: Path.expand("../tmp/test-exports", __DIR__)

config :idejo_hub, IdejoHub.Hosting.Maintenance,
  dir: Path.expand("../tmp/test-forum-state/suspended", __DIR__),
  sync_on_boot: false

# Jobs run only when a test runs them (Oban.Testing).
config :idejo_hub, Oban, testing: :manual

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# SC-04: the key that encrypts forum secrets in the Hub database. Test only, never in
# production (there it comes from HUB_SECRETS_KEY, config/runtime.exs).
config :idejo_hub, IdejoHub.Secrets, key: "fcjlnmVauctvHV2aRFqBHgQaZIAaJpWxxfs8xi4Eu5c="
