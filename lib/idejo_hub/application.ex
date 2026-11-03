# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      IdejoHubWeb.Telemetry,
      IdejoHub.Repo,
      {DNSCluster, query: Application.get_env(:idejo_hub, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: IdejoHub.PubSub},
      # Lifecycle (FL) and operations (OP) jobs, stored in PostgreSQL.
      {Oban, Application.fetch_env!(:idejo_hub, Oban)},
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
end
