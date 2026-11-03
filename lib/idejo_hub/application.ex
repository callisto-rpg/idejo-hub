# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias IdejoHub.Hosting.Maintenance
  alias IdejoHub.Identity.SetupWorker

  @impl true
  def start(_type, _args) do
    # SC-04: refuse to start without a usable key for forum secrets.
    IdejoHub.Secrets.validate_key!()

    children = [
      IdejoHubWeb.Telemetry,
      IdejoHub.Repo,
      {DNSCluster, query: Application.get_env(:idejo_hub, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: IdejoHub.PubSub},
      IdejoHub.RateLimit,
      # FL-04: make Caddy's maintenance marks match the suspended forums.
      maintenance_sync(),
      # Lifecycle (FL) and operations (OP) jobs, stored in PostgreSQL.
      {Oban, Application.fetch_env!(:idejo_hub, Oban)},
      # ID-02, ID-08: the identity provider's settings, once Oban runs.
      Supervisor.child_spec({Task, &SetupWorker.queue/0}, id: :identity_setup),
      # Start to serve requests, typically the last entry
      IdejoHubWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: IdejoHub.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    IdejoHubWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maintenance_sync do
    if Application.get_env(:idejo_hub, Maintenance)[:sync_on_boot] == false,
      do: {Task, fn -> :ok end},
      else: {Task, &Maintenance.sync/0}
  end
end
