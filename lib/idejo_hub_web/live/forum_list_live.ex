# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ForumListLive do
  @moduledoc """
  HA-01: the forum list. Subdomain, name, owner, status (with the action under way),
  version, members, last backup and its size, sorted and filtered (by status) through the
  address (`?status=`, `?sort=`), so a view can be bookmarked. Changes show live
  (`Forums.subscribe/0`).

  Members are not shown: the Hub never reads a forum's database (CLAUDE.md, The one rule) and
  Idejo's contract has no count yet. The size is the latest backup's, which holds the
  forum's database and uploads.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Forums

  @sorts ~w(subdomain name status version backup size)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Forums.subscribe()
    {:ok, assign(socket, page_title: "Forums", statuses: Forums.Forum.statuses() -- ["deleted"])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    status = if params["status"] in socket.assigns.statuses, do: params["status"]
    sort = if params["sort"] in @sorts, do: params["sort"], else: "subdomain"
    {:noreply, socket |> assign(status: status, sort: sort) |> load()}
  end

  @impl true
  def handle_info({:forum_changed, _forum}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    rows =
      Forums.list_overview()
      |> Enum.filter(&(socket.assigns.status in [nil, &1.forum.status]))
      |> sort(socket.assigns.sort)

    assign(socket,
      rows: rows,
      counts: Enum.frequencies_by(Forums.list_overview(), & &1.forum.status)
    )
  end

  defp sort(rows, "name"), do: Enum.sort_by(rows, &String.downcase(&1.forum.display_name))
  defp sort(rows, "status"), do: Enum.sort_by(rows, &{&1.forum.status, &1.forum.subdomain})

  defp sort(rows, "version"),
    do: Enum.sort_by(rows, &Version.parse!(&1.forum.idejo_version), {:desc, Version})

  defp sort(rows, "backup"), do: Enum.sort_by(rows, &backup_at/1, :asc)

  defp sort(rows, "size"),
    do: Enum.sort_by(rows, &((&1.last_backup && &1.last_backup.size) || 0), :desc)

  defp sort(rows, _subdomain), do: Enum.sort_by(rows, & &1.forum.subdomain)

  # Never backed up first: the ones to look at.
  defp backup_at(%{last_backup: nil}), do: 0
  defp backup_at(%{last_backup: b}), do: DateTime.to_unix(b.inserted_at)

  defp list_path(assigns, changes) do
    query =
      %{"status" => assigns.status, "sort" => assigns.sort}
      |> Map.merge(changes)
      |> Enum.reject(fn {k, v} -> is_nil(v) or (k == "sort" and v == "subdomain") end)

    ~p"/?#{query}"
  end

  defp size(nil), do: "—"
  defp size(bytes) when bytes < 1_048_576, do: "#{max(div(bytes, 1024), 1)} KB"
  defp size(bytes) when bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator} wide>
      <h1 class="text-2xl font-semibold">Forums</h1>

      <nav aria-label="Filter by status" id="status-filter" class="flex flex-wrap gap-2">
        <.link
          patch={list_path(assigns, %{"status" => nil})}
          class={["btn btn-sm", is_nil(@status) && "btn-primary"]}
          aria-current={is_nil(@status) && "page"}
        >
          All ({@counts |> Map.values() |> Enum.sum()})
        </.link>
        <.link
          :for={status <- @statuses}
          patch={list_path(assigns, %{"status" => status})}
          class={["btn btn-sm", @status == status && "btn-primary"]}
          aria-current={@status == status && "page"}
        >
          {status} ({Map.get(@counts, status, 0)})
        </.link>
      </nav>

      <p :if={@rows == []} id="no-forums">No forums here.</p>

      <table :if={@rows != []} id="forums" class="table">
        <thead>
          <tr>
            <th :for={
              {key, label} <- [
                {"subdomain", "Subdomain"},
                {"name", "Name"},
                {nil, "Owner"},
                {"status", "Status"},
                {"version", "Version"},
                {nil, "Members"},
                {"backup", "Last backup"},
                {"size", "Size"}
              ]
            }>
              <.link
                :if={key}
                patch={list_path(assigns, %{"sort" => key})}
                aria-sort={@sort == key && "ascending"}
              >
                {label}
              </.link>
              <span :if={!key}>{label}</span>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={%{forum: f, last_backup: b} <- @rows} id={"forum-#{f.subdomain}"}>
            <td>{f.subdomain}</td>
            <td>{f.display_name}</td>
            <td>{f.owner_email}</td>
            <td>
              <span class="badge">{f.status}</span>
              <span :if={f.step} class="text-sm">({f.step})</span>
              <span :if={f.error} class="text-sm text-error" title={f.error}>error</span>
            </td>
            <td>{f.idejo_version}</td>
            <td title="Not available: the Hub does not read a forum's database">—</td>
            <td>
              <time :if={b} datetime={DateTime.to_iso8601(b.inserted_at)}>
                {Calendar.strftime(b.inserted_at, "%Y-%m-%d %H:%M")} UTC
              </time>
              <span :if={!b}>never</span>
            </td>
            <td>{size(b && b.size)}</td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
