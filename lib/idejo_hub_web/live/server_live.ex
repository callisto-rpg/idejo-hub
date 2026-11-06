# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ServerLive do
  @moduledoc """
  HA-04: the server page: CPU, memory, disk, PostgreSQL sizes and the forum containers
  (`Operations.Server.snapshot/0`), refreshed every 10 seconds while open. OP-10: the newest
  backup of the Hub's database and the identity provider's, the last run's outcome, and
  "Back up the Hub now" (`Operations.backup_hub/1`).
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Operations
  alias IdejoHub.Operations.{HubBackup, Releases, Server}

  @refresh 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh, :refresh)

    {:ok,
     socket
     |> assign(
       page_title: "Server",
       server: Server.snapshot(),
       release: Releases.notice()
     )
     |> load_backups()}
  end

  @impl true
  def handle_info(:refresh, socket),
    do: {:noreply, socket |> assign(server: Server.snapshot()) |> load_backups()}

  @impl true
  def handle_event("backup_hub", _params, socket) do
    message =
      case Operations.backup_hub(socket.assigns.current_operator.email) do
        {:ok, _job} -> "Hub backup started."
        {:error, :already_running} -> "A Hub backup is already running."
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  defp load_backups(socket),
    do: assign(socket, hub_backups: HubBackup.latest(), hub_backup_run: HubBackup.last_run())

  defp kind_label("hub"), do: "Hub database"
  defp kind_label("zitadel"), do: "Identity provider (Zitadel)"

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
      <.release_notice release={@release} />

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

      <section id="hub-backups">
        <h2 class="text-xl font-semibold">Hub backups</h2>
        <p :if={@hub_backups == %{}}>None yet.</p>
        <table :if={@hub_backups != %{}} class="table table-sm">
          <thead>
            <tr>
              <th>What</th><th>Newest</th><th>Size</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={{kind, b} <- Enum.sort(@hub_backups)} id={"hub-backup-#{kind}"}>
              <td>{kind_label(kind)}</td>
              <td>{Calendar.strftime(b.inserted_at, "%Y-%m-%d %H:%M")} UTC</td>
              <td>{bytes(b.size)}</td>
            </tr>
          </tbody>
        </table>
        <p
          :if={@hub_backup_run && @hub_backup_run.outcome == "failed"}
          id="hub-backup-failed"
          class="text-error"
        >
          The last Hub backup failed ({@hub_backup_run.details["failed"]}: {@hub_backup_run.details[
            "error"
          ]}).
        </p>
        <button id="backup-hub" class="btn btn-sm" phx-click="backup_hub">
          Back up the Hub now
        </button>
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
