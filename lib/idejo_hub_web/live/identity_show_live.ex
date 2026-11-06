# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.IdentityShowLive do
  @moduledoc """
  HA-06: one Idejo ID, at `/identities/:id` (the provider's id): its email, state, the forums
  it joined, and what the audit log holds about it. The operator locks it for abuse (a reason
  required) or unlocks it, and deletes it when its owner asked them to (the email typed
  again, and who asked and how), which runs as the member's own deletion does (ID-06).
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Identity.Admin

  @impl true
  def mount(%{"id" => subject}, _session, socket) do
    {:ok, socket |> assign(subject: subject, page_title: "Idejo ID") |> load()}
  end

  defp load(socket) do
    case Admin.get(socket.assigns.subject) do
      {:ok, person} ->
        assign(socket, person: person, log: Admin.log(socket.assigns.subject), error: nil)

      {:error, :not_found} ->
        assign(socket, person: nil, log: [], error: "No such Idejo ID.")

      {:error, _} ->
        assign(socket, person: nil, log: [], error: "The identity provider did not answer.")
    end
  end

  @impl true
  def handle_event("lock", %{"reason" => reason}, socket) do
    socket =
      case Admin.lock(socket.assigns.subject, reason, operator(socket)) do
        :ok -> put_flash(socket, :info, "Locked: this Idejo ID can no longer sign in.")
        {:error, :reason} -> put_flash(socket, :error, "Give a reason: it goes in the audit log.")
        {:error, _} -> put_flash(socket, :error, "The identity provider refused. Try again.")
      end

    {:noreply, load(socket)}
  end

  def handle_event("unlock", _params, socket) do
    socket =
      case Admin.unlock(socket.assigns.subject, operator(socket)) do
        :ok -> put_flash(socket, :info, "Unlocked: this Idejo ID can sign in again.")
        {:error, _} -> put_flash(socket, :error, "The identity provider refused. Try again.")
      end

    {:noreply, load(socket)}
  end

  def handle_event("delete", %{"email" => email, "reason" => reason}, socket) do
    socket =
      case Admin.delete(socket.assigns.subject, email, reason, operator(socket)) do
        {:ok, _} ->
          put_flash(socket, :info, "Deleting: the forum accounts first, then the Idejo ID.")

        {:error, :email} ->
          put_flash(socket, :error, "That is not this Idejo ID's email: nothing was deleted.")

        {:error, :reason} ->
          put_flash(socket, :error, "Say who asked and how: it goes in the audit log.")

        {:error, :deleting} ->
          put_flash(socket, :error, "A deletion of this Idejo ID is already under way.")

        {:error, _} ->
          put_flash(socket, :error, "The identity provider did not answer. Try again.")
      end

    {:noreply, load(socket)}
  end

  defp operator(socket), do: socket.assigns.current_operator.email

  defp deleting?(%{deletion: %{finished_at: nil, error: nil}}), do: true
  defp deleting?(_person), do: false

  defp details(details) do
    details
    |> Map.delete("subject")
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{v}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator}>
      <.link navigate={~p"/identities"} class="text-sm">← Idejo IDs</.link>
      <p :if={@error} id="identity-error" class="text-error">{@error}</p>

      <div :if={@person} class="space-y-6">
        <h1 class="text-2xl font-semibold">
          {if @person[:gone?], do: "Deleted Idejo ID", else: @person.display_name || @person.email}
        </h1>
        <dl :if={!@person[:gone?]} id="identity-facts" class="grid grid-cols-[auto_1fr] gap-x-4">
          <dt>Email</dt>
          <dd>
            {@person.email}
            <span :if={!@person.email_verified} class="badge badge-sm">not verified</span>
          </dd>
          <dt>State</dt>
          <dd>
            <span class={["badge", @person.state == "locked" && "badge-error"]} id="identity-state">
              {@person.state}
            </span>
          </dd>
          <dt>Provider id</dt>
          <dd><code>{@subject}</code></dd>
        </dl>

        <section aria-labelledby="forums-title">
          <h2 id="forums-title" class="text-xl font-semibold">Forums joined</h2>
          <p :if={@person.joins == []}>None.</p>
          <ul class="list-disc pl-6">
            <li :for={j <- @person.joins} id={"join-#{j.forum.subdomain}"}>
              <.link navigate={~p"/forums/#{j.forum}"}>{j.forum.subdomain}</.link> ({j.state})
            </li>
          </ul>
        </section>

        <section :if={!@person[:gone?]} aria-labelledby="lock-title" class="space-y-2">
          <h2 id="lock-title" class="text-xl font-semibold">Lock for abuse</h2>
          <div :if={@person.state != "locked"}>
            <p class="text-sm">
              The identity provider then refuses this person's sign-ins to every forum and to
              their Idejo ID page. Sessions already open on a forum are the forum's own: its
              moderators ban there.
            </p>
            <form id="lock-form" phx-submit="lock" class="flex items-end gap-2">
              <label class="flex flex-col text-sm">
                Reason (kept in the audit log)
                <input type="text" name="reason" class="input input-sm" required maxlength="500" />
              </label>
              <button class="btn btn-sm btn-error">Lock</button>
            </form>
          </div>
          <div :if={@person.state == "locked"}>
            <p>Locked: this Idejo ID cannot sign in.</p>
            <button id="unlock" phx-click="unlock" class="btn btn-sm">Unlock</button>
          </div>
        </section>

        <section aria-labelledby="delete-title" class="space-y-2">
          <h2 id="delete-title" class="text-xl font-semibold">Deletion</h2>
          <p :if={@person.deletion && @person.deletion.finished_at} id="deletion-done">
            Deleted {Calendar.strftime(@person.deletion.finished_at, "%Y-%m-%d %H:%M")} UTC.
          </p>
          <p :if={deleting?(@person)} id="deletion-running">
            Being deleted: the forum accounts first, then the Idejo ID.
          </p>
          <p
            :if={@person.deletion && @person.deletion.error && !@person.deletion.finished_at}
            class="text-error"
          >
            Stopped: {@person.deletion.error}
          </p>
          <div :if={!@person[:gone?] and !deleting?(@person)}>
            <p class="text-sm">
              When this person asks you to delete their Idejo ID (they can also do it
              themselves from their page): their account on every forum they joined is deleted
              as that forum's rules say, then the ID. This cannot be undone.
            </p>
            <form id="delete-form" phx-submit="delete" class="space-y-2">
              <label class="flex flex-col text-sm">
                Type this Idejo ID's email to confirm
                <input type="email" name="email" class="input input-sm" required autocomplete="off" />
              </label>
              <label class="flex flex-col text-sm">
                Who asked, and how (kept in the audit log)
                <input type="text" name="reason" class="input input-sm" required maxlength="500" />
              </label>
              <button class="btn btn-sm btn-error">Delete this Idejo ID</button>
            </form>
          </div>
        </section>

        <section aria-labelledby="log-title">
          <h2 id="log-title" class="text-xl font-semibold">Audit log</h2>
          <p :if={@log == []}>No entries.</p>
          <table :if={@log != []} id="identity-log" class="table table-sm">
            <thead>
              <tr>
                <th>When (UTC)</th><th>Who</th><th>What</th><th>Outcome</th><th>Details</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={e <- @log}>
                <td>{Calendar.strftime(e.inserted_at, "%Y-%m-%d %H:%M")}</td>
                <td>{e.actor}</td>
                <td><code>{e.action}</code></td>
                <td>{e.outcome}</td>
                <td class="text-sm">{details(e.details)}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
