# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/idejo_hub start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :idejo_hub, IdejoHubWeb.Endpoint, server: true
end

config :idejo_hub, IdejoHubWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :idejo_hub, IdejoHubWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/idejo_hub_web/router\.ex$"E,
        ~r"lib/idejo_hub_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  # Compose passes POOL_SIZE as an empty string when it is not set in deploy/.env.
  pool_size =
    case System.get_env("POOL_SIZE", "") do
      "" -> "10"
      value -> value
    end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :idejo_hub, IdejoHub.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(pool_size),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Never a hard-coded domain (LB-05): the Hub's own host comes from the environment.
  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the Hub's own host name, for example: hub.example.org
      """

  # SC-04: encrypts forum secrets stored in the Hub database. Losing it means the Hub can no
  # longer recreate forum containers; keep a copy with the Hub's backups.
  config :idejo_hub, IdejoHub.Secrets,
    key:
      System.get_env("HUB_SECRETS_KEY") ||
        raise("""
        environment variable HUB_SECRETS_KEY is missing.
        Generate one with: openssl rand -base64 32
        """)

  # FL: forums are `<subdomain>.IDEJO_FORUM_DOMAIN` (never hard-coded, LB-05).
  config :idejo_hub, IdejoHub.Forums,
    domain:
      System.get_env("IDEJO_FORUM_DOMAIN") ||
        raise("""
        environment variable IDEJO_FORUM_DOMAIN is missing.
        Set it to the domain forums are subdomains of, for example forums.example.org
        """),
    default_version: System.get_env("IDEJO_DEFAULT_VERSION", "0.2.2")

  # OP-01: when forums are backed up (cron, UTC) and how many backups are kept per forum.
  # Empty means the default.
  env_or = fn name, default ->
    case System.get_env(name, "") |> String.trim() do
      "" -> default
      value -> value
    end
  end

  config :idejo_hub, Oban,
    plugins: [
      Oban.Plugins.Pruner,
      {Oban.Plugins.Cron,
       crontab: [
         {env_or.("IDEJO_HUB_BACKUP_CRON", "0 2 * * *"), IdejoHub.Operations.BackupScheduler},
         {"*/15 * * * *", IdejoHub.Operations.StatsWorker},
         {"* * * * *", IdejoHub.Operations.HealthWorker},
         {"*/5 * * * *", IdejoHub.Identity.SyncWorker}
       ]}
    ]

  config :idejo_hub, IdejoHub.Operations,
    backups_kept: String.to_integer(env_or.("IDEJO_HUB_BACKUPS_KEPT", "14")),
    # OP-04: seconds an upgraded forum has to answer /health before it is rolled back.
    upgrade_health_timeout:
      String.to_integer(env_or.("IDEJO_HUB_UPGRADE_HEALTH_SECONDS", "300")) * 1000

  # OP-10: the identity provider's database is dumped as its own role (steward decision
  # 2026-11-04); without ZITADEL_DB_PASSWORD only the Hub's database is backed up.
  config :idejo_hub, IdejoHub.Operations.HubBackup,
    zitadel: [
      hostname: env_or.("ZITADEL_DB_HOST", "db"),
      port: 5432,
      username: "zitadel",
      database: "zitadel",
      password: System.get_env("ZITADEL_DB_PASSWORD")
    ]

  # OP-02: off-server copies (steward decision 2026-11-04). With a bucket, every other value
  # is required, and the age public key must look like one: a copy is never sent unencrypted.
  s3_bucket = env_or.("IDEJO_HUB_S3_BUCKET", nil)

  if s3_bucket do
    required = fn name ->
      env_or.(name, nil) ||
        raise "IDEJO_HUB_S3_BUCKET is set, so #{name} is required (deploy/.env.example, OP-02)"
    end

    recipient = required.("IDEJO_HUB_BACKUP_AGE_RECIPIENT")

    unless recipient =~ ~r/\Aage1[02-9ac-hj-np-z]{58}\z/ do
      raise "IDEJO_HUB_BACKUP_AGE_RECIPIENT is not an age public key (age1..., from age-keygen)"
    end

    prefix =
      case env_or.("IDEJO_HUB_S3_PREFIX", "") |> String.trim("/") do
        "" -> ""
        prefix -> prefix <> "/"
      end

    config :idejo_hub, IdejoHub.Operations.Offsite,
      endpoint: required.("IDEJO_HUB_S3_ENDPOINT") |> String.trim_trailing("/"),
      region: env_or.("IDEJO_HUB_S3_REGION", "us-east-1"),
      bucket: s3_bucket,
      prefix: prefix,
      access_key_id: required.("IDEJO_HUB_S3_ACCESS_KEY_ID"),
      secret_access_key: required.("IDEJO_HUB_S3_SECRET_ACCESS_KEY"),
      recipient: recipient
  end

  # FL-06: forum exports (the `exports` volume, deploy/docker-compose.yml).
  config :idejo_hub, IdejoHub.Forums.Export, dir: "/data/exports"

  # FL-07: the largest standalone backup the import form takes, in MB (default 4096).
  config :idejo_hub, IdejoHub.Forums.Import,
    max_bytes: String.to_integer(env_or.("IDEJO_HUB_IMPORT_MAX_MB", "4096")) * 1_048_576

  # FL-04: the volume Caddy reads (deploy/docker-compose.yml).
  config :idejo_hub, IdejoHub.Hosting.Maintenance, dir: "/data/forum-state/suspended"

  # HN-07: optional SMTP server shared by every forum (passed to them as IDEJO_SMTP_*).
  # A forum's own SMTP is set in its Admin → Email and wins over this.
  shared_smtp =
    case System.get_env("HUB_SMTP_HOST", "") |> String.trim() do
      "" ->
        nil

      host ->
        port = System.get_env("HUB_SMTP_PORT", "") |> String.trim()
        security = System.get_env("HUB_SMTP_SECURITY", "") |> String.trim()

        port in ["" | Enum.map(1..65_535, &Integer.to_string/1)] ||
          raise "environment variable HUB_SMTP_PORT must be a port number (1 to 65535)."

        security in ["", "starttls", "tls", "none"] ||
          raise "environment variable HUB_SMTP_SECURITY must be starttls, tls or none."

        [
          host: host,
          port: port,
          security: security,
          username: System.get_env("HUB_SMTP_USERNAME", ""),
          password: System.get_env("HUB_SMTP_PASSWORD", "")
        ]
    end

  config :idejo_hub, IdejoHub.Forums.Mail, shared_smtp: shared_smtp

  # ID-01: the identity provider (Zitadel) and the Hub's token for its API.
  config :idejo_hub, IdejoHub.Identity,
    adapter: IdejoHub.Identity.Zitadel,
    domain: env_or.("IDEJO_ID_DOMAIN", "id." <> host),
    token_file: env_or.("ZITADEL_TOKEN_FILE", "/zitadel-tokens/hub.pat")

  # HN-04: docker-guard's address, and the image and network every forum uses.
  config :idejo_hub, IdejoHub.Hosting,
    docker_url: System.get_env("DOCKER_GUARD_URL", "http://docker-guard:2375"),
    forum_image: System.get_env("IDEJO_FORUM_IMAGE", "ghcr.io/callisto-rpg/idejo"),
    forum_network: System.get_env("IDEJO_FORUM_NETWORK", "idejo-forums")

  config :idejo_hub, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :idejo_hub, IdejoHubWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :idejo_hub, IdejoHubWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :idejo_hub, IdejoHubWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
