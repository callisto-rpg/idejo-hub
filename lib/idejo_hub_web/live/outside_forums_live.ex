# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.OutsideForumsLive do
  @moduledoc """
  Outside forums (steward decisions 2026-11-06): idejo servers not hosted here that sign in
  with this Hub's idejo ID (`IdejoHub.Identity.OutsideForums`). Listing requests first:
  Approve puts the forum in the directory, Refuse keeps it out; Remove deletes its client,
  so its sign-in with idejo ID stops. Every decision is audited.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Identity.OutsideForums

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, socket |> assign(page_title: "Outside forums") |> load()}

  @impl true
  def handle_event("decide", %{"id" => id, "decision" => decision}, socket)
      when decision in ["approved", "refused"] do
    socket =
      case OutsideForums.decide(id, decision, socket.assigns.current_operator.email) do
        {:ok, forum} -> put_flash(socket, :info, "#{forum.host}: #{label(forum.listing)}.")
        {:error, _} -> put_flash(socket, :error, "That forum has not asked to be listed.")
      end

    {:noreply, load(socket)}
  end

  def handle_event("remove", %{"id" => id}, socket) do
    socket =
      case OutsideForums.remove(id, socket.assigns.current_operator.email) do
        :ok -> put_flash(socket, :info, "Removed: its sign-in with idejo ID has stopped.")
        {:error, _} -> put_flash(socket, :error, "The provider could not be reached: try again.")
      end

    {:noreply, load(socket)}
  end

  defp load(socket), do: assign(socket, forums: OutsideForums.list())

  defp label("none"), do: "not asking to be listed"
  defp label("requested"), do: "asks to be listed"
  defp label("approved"), do: "listed"
  defp label("refused"), do: "refused"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator} wide>
      <h1 class="text-2xl font-semibold">Outside forums</h1>
      <p>
        idejo servers hosted elsewhere that sign in with this Hub's idejo ID. They appear in
        the forums directory once you approve their request.
      </p>
      <p :if={@forums == []} id="no-outside-forums">No outside forum has registered yet.</p>
      <table :if={@forums != []} id="outside-forums" class="table">
        <thead>
          <tr>
            <th>Forum</th>
            <th>Registered</th>
            <th>Directory</th>
            <th><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={f <- @forums} id={"outside-#{f.id}"}>
            <td>
              <a href={"https://#{f.host}/"} rel="noopener noreferrer">{f.display_name}</a>
              <span class="text-sm opacity-70">{f.host}</span>
            </td>
            <td>{if f.status == "registered", do: "yes", else: "not proven yet"}</td>
            <td><span class="badge">{label(f.listing)}</span></td>
            <td class="flex flex-wrap gap-2">
              <button
                :if={f.listing == "requested"}
                class="btn btn-sm btn-primary"
                phx-click="decide"
                phx-value-id={f.id}
                phx-value-decision="approved"
              >
                Approve
              </button>
              <button
                :if={f.listing in ["requested", "approved"]}
                class="btn btn-sm"
                phx-click="decide"
                phx-value-id={f.id}
                phx-value-decision="refused"
              >
                {if f.listing == "approved", do: "Take out of the directory", else: "Refuse"}
              </button>
              <button
                class="btn btn-sm btn-error"
                phx-click="remove"
                phx-value-id={f.id}
                data-confirm={"Remove #{f.host}? Its members can no longer sign in there with idejo ID until it registers again."}
              >
                Remove
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
