# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ForumImportLive do
  @moduledoc """
  FL-07: imports a standalone Idejo backup (`bin/idejo-admin backup`'s
  `idejo-YYYYMMDD-HHMMSS.tar`) as a new forum. The form has the create form's fields (HA-02,
  the subdomain checked while typing) plus the file and, optionally, the standalone
  install's `SECRET_KEY_BASE`. The fields are checked before the file is taken, so a typo
  never costs the upload; then `Forums.import_forum/4` checks the archive, creates the forum
  and restores it, and the page goes to the new forum, where its progress shows.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Forums
  alias IdejoHub.Forums.Import

  @impl true
  def mount(_params, _session, socket) do
    max_bytes = Application.fetch_env!(:idejo_hub, Import)[:max_bytes]

    {:ok,
     socket
     |> assign(
       page_title: "Import a standalone backup",
       domain: Application.fetch_env!(:idejo_hub, Forums)[:domain],
       max_bytes: max_bytes
     )
     |> assign_form(Forums.change_import())
     |> allow_upload(:backup, accept: ~w(.tar), max_entries: 1, max_file_size: max_bytes)}
  end

  @impl true
  def handle_event("validate", %{"forum" => params}, socket) do
    changeset =
      params |> Forums.change_import() |> Forums.check_available() |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :backup, ref)}

  def handle_event("import", %{"forum" => params} = all, socket) do
    key = all["secret_key_base"]
    changeset = params |> Forums.change_import() |> Forums.check_available()

    cond do
      not changeset.valid? ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

      not Forums.valid_import_key?(key) ->
        {:noreply, put_flash(socket, :error, message(:invalid_key))}

      socket.assigns.uploads.backup.entries == [] ->
        {:noreply, put_flash(socket, :error, "Choose the backup file to import.")}

      true ->
        {:noreply, import(socket, params, key)}
    end
  end

  defp import(socket, params, key) do
    actor = socket.assigns.current_operator.email

    [result] =
      consume_uploaded_entries(socket, :backup, fn %{path: path}, _entry ->
        {:ok, Forums.import_forum(path, params, actor, secret_key_base: key)}
      end)

    case result do
      {:ok, forum} ->
        socket
        |> put_flash(:info, "Importing #{Forums.host(forum)}. Its progress shows below.")
        |> push_navigate(to: ~p"/forums/#{forum}")

      {:error, %Ecto.Changeset{} = changeset} ->
        socket
        |> put_flash(:error, "Not imported: choose the file again.")
        |> assign_form(changeset)

      {:error, reason} ->
        put_flash(socket, :error, message(reason))
    end
  end

  defp message(:not_a_backup),
    do:
      "Not imported: that file is not a standalone Idejo backup (an idejo-….tar made by bin/idejo-admin backup)."

  defp message(:invalid_key),
    do:
      "Not imported: the SECRET_KEY_BASE must be the standalone install's whole key (at least 64 characters, no spaces), or left empty."

  defp message(_other), do: "Not imported: the file could not be stored. Try again."

  defp assign_form(socket, changeset) do
    subdomain = Ecto.Changeset.get_field(changeset, :subdomain)

    available? =
      is_binary(subdomain) and changeset.action == :validate and
        changeset.errors[:subdomain] == nil

    assign(socket,
      form: to_form(changeset, as: :forum),
      subdomain: subdomain,
      available?: available?
    )
  end

  defp upload_error(:too_large), do: "The file is larger than the Hub accepts."
  defp upload_error(:not_accepted), do: "Choose an idejo-….tar file."
  defp upload_error(:too_many_files), do: "Choose one file."
  defp upload_error(other), do: "The file could not be sent (#{other})."

  defp size(bytes), do: "#{div(bytes, 1_048_576)} MB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator}>
      <.link navigate={~p"/"} class="text-sm">← Forums</.link>
      <h1 class="text-2xl font-semibold">Import a standalone backup</h1>
      <p>
        Makes a new forum from a standalone Idejo install's backup: on that server, run <code>bin/idejo-admin backup</code>, then choose the
        <code>idejo-….tar</code>
        it wrote. Members, messages, uploads and settings come with it; members keep signing in
        with their passwords (local accounts stay allowed) and can link an Idejo ID from their
        profile.
      </p>

      <.form for={@form} id="import-forum" phx-change="validate" phx-submit="import">
        <fieldset class="fieldset mb-2">
          <label for={@uploads.backup.ref} class="label">
            Backup file (idejo-….tar, at most {size(@max_bytes)})
          </label>
          <.live_file_input upload={@uploads.backup} class="file-input" />
          <div :for={entry <- @uploads.backup.entries} id={"upload-#{entry.ref}"}>
            <span>{entry.client_name}</span>
            <progress value={entry.progress} max="100" class="progress w-40">
              {entry.progress}%
            </progress>
            <button
              type="button"
              phx-click="cancel_upload"
              phx-value-ref={entry.ref}
              class="btn btn-ghost btn-xs"
              aria-label={"Remove #{entry.client_name}"}
            >
              Remove
            </button>
            <p :for={err <- upload_errors(@uploads.backup, entry)} class="text-error">
              {upload_error(err)}
            </p>
          </div>
          <p :for={err <- upload_errors(@uploads.backup)} class="text-error">
            {upload_error(err)}
          </p>
        </fieldset>

        <.input
          field={@form[:subdomain]}
          label="Subdomain"
          phx-debounce="300"
          autocomplete="off"
          required
        />
        <p id="subdomain-check" class="text-sm" aria-live="polite">
          <span :if={@available?} class="text-success">
            Available: https://{@subdomain}.{@domain}
          </span>
        </p>
        <.input field={@form[:display_name]} label="Name" required />
        <.input
          field={@form[:owner_email]}
          type="email"
          label="Owner's email (as on the standalone forum)"
          required
        />
        <.input
          field={@form[:idejo_version]}
          label="Idejo version (the standalone's, or newer)"
          required
        />
        <.input field={@form[:memory_mb]} type="number" label="Memory (MB)" required />
        <.input field={@form[:cpus]} type="number" step="0.1" label="CPUs" required />
        <.input
          field={@form[:mail_from]}
          type="email"
          label="Sender address (optional; default noreply@ its address)"
        />
        <.input
          name="secret_key_base"
          id="secret-key-base"
          type="password"
          value=""
          autocomplete="off"
          label="The standalone install's SECRET_KEY_BASE (optional)"
        />
        <p class="text-sm">
          With it, the forum's push keys and an SMTP password set in its Admin → Email keep
          working; the key then belongs to this forum only, so stop the standalone install.
          Without it, the forum gets its own key and new push keys (browsers subscribe again
          on their next visit), and an SMTP password set there must be entered again.
        </p>
        <.button phx-disable-with="Importing…">Import</.button>
        <.link navigate={~p"/"} class="btn btn-ghost">Cancel</.link>
      </.form>
    </Layouts.app>
    """
  end
end
