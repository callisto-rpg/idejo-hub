# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule DockerGuard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:docker_guard, :server, true) do
        [{Bandit, plug: DockerGuard.Router, port: Application.fetch_env!(:docker_guard, :port)}]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: DockerGuard.Supervisor)
  end
end
