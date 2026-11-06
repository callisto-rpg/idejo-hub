# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ForumShowLive do
  @moduledoc """
  HA-03: one forum. Its health (asked live, `Hosting.Health`), its kept archives (back up
  now, export, restore here or to a new subdomain, download), upgrade, suspend and resume,
  delete (with the grace period, or immediately after typing the subdomain) and cancel, the
  owner's link when the Hub holds it (FL-02), and its audit log.

  Every action goes through `IdejoHub.Forums` as the signed-in operator, so it is checked
  (one action at a time) and audited there (SC-06). The page follows the forum live.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.{Audit, Forums, Repo}
  alias IdejoHub.Forums.Export
  alias IdejoHub.Hosting.Health

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    forum = Forums.get_forum!(id)
    if connected?(socket), do: Forums.subscribe()

    {:ok,
     socket
     |> assign(page_title: forum.subdomain, owner_link: nil, health: nil, secret_key_base: nil)
     |> load(forum)
     |> check_health()}
  end

  @impl true
  def handle_info({:forum_changed, %{id: id} = forum}, %{assigns: %{forum: %{id: id}}} = socket),
    do: {:noreply, socket |> load(forum) |> check_health()}

  def handle_info({:forum_changed, _other}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:health, {:ok, result}, socket), do: {:noreply, assign(socket, health: result)}

  def handle_async(:health, {:exit, _reason}, socket),
    do: {:noreply, assign(socket, health: {:error, :unreachable})}

  @impl true
  def handle_event(action, params, socket) do
    forum = Forums.get_forum!(socket.assigns.forum.id)
    actor = socket.assigns.current_operator.email
    {:noreply, run(action, params, forum, actor, socket)}
  end

  defp run("suspend", _p, forum, actor, socket),
    do: done(socket, Forums.suspend_forum(forum, actor), "Suspending.")

  defp run("resume", _p, forum, actor, socket),
    do: done(socket, Forums.resume_forum(forum, actor), "Resuming.")

  defp run("backup", _p, forum, actor, socket),
    do: done(socket, Forums.backup_forum(forum, actor), "Backing up.")

  defp run("export", _p, forum, actor, socket),
    do: done(socket, Forums.export_forum(forum, actor), "Exporting.")

  defp run("upgrade", %{"version" => version}, forum, actor, socket),
    do:
      done(
        socket,
        Forums.upgrade_forum(forum, String.trim(version), actor),
        "Upgrading to #{version}."
      )

  defp run("restore", %{"archive" => id}, forum, actor, socket) do
    case archive(forum, id) do
      nil -> put_flash(socket, :error, message(:not_its_archive))
      export -> done(socket, Forums.restore_forum(forum, export, actor), "Restoring.")
    end
  end

  defp run("restore_new", %{"archive" => id, "subdomain" => subdomain}, forum, actor, socket) do
    with %Export{} = export <- archive(forum, id),
         {:ok, new} <-
           Forums.restore_to_new(export, %{"subdomain" => String.trim(subdomain)}, actor) do
      socket
      |> put_flash(:info, "Creating #{new.subdomain} from this archive.")
      |> push_navigate(to: ~p"/forums/#{new}")
    else
      nil ->
        put_flash(socket, :error, message(:not_its_archive))

      {:error, %Ecto.Changeset{} = changeset} ->
        put_flash(socket, :error, "Not restored: " <> errors(changeset))

      {:error, reason} ->
        put_flash(socket, :error, message(reason))
    end
  end

  defp run("delete", %{"immediate" => "true", "confirm" => confirm}, forum, actor, socket),
    do:
      done(
        socket,
        Forums.delete_forum(forum, actor, immediate: true, confirm: String.trim(confirm)),
        "Deleting now."
      )

  defp run("delete", _p, forum, actor, socket),
    do:
      done(
        socket,
        Forums.delete_forum(forum, actor),
        "Deleting: final export, then purge in 30 days."
      )

  defp run("cancel_deletion", _p, forum, actor, socket),
    do:
      done(
        socket,
        Forums.cancel_deletion(forum, actor),
        "Deletion cancelled; the forum is suspended."
      )

  defp run("rotate_identity", _p, forum, actor, socket),
    do: done(socket, Forums.rotate_identity(forum, actor), "Rotating the sign-in secret.")

  defp run("local_accounts", %{"allowed" => allowed}, forum, actor, socket),
    do:
      done(
        socket,
        Forums.set_local_accounts(forum, allowed == "true", actor),
        if(allowed == "true", do: "Allowing local accounts.", else: "Idejo ID accounts only.")
      )

  defp run("recreate", _p, forum, actor, socket),
    do: done(socket, Forums.recreate_forum(forum, actor), "Recreating with the current settings.")

  defp run("secret_key_base", _p, forum, actor, socket) do
    case Forums.reveal_secret_key_base(forum, actor) do
      {:ok, key} -> socket |> assign(secret_key_base: key) |> load(Forums.get_forum!(forum.id))
      {:error, _} -> put_flash(socket, :error, "The forum's key could not be read.")
    end
  end

  defp run("owner_link", _p, forum, actor, socket) do
    case Forums.take_owner_link(forum, actor) do
      {:ok, link} -> socket |> assign(owner_link: link) |> load(Forums.get_forum!(forum.id))
      {:error, :none} -> put_flash(socket, :error, "The Hub holds no link for this owner.")
    end
  end

  defp run("check_health", _p, _forum, _actor, socket),
    do: socket |> assign(health: nil) |> check_health()

  # Only this forum's archives (nil for any other id).
  defp archive(forum, id), do: Repo.get_by(Export, id: id, forum_id: forum.id)

  defp done(socket, {:ok, forum}, info), do: socket |> put_flash(:info, info) |> load(forum)
  defp done(socket, {:error, reason}, _info), do: put_flash(socket, :error, message(reason))

  defp message(:invalid_state), do: "Not now: the forum is busy, or not in a state for this."
  defp message(:confirmation_required), do: "Type the forum's subdomain exactly to delete it now."
  defp message(:not_newer), do: "Choose a version newer than the current one."
  defp message(:invalid_version), do: "Give an exact version, for example 0.2.2."
  defp message(:not_its_archive), do: "That archive belongs to another forum."
  defp message(other), do: "Not done: #{inspect(other)}"

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp load(socket, forum) do
    assign(socket,
      forum: forum,
      archives: Forums.list_exports(forum),
      hosted: Forums.hosted_count(),
      entries: forum.id |> Audit.for_forum() |> Enum.reverse()
    )
  end

  defp check_health(%{assigns: %{forum: %{status: "running", subdomain: subdomain}}} = socket) do
    if connected?(socket),
      do: start_async(socket, :health, fn -> Health.check(subdomain) end),
      else: socket
  end

  defp check_health(socket), do: assign(socket, health: :not_running)

  defp size(bytes) when bytes < 1_048_576, do: "#{max(div(bytes, 1024), 1)} KB"
  defp size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator} wide>
      <.link navigate={~p"/"} class="text-sm">← Forums</.link>
      <h1 class="text-2xl font-semibold">{@forum.display_name}</h1>
      <p>
        <a href={"https://" <> Forums.host(@forum)} rel="noopener">{Forums.host(@forum)}</a>
        · owner {@forum.owner_email} · Idejo {@forum.idejo_version}
      </p>

      <section id="state" aria-labelledby="state-title">
        <h2 id="state-title" class="text-xl font-semibold">State</h2>
        <p>
          <span class="badge" id="status">{@forum.status}</span>
          <span :if={@forum.step} id="step">({@forum.step} …)</span>
          <span :if={@forum.purge_at}>purge on {Calendar.strftime(@forum.purge_at, "%Y-%m-%d")}</span>
        </p>
        <p :if={@forum.error} id="error" class="text-error">Last error: {@forum.error}</p>
        <p id="health">
          Health: <span :if={@health == nil}>checking…</span>
          <span :if={@health == :ok} class="text-success">healthy (/health 200)</span>
          <span :if={@health == :not_running}>not running</span>
          <span :if={match?({:error, _}, @health)} class="text-error">
            not healthy ({inspect(elem(@health, 1))})
          </span>
          <button
            :if={@forum.status == "running"}
            phx-click="check_health"
            class="btn btn-ghost btn-xs"
          >
            Check again
          </button>
        </p>
      </section>

      <section id="actions" aria-labelledby="actions-title" class="space-y-2">
        <h2 id="actions-title" class="text-xl font-semibold">Actions</h2>
        <div class="flex flex-wrap gap-2">
          <button
            :if={@forum.status == "running"}
            id="suspend"
            phx-click="suspend"
            class="btn btn-sm"
            data-confirm="Suspend this forum? Visitors see the maintenance page."
          >Suspend</button>
          <button :if={@forum.status == "suspended"} id="resume" phx-click="resume" class="btn btn-sm">Resume</button>
          <button :if={@forum.status == "running"} id="backup" phx-click="backup" class="btn btn-sm">Back up now</button>
          <button
            :if={@forum.status in ["running", "suspended"]}
            id="export"
            phx-click="export"
            class="btn btn-sm"
          >Export</button>
          <button
            :if={@forum.status in ["running", "suspended"]}
            id="recreate"
            phx-click="recreate"
            class="btn btn-sm"
            data-confirm="Remake this forum's container with the current settings (same version, data kept)? A running forum is briefly unavailable."
          >
            Recreate (apply settings)
          </button>
          <button
            :if={@forum.status == "deleting"}
            id="cancel-deletion"
            phx-click="cancel_deletion"
            class="btn btn-sm"
          >
            Cancel deletion
          </button>
        </div>

        <form
          :if={@forum.status == "running"}
          id="upgrade"
          phx-submit="upgrade"
          class="flex gap-2 items-end"
        >
          <label>Upgrade to version
          <input name="version" class="input input-sm" required placeholder="0.2.2" /></label>
          <button
            class="btn btn-sm"
            data-confirm="Upgrade? It is backed up first and rolled back if unhealthy."
          >Upgrade</button>
        </form>

        <div
          :if={@forum.owner_invite == "operator" and (@forum.owner_link_enc || @owner_link)}
          id="owner-link"
        >
          <p>The forum could not email its owner the link to choose a password; the Hub holds it.</p>
          <button
            :if={!@owner_link}
            phx-click="owner_link"
            class="btn btn-sm"
            data-confirm="The link is shown once and removed from the Hub. Send it to the owner."
          >
            Show the owner's link once
          </button>
          <p :if={@owner_link}><code id="owner-link-value">{@owner_link}</code></p>
        </div>

        <div :if={@forum.status in ["running", "suspended", "failed"]} id="delete" class="space-y-2">
          <button
            phx-click="delete"
            class="btn btn-sm btn-error"
            data-confirm="Delete this forum? A final export is made, then it is purged in 30 days."
          >
            Delete (30-day grace)
          </button>
          <form phx-submit="delete" class="flex gap-2 items-end">
            <input type="hidden" name="immediate" value="true" />
            <label>
              Type <strong>{@forum.subdomain}</strong>
              to delete now
              <input name="confirm" class="input input-sm" autocomplete="off" required />
            </label>
            <button class="btn btn-sm btn-error">Delete now</button>
          </form>
        </div>
      </section>

      <section id="identity" aria-labelledby="identity-title" class="space-y-2">
        <h2 id="identity-title" class="text-xl font-semibold">Sign-in</h2>
        <p :if={@forum.oidc_client_id} id="identity-client">
          Members sign in with Idejo ID (client <code>{@forum.oidc_client_id}</code>).
        </p>
        <p :if={!@forum.oidc_client_id} id="identity-none">
          Not connected to Idejo ID yet: "Recreate (apply settings)" connects it.
        </p>
        <p id="local-accounts">
          Local accounts (without an Idejo ID):
          <strong>{if @forum.local_accounts, do: "allowed", else: "not allowed"}</strong>
          <button
            :if={@forum.status in ["running", "suspended"]}
            phx-click="local_accounts"
            phx-value-allowed={to_string(!@forum.local_accounts)}
            class="btn btn-ghost btn-xs"
            data-confirm="Change this and make the forum's container again (briefly unavailable)?"
          >
            {if @forum.local_accounts, do: "Allow Idejo ID only", else: "Allow local accounts"}
          </button>
        </p>
        <button
          :if={@forum.oidc_client_id && @forum.status in ["running", "suspended"]}
          id="rotate-identity"
          phx-click="rotate_identity"
          class="btn btn-sm"
          data-confirm="Give the forum a new sign-in secret? The old one stops working at once; the forum is briefly unavailable."
        >
          Rotate the sign-in secret
        </button>
      </section>

      <section id="archives" aria-labelledby="archives-title" class="space-y-2">
        <h2 id="archives-title" class="text-xl font-semibold">Backups and exports</h2>
        <p :if={@archives == []}>None yet.</p>
        <table :if={@archives != []} class="table">
          <thead>
            <tr>
              <th>When (UTC)</th><th>Kind</th><th>Size</th><th>SHA-256</th><th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={a <- @archives} id={"archive-#{a.id}"}>
              <td>{Calendar.strftime(a.inserted_at, "%Y-%m-%d %H:%M")}</td>
              <td>{a.kind}</td>
              <td>{size(a.size)}</td>
              <td><code title={a.sha256}>{String.slice(a.sha256, 0, 12)}…</code></td>
              <td class="flex gap-2">
                <a href={~p"/forums/#{@forum}/archives/#{a}"} class="btn btn-ghost btn-xs">Download</a>
                <button
                  :if={@forum.status in ["running", "suspended"]}
                  phx-click="restore"
                  phx-value-archive={a.id}
                  class="btn btn-ghost btn-xs"
                  data-confirm="Restore this archive? The forum's current data is replaced."
                >
                  Restore here
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <.forum_limit_notice :if={@archives != []} id="forum-limit" hosted={@hosted} />
        <form
          :if={@archives != []}
          id="restore-new"
          phx-submit="restore_new"
          class="flex flex-wrap gap-2 items-end"
        >
          <label>
            Restore
            <select name="archive" class="select select-sm">
              <option :for={a <- @archives} value={a.id}>
                {a.kind} {Calendar.strftime(a.inserted_at, "%Y-%m-%d %H:%M")}
              </option>
            </select>
          </label>
          <label>to a new subdomain <input name="subdomain" class="input input-sm" required /></label>
          <button class="btn btn-sm">Restore to new</button>
        </form>

        <div :if={@archives != []} id="standalone-key" class="space-y-1">
          <p class="text-sm">
            Restoring an export on a standalone Idejo? Give that install this forum's <code>SECRET_KEY_BASE</code>, or its push keys and any SMTP password set in the
            forum can't be read (see the deployment guide).
          </p>
          <button
            :if={!@secret_key_base}
            phx-click="secret_key_base"
            class="btn btn-sm"
            data-confirm="Show this forum's SECRET_KEY_BASE? It is a secret: the reveal is recorded in the audit log."
          >
            Show the key for a standalone restore
          </button>
          <p :if={@secret_key_base}>
            <code id="secret-key-base-value" class="break-all">{@secret_key_base}</code>
          </p>
        </div>
      </section>

      <section id="audit" aria-labelledby="audit-title">
        <h2 id="audit-title" class="text-xl font-semibold">Audit log</h2>
        <.link navigate={~p"/audit?forum=#{@forum.subdomain}"} id="audit-filtered" class="text-sm">
          Search it in the Hub's audit log
        </.link>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>When (UTC)</th><th>Who</th><th>What</th><th>Outcome</th><th>Details</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={e <- @entries}>
              <td>{Calendar.strftime(e.inserted_at, "%Y-%m-%d %H:%M:%S")}</td>
              <td>{e.actor}</td>
              <td>{e.action}</td>
              <td>{e.outcome}</td>
              <td><code :if={e.details != %{}}>{inspect(e.details)}</code></td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end
end
