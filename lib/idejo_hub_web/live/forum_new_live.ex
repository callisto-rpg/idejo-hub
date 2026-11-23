# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ForumNewLive do
  @moduledoc """
  HA-02: the create-forum form (FL-01). While the operator types, the subdomain is checked
  (FL-03 rules, and free among forums not deleted) and its full address shown. Creating
  queues the job and goes back to the forum list, where its progress shows live.

  The owner (FL-02) is an email, invited to choose a password, or, with an identity
  provider, an existing idejo ID (steward request 2026-11-23): searched by email, name or
  username, and only one that is active with a verified email can be picked. The Hub then
  takes the ID's email from the provider (`Forums.create_forum/3`).
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.{Forums, Identity}
  alias IdejoHub.Forums.Forum

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "New forum",
       domain: Application.fetch_env!(:idejo_hub, Forums)[:domain],
       hosted: Forums.hosted_count(),
       identity?: Identity.enabled?(),
       owner_kind: "email",
       owner_search: "",
       owner_results: nil,
       owner_error: nil,
       owner: nil,
       owner_since: Forum.owner_subject_since()
     )
     |> assign_form(Forums.change_new_forum())}
  end

  @impl true
  def handle_event("validate", %{"forum" => params} = all, socket) do
    socket =
      socket
      |> assign(owner_kind: owner_kind(all, socket))
      |> search_owner(String.trim(all["owner_search"] || ""))

    changeset =
      params
      |> owner_params(socket.assigns)
      |> Forums.change_new_forum()
      |> Forums.check_available()
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("pick_owner", %{"subject" => subject}, socket) do
    case Enum.find(socket.assigns.owner_results || [], &(&1.id == subject and owner?(&1))) do
      nil -> {:noreply, socket}
      person -> {:noreply, assign(socket, owner: person)}
    end
  end

  def handle_event("unpick_owner", _params, socket),
    do: {:noreply, assign(socket, owner: nil)}

  def handle_event("create", %{"forum" => params}, %{assigns: assigns} = socket) do
    params = owner_params(params, assigns)

    result =
      if assigns.owner_kind == "idejo_id" and assigns.owner == nil do
        {:error,
         params
         |> Forums.change_new_forum()
         |> Ecto.Changeset.add_error(:owner_subject, "pick the idejo ID that owns the forum")
         |> Map.put(:action, :insert)}
      else
        Forums.create_forum(params, assigns.current_operator.email)
      end

    case result do
      {:ok, forum} ->
        {:noreply,
         socket
         |> put_flash(:info, "Creating #{Forums.host(forum)}. Its progress shows below.")
         |> push_navigate(to: ~p"/")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp owner_kind(%{"owner_kind" => "idejo_id"}, %{assigns: %{identity?: true}}),
    do: "idejo_id"

  defp owner_kind(_params, _socket), do: "email"

  # An idejo ID owner: its subject, and its email for the form's own checks (the Hub reads
  # it again from the provider when creating). Without one picked, nothing is owner.
  defp owner_params(params, %{owner_kind: "idejo_id", owner: %{} = person}),
    do: Map.merge(params, %{"owner_subject" => person.id, "owner_email" => person.email})

  defp owner_params(params, %{owner_kind: "idejo_id"}),
    do: Map.merge(params, %{"owner_subject" => nil, "owner_email" => nil})

  defp owner_params(params, _assigns), do: Map.delete(params, "owner_subject")

  defp search_owner(%{assigns: %{owner_search: q}} = socket, q), do: socket
  defp search_owner(socket, ""), do: assign(socket, owner_search: "", owner_results: nil)

  defp search_owner(socket, q) do
    case Identity.search_people(q) do
      {:ok, people} -> assign(socket, owner_search: q, owner_results: people, owner_error: nil)
      {:error, _} -> assign(socket, owner_search: q, owner_results: [], owner_error: :provider)
    end
  end

  # Who can own a forum: an active idejo ID whose email is verified.
  defp owner?(person), do: person.state == "active" and person.email_verified == true

  defp not_owner_reason(%{state: state}) when state != "active", do: state
  defp not_owner_reason(_person), do: "email not verified"

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
      <.forum_limit_notice id="forum-limit" hosted={@hosted} />

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
        <fieldset :if={@identity?} id="owner-kind" class="fieldset">
          <legend class="fieldset-legend">Owner</legend>
          <label class="label">
            <input
              type="radio"
              name="owner_kind"
              value="email"
              class="radio radio-sm"
              checked={@owner_kind == "email"}
            /> An email address, invited to choose a password
          </label>
          <label class="label">
            <input
              type="radio"
              name="owner_kind"
              value="idejo_id"
              class="radio radio-sm"
              checked={@owner_kind == "idejo_id"}
            /> An existing idejo ID, who signs in with it (idejo {@owner_since} or later)
          </label>
        </fieldset>
        <.input
          :if={@owner_kind == "email"}
          field={@form[:owner_email]}
          type="email"
          label="Owner's email"
          required
        />
        <div :if={@owner_kind == "idejo_id"} id="owner-idejo-id" class="space-y-2">
          <div :if={@owner} id="owner-picked" class="flex items-center gap-2">
            <span>
              Owner: <strong>{@owner.display_name || @owner.email}</strong>
              <span class="opacity-70">{@owner.email}</span>
            </span>
            <button type="button" phx-click="unpick_owner" class="btn btn-ghost btn-sm">
              Change
            </button>
          </div>
          <div :if={!@owner}>
            <label for="owner-search" class="label">
              Find the idejo ID (email, name or username)
            </label>
            <input
              id="owner-search"
              name="owner_search"
              value={@owner_search}
              phx-debounce="300"
              autocomplete="off"
              class="input w-full"
            />
            <p :if={@owner_error} id="owner-search-error" class="text-error text-sm">
              The identity provider did not answer. Try again in a minute.
            </p>
            <p :if={@owner_results == []} id="owner-search-none" class="text-sm">
              No idejo ID matches.
            </p>
            <ul :if={@owner_results not in [nil, []]} id="owner-results" class="space-y-1">
              <li :for={person <- @owner_results} id={"owner-result-" <> person.id}>
                <button
                  :if={owner?(person)}
                  type="button"
                  phx-click="pick_owner"
                  phx-value-subject={person.id}
                  class="btn btn-ghost btn-sm"
                >
                  {person.display_name || person.email}
                  <span class="opacity-70">{person.email}</span>
                </button>
                <span :if={!owner?(person)} class="opacity-60 text-sm">
                  {person.display_name || person.email} ({not_owner_reason(person)})
                </span>
              </li>
            </ul>
          </div>
          <p :for={error <- @form[:owner_subject].errors} class="mt-1.5 text-sm text-error">
            Owner: {translate_error(error)}
          </p>
        </div>
        <.input field={@form[:idejo_version]} label="idejo version" required />
        <.input field={@form[:memory_mb]} type="number" label="Memory (MB)" required />
        <.input field={@form[:cpus]} type="number" step="0.1" label="CPUs" required />
        <.input
          field={@form[:mail_from]}
          type="email"
          label="Sender address (optional; default the Hub's, as set in Settings)"
        />
        <.input
          field={@form[:local_accounts]}
          type="checkbox"
          label="Also allow local accounts (people without an idejo ID)"
        />
        <.button phx-disable-with="Creating…">Create forum</.button>
        <.link navigate={~p"/"} class="btn btn-ghost">Cancel</.link>
      </.form>
    </Layouts.app>
    """
  end
end
