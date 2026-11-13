# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.IdentitiesLive do
  @moduledoc """
  HA-06: the idejo IDs, at `/identities`. Search by email, name or username (`?q=`, kept in
  the address), each result linking to its page (lock, unlock, delete on request); and the
  deletion requests: under way, stopped (with why, and Retry), and the latest finished.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Identity
  alias IdejoHub.Identity.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "idejo IDs", enabled?: Identity.enabled?())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = String.trim(params["q"] || "")

    {results, error} =
      cond do
        not socket.assigns.enabled? -> {nil, nil}
        q == "" -> {nil, nil}
        true -> search(q)
      end

    {:noreply,
     assign(socket,
       q: q,
       form: to_form(%{"q" => q}, as: :search),
       results: results,
       error: error,
       deletions: if(socket.assigns.enabled?, do: Admin.deletions(), else: [])
     )}
  end

  defp search(q) do
    case Admin.search(q) do
      {:ok, people} -> {people, nil}
      {:error, _reason} -> {[], "The identity provider did not answer. Try again in a minute."}
    end
  end

  @impl true
  def handle_event("search", %{"search" => %{"q" => q}}, socket) do
    query = if String.trim(q) == "", do: [], else: [q: String.trim(q)]
    {:noreply, push_patch(socket, to: ~p"/identities?#{query}")}
  end

  def handle_event("retry", %{"subject" => subject}, socket) do
    socket =
      case Admin.retry(subject, socket.assigns.current_operator.email) do
        {:ok, _} -> put_flash(socket, :info, "The deletion starts again.")
        {:error, _} -> put_flash(socket, :error, "That deletion is not stopped.")
      end

    {:noreply, assign(socket, deletions: Admin.deletions())}
  end

  defp deletion_state(%{finished_at: %DateTime{}}), do: "done"
  defp deletion_state(%{error: error}) when is_binary(error), do: "stopped"
  defp deletion_state(_deletion), do: "under way"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator} wide>
      <h1 class="text-2xl font-semibold">idejo IDs</h1>

      <p :if={!@enabled?} id="identities-disabled">
        This Hub has no identity provider: its forums use local accounts only.
      </p>

      <div :if={@enabled?} class="space-y-6">
        <section aria-labelledby="search-title" class="space-y-2">
          <h2 id="search-title" class="text-xl font-semibold">Search</h2>
          <.form for={@form} id="identity-search" phx-submit="search" class="flex items-end gap-2">
            <.input field={@form[:q]} label="Email, name or username contains" />
            <.button class="btn btn-sm">Search</.button>
          </.form>
          <p :if={@error} class="text-error">{@error}</p>
          <p :if={@results == []} id="identities-none">No idejo ID matches.</p>
          <table :if={@results not in [nil, []]} id="identities" class="table table-sm">
            <thead>
              <tr>
                <th>Name</th><th>Email</th><th>State</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @results} id={"identity-#{p.id}"}>
                <td>
                  <.link navigate={~p"/identities/#{p.id}"}>{p.display_name || p.username}</.link>
                </td>
                <td>
                  {p.email}
                  <span :if={!p.email_verified} class="badge badge-sm">not verified</span>
                </td>
                <td>
                  <span class={["badge badge-sm", p.state == "locked" && "badge-error"]}>{p.state}</span>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@results && length(@results) == 50} class="text-sm">
            The first 50: search for more of the address or name.
          </p>
        </section>

        <section aria-labelledby="deletions-title" class="space-y-2">
          <h2 id="deletions-title" class="text-xl font-semibold">Deletion requests</h2>
          <p class="text-sm">
            Members delete their idejo ID themselves from their page; a request made to you
            (by email, by letter) is handled from the ID's page here. Each deletes the
            person's account on every forum they joined, as that forum's rules say, then the ID.
          </p>
          <p :if={@deletions == []} id="deletions-none">None.</p>
          <table :if={@deletions != []} id="deletions" class="table table-sm">
            <thead>
              <tr>
                <th>idejo ID</th><th>Asked (UTC)</th><th>State</th><th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={d <- @deletions} id={"deletion-#{d.subject}"}>
                <td><.link navigate={~p"/identities/#{d.subject}"}>{d.subject}</.link></td>
                <td>{Calendar.strftime(d.requested_at, "%Y-%m-%d %H:%M")}</td>
                <td>
                  {deletion_state(d)}
                  <span :if={d.error && !d.finished_at} class="text-sm text-error">: {d.error}</span>
                </td>
                <td>
                  <button
                    :if={deletion_state(d) == "stopped"}
                    phx-click="retry"
                    phx-value-subject={d.subject}
                    class="btn btn-xs"
                  >
                    Retry
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
