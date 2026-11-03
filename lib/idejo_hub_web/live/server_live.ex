# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ServerLive do
  @moduledoc """
  HA-04: the server page: CPU, memory, disk, PostgreSQL sizes and the forum containers
  (`Operations.Server.snapshot/0`), refreshed every 10 seconds while open.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Operations.Server

  @refresh 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, :refresh)
    {:ok, assign(socket, page_title: "Server", server: Server.snapshot())}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign(socket, server: Server.snapshot())}

  defp bytes(n) when n >= 1_073_741_824, do: "#{Float.round(n / 1_073_741_824, 1)} GB"
  defp bytes(n) when n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp bytes(n), do: "#{max(div(n, 1024), 1)} KB"

  defp percent(part, whole) when whole > 0, do: "#{round(part * 100 / whole)}%"
  defp percent(_part, _whole), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator} wide>
      <h1 class="text-2xl font-semibold">Server</h1>

      <section id="cpu">
        <h2 class="text-xl font-semibold">CPU</h2>
        <p :if={@server.cpu == :unavailable}>Unavailable.</p>
        <p :if={@server.cpu != :unavailable}>
          Load {Enum.join(@server.cpu.load, " / ")} (1, 5, 15 min) on {@server.cpu.cores} cores
        </p>
      </section>

      <section id="memory">
        <h2 class="text-xl font-semibold">Memory</h2>
        <p :if={@server.memory == :unavailable}>Unavailable.</p>
        <p :if={@server.memory != :unavailable}>
          {bytes(@server.memory.total - @server.memory.available)} used of {bytes(
            @server.memory.total
          )} ({percent(@server.memory.total - @server.memory.available, @server.memory.total)}), {bytes(
            @server.memory.available
          )} available
        </p>
      </section>

      <section id="disk">
        <h2 class="text-xl font-semibold">Disk</h2>
        <p :if={@server.disk == :unavailable}>Unavailable.</p>
        <p :if={@server.disk != :unavailable}>
          {bytes(@server.disk.used)} used of {bytes(@server.disk.total)} ({percent(
            @server.disk.used,
            @server.disk.total
          )}), {bytes(@server.disk.available)} free
        </p>
      </section>

      <section id="databases">
        <h2 class="text-xl font-semibold">PostgreSQL</h2>
        <p :if={@server.databases == :unavailable}>Unavailable.</p>
        <table :if={@server.databases != :unavailable} class="table table-sm">
          <thead>
            <tr>
              <th>Database</th><th>Size</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={db <- @server.databases} id={"db-#{db.name}"}>
              <td>{db.name}</td><td>{bytes(db.size)}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <section id="containers">
        <h2 class="text-xl font-semibold">Forum containers</h2>
        <p :if={@server.containers == :unavailable}>Unavailable (Docker could not be reached).</p>
        <p :if={@server.containers == []}>None.</p>
        <table :if={is_list(@server.containers) and @server.containers != []} class="table table-sm">
          <thead>
            <tr>
              <th>Container</th><th>State</th><th>Status</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={c <- @server.containers} id={"container-#{c.name}"}>
              <td>{c.name}</td><td>{c.state}</td><td>{c.status}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end
end
