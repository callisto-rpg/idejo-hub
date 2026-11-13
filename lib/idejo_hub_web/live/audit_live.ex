# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.AuditLive do
  @moduledoc """
  SC-07: the Hub's audit log for the operator, at `/audit`: who did what to which forum, when,
  and how it ended, newest first, 50 a page. Filters by forum, action (its start, such as
  `forum.` or `identity.`), outcome and actor, kept in the address (`?forum=&action=&outcome=&actor=`,
  `&before=` for older pages), so a view can be bookmarked. Entries never hold secrets
  (`IdejoHub.Audit.record/5`). A forum's owner sees their forum's part on their idejo ID page
  (`AccountController.log/2`).
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Audit

  @filters ~w(forum action outcome actor)

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Audit log")}

  @impl true
  def handle_params(params, _uri, socket) do
    filters = Map.new(@filters, &{&1, String.trim(params[&1] || "")})
    {entries, more?} = Audit.list(Map.put(filters, "before", params["before"]))

    {:noreply,
     assign(socket,
       filters: filters,
       form: to_form(filters, as: :filter),
       entries: entries,
       more?: more?,
       first_page?: params["before"] in [nil, ""]
     )}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    query = filter |> Map.take(@filters) |> Enum.reject(fn {_k, v} -> String.trim(v) == "" end)
    {:noreply, push_patch(socket, to: ~p"/audit?#{query}")}
  end

  defp page_path(filters, before) do
    query =
      filters
      |> Map.put("before", before)
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    ~p"/audit?#{query}"
  end

  defp details(details) when details == %{}, do: ""

  defp details(details) do
    details
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {key, value} -> "#{key}: #{value(value)}" end)
  end

  defp value(value) when is_binary(value), do: value
  defp value(value) when is_list(value), do: Enum.map_join(value, ", ", &value/1)
  defp value(value), do: inspect(value)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator} wide>
      <h1 class="text-2xl font-semibold">Audit log</h1>
      <p class="text-sm">
        Who did what to which forum, and when; newest first. A forum's owner sees its part
        on their idejo ID page.
      </p>

      <.form for={@form} id="audit-filter" phx-submit="filter" class="flex flex-wrap items-end gap-2">
        <.input field={@form[:forum]} label="Forum (subdomain)" />
        <.input field={@form[:action]} label="Action (starts with)" placeholder="forum.backup" />
        <.input
          field={@form[:outcome]}
          type="select"
          label="Outcome"
          options={[{"Any", ""}, {"requested", "requested"}, {"ok", "ok"}, {"failed", "failed"}]}
        />
        <.input field={@form[:actor]} label="Who (contains)" />
        <.button class="btn btn-sm">Filter</.button>
        <.link patch={~p"/audit"} class="btn btn-ghost btn-sm">Clear</.link>
      </.form>

      <p :if={@entries == []} id="audit-empty">No entries.</p>

      <table :if={@entries != []} id="audit" class="table table-sm">
        <thead>
          <tr>
            <th>When (UTC)</th>
            <th>Who</th>
            <th>Action</th>
            <th>Outcome</th>
            <th>Forum</th>
            <th>Details</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={e <- @entries} id={"audit-#{e.id}"}>
            <td>
              <time datetime={DateTime.to_iso8601(e.inserted_at)}>
                {Calendar.strftime(e.inserted_at, "%Y-%m-%d %H:%M:%S")}
              </time>
            </td>
            <td>{e.actor}</td>
            <td><code>{e.action}</code></td>
            <td>
              <span class={["badge badge-sm", e.outcome == "failed" && "badge-error"]}>
                {e.outcome}
              </span>
            </td>
            <td>
              <.link :if={e.forum_id} navigate={~p"/forums/#{e.forum_id}"}>{e.subdomain}</.link>
            </td>
            <td class="text-sm break-all">{details(e.details)}</td>
          </tr>
        </tbody>
      </table>

      <nav aria-label="Pages" class="flex gap-2">
        <.link :if={!@first_page?} patch={page_path(@filters, nil)} class="btn btn-sm">
          Newest
        </.link>
        <.link
          :if={@more?}
          patch={page_path(@filters, List.last(@entries).id)}
          id="audit-older"
          class="btn btn-sm"
        >
          Older
        </.link>
      </nav>
    </Layouts.app>
    """
  end
end
