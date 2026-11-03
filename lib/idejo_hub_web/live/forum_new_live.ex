# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ForumNewLive do
  @moduledoc """
  HA-02: the create-forum form (FL-01). While the operator types, the subdomain is checked
  (FL-03 rules, and free among forums not deleted) and its full address shown. Creating
  queues the job and goes back to the forum list, where its progress shows live.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Forums

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "New forum",
       domain: Application.fetch_env!(:idejo_hub, Forums)[:domain]
     )
     |> assign_form(Forums.change_new_forum())}
  end

  @impl true
  def handle_event("validate", %{"forum" => params}, socket) do
    changeset =
      params |> Forums.change_new_forum() |> availability() |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("create", %{"forum" => params}, socket) do
    case Forums.create_forum(params, socket.assigns.current_operator.email) do
      {:ok, forum} ->
        {:noreply,
         socket
         |> put_flash(:info, "Creating #{Forums.host(forum)}. Its progress shows below.")
         |> push_navigate(to: ~p"/")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  # FL-03's rules are in the changeset; this adds "already used", before the database says so.
  defp availability(changeset) do
    subdomain = Ecto.Changeset.get_field(changeset, :subdomain)

    if changeset.errors[:subdomain] == nil and is_binary(subdomain) and
         Forums.get_by_subdomain(subdomain),
       do: Ecto.Changeset.add_error(changeset, :subdomain, "is already used by another forum"),
       else: changeset
  end

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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator}>
      <h1 class="text-2xl font-semibold">New forum</h1>

      <.form for={@form} id="new-forum" phx-change="validate" phx-submit="create">
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
        <.input field={@form[:owner_email]} type="email" label="Owner's email" required />
        <.input field={@form[:idejo_version]} label="Idejo version" required />
        <.input field={@form[:memory_mb]} type="number" label="Memory (MB)" required />
        <.input field={@form[:cpus]} type="number" step="0.1" label="CPUs" required />
        <.input
          field={@form[:mail_from]}
          type="email"
          label="Sender address (optional; default noreply@ its address)"
        />
        <.button phx-disable-with="Creating…">Create forum</.button>
        <.link navigate={~p"/"} class="btn btn-ghost">Cancel</.link>
      </.form>
    </Layouts.app>
    """
  end
end
