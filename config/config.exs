# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :idejo_hub,
  ecto_repos: [IdejoHub.Repo],
  generators: [timestamp_type: :utc_datetime]

# Lifecycle (FL) and operations (OP) actions run as Oban jobs stored in the Hub's database,
# so each action has clear states and survives a restart. The crontab comes with OP-01.
config :idejo_hub, Oban,
  repo: IdejoHub.Repo,
  queues: [lifecycle: 2, operations: 2],
  plugins: [Oban.Plugins.Pruner]

# Docker access (HN-04, steward decision 2026-11-03): the Hub reaches Docker only through
# docker-guard and the socket proxy, never the socket itself. Forums run the official image on
# their own network. Production values come from config/runtime.exs.
config :idejo_hub, IdejoHub.Hosting,
  docker_adapter: IdejoHub.Hosting.Docker.Engine,
  docker_url: "http://localhost:2375",
  forum_image: "ghcr.io/callisto-rpg/idejo",
  forum_network: "idejo-forums"

# Forums (FL): the domain whose subdomains forums get (`<subdomain>.<domain>`), the database
# server's name on the forum network, and defaults for new forums. LB-03: each forum's
# IDEJO_SOURCE_URL is source_url_base followed by its exact version.
config :idejo_hub, IdejoHub.Forums,
  domain: "idejo.test",
  db_host: "db",
  default_version: "0.1.0",
  default_memory_mb: 384,
  default_cpus: 0.5,
  source_url_base: "https://github.com/callisto-rpg/Idejo/tree/v"

# FL-06: where the Hub keeps forum exports (a volume in deploy/).
config :idejo_hub, IdejoHub.Forums.Export, dir: Path.expand("../tmp/exports", __DIR__)

# FL-04: where suspended forums are marked for Caddy (a volume shared with it in deploy/).
config :idejo_hub, IdejoHub.Hosting.Maintenance,
  dir: Path.expand("../tmp/forum-state/suspended", __DIR__)

# Configure the endpoint
config :idejo_hub, IdejoHubWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: IdejoHubWeb.ErrorHTML, json: IdejoHubWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: IdejoHub.PubSub,
  live_view: [signing_salt: "d84fVpXu"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  idejo_hub: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  idejo_hub: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
