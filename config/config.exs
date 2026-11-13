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
  # OP-07: health checks have a queue of their own, so a long backup never holds them up.
  queues: [lifecycle: 2, operations: 2, health: 1],
  plugins: [
    Oban.Plugins.Pruner,
    # OP-01: daily backups of every running forum (IDEJO_HUB_BACKUP_CRON in production).
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 * * *", IdejoHub.Operations.BackupScheduler},
       # HA-01: forum figures (idejo-admin stats).
       {"*/15 * * * *", IdejoHub.Operations.StatsWorker},
       # OP-07: every forum's health and memory, every minute.
       {"* * * * *", IdejoHub.Operations.HealthWorker},
       # ID-05: sign-ins to forums, read from the identity provider.
       {"*/5 * * * *", IdejoHub.Identity.SyncWorker},
       # OP-09: new idejo releases, once a day.
       {"17 6 * * *", IdejoHub.Operations.ReleaseCheckWorker}
     ]}
  ]

# OP-09: where the Hub reads idejo's releases (empty: off), and its changelog link.
config :idejo_hub, IdejoHub.Operations.Releases,
  url: "https://api.github.com/repos/callisto-rpg/Idejo/tags",
  changelog: "https://github.com/callisto-rpg/Idejo/compare/v{from}...v{to}"

# OP-08: the Hub's own email (alerts), over the shared SMTP server (IdejoHub.Mailer).
config :idejo_hub, IdejoHub.Mailer, adapter: Swoosh.Adapters.SMTP
config :swoosh, :api_client, false

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
  default_version: "0.3.6",
  default_memory_mb: 384,
  default_cpus: 0.5,
  # FL-05: days between a deletion and the purge.
  deletion_grace_days: 30,
  source_url_base: "https://github.com/callisto-rpg/Idejo/tree/v"

# OP-01: scheduled backups kept per forum.
# OP-04: how long an upgraded forum has to answer /health (its migrations run first).
config :idejo_hub, IdejoHub.Operations, backups_kept: 14, upgrade_health_timeout: 300_000

# OP-02: off-server copies (off without a bucket; IDEJO_HUB_S3_* in production).
config :idejo_hub, IdejoHub.Operations.Offsite, age: "age", bucket: nil

# OP-10: pg_dump for the Hub's database and the identity provider's (its role and password;
# ZITADEL_DB_PASSWORD in production, none in development, so only the Hub's is dumped).
config :idejo_hub, IdejoHub.Operations.HubBackup,
  pg_dump: "pg_dump",
  zitadel: [hostname: "db", port: 5432, username: "zitadel", database: "zitadel", password: nil]

# ID-01: the identity provider (Zitadel) at its own host; the Hub's API token file.
config :idejo_hub, IdejoHub.Identity,
  adapter: nil,
  domain: "id.idejo.test",
  api_url: "http://zitadel:8080",
  token_file: nil,
  label: "idejo ID"

# FL-06: where the Hub keeps forum exports (a volume in deploy/).
config :idejo_hub, IdejoHub.Forums.Export, dir: Path.expand("../tmp/exports", __DIR__)

# FL-07: the largest standalone backup the import form takes (IDEJO_HUB_IMPORT_MAX_MB).
config :idejo_hub, IdejoHub.Forums.Import, max_bytes: 4096 * 1_048_576

# FL-04: where suspended forums are marked for Caddy (a volume shared with it in deploy/).
config :idejo_hub, IdejoHub.Hosting.Maintenance,
  dir: Path.expand("../tmp/forum-state/suspended", __DIR__)

# SC-08: operator passwords, Argon2id at idejo's pinned cost (3 passes, 64 MiB).
config :argon2_elixir, argon2_type: 2, t_cost: 3, m_cost: 16, parallelism: 4

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
