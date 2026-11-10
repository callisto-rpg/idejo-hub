# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SettingsLive do
  @moduledoc """
  HA-05: settings. Forum domain and backup storage are shown (environment, exports volume,
  OP-02's off-server storage without its keys);
  SMTP shared by forums, alert email and extra reserved subdomains are changed here
  (`IdejoHub.Settings`). The SMTP password is never sent back to the page: left empty it
  stays, "Remove the password" clears it.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Operations.Offsite
  alias IdejoHub.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Settings", errors: %{}, inbox: IdejoHub.Forums.inbox())
     |> load()}
  end

  @impl true
  # HA-05: the new settings reach running and suspended forums only when their containers
  # are made again (Forums.recreate_all/1).
  def handle_event("apply_all", _params, socket) do
    %{queued: queued, busy: busy} =
      IdejoHub.Forums.recreate_all(socket.assigns.current_operator.email)

    message =
      case {queued, busy} do
        {[], []} ->
          "No forum to apply them to."

        {queued, []} ->
          "Recreating #{Enum.join(queued, ", ")} with the current settings."

        {queued, busy} ->
          "Recreating #{Enum.join(queued, ", ")}. Busy, try again later: #{Enum.join(busy, ", ")}."
      end

    {:noreply, put_flash(socket, :info, message)}
  end

  # The members' inbox (steward request 2026-11-10): Idejo in inbox mode at my.<forum
  # domain>, owned by the operator who sets it up.
  def handle_event("create_inbox", _params, socket) do
    email = socket.assigns.current_operator.email

    case IdejoHub.Forums.create_inbox(email, email) do
      {:ok, inbox} ->
        {:noreply,
         socket
         |> assign(inbox: inbox)
         |> put_flash(
           :info,
           "Setting up the members' inbox. Once it runs, apply to all forums so they lead there."
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "The members' inbox could not be set up.")}
    end
  end

  def handle_event("save", %{"settings" => params}, socket) do
    case Settings.update(params, socket.assigns.current_operator.email) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Settings saved.") |> assign(errors: %{}) |> load()}

      {:error, errors} ->
        {:noreply, socket |> put_flash(:error, "Not saved: see below.") |> assign(errors: errors)}
    end
  end

  defp load(socket) do
    values = Settings.all()

    assign(socket,
      values: values,
      password_set?: values["smtp_password"] != nil,
      env_smtp: Application.get_env(:idejo_hub, IdejoHub.Forums.Mail, [])[:shared_smtp],
      domain: Application.fetch_env!(:idejo_hub, IdejoHub.Forums)[:domain],
      exports: Application.fetch_env!(:idejo_hub, IdejoHub.Forums.Export)[:dir],
      offsite: Offsite.summary()
    )
  end

  defp field(assigns) do
    ~H"""
    <label class="block">
      <span class="block text-sm font-medium">{@label}</span>
      <input
        type={@type}
        name={"settings[#{@key}]"}
        id={"setting-#{@key}"}
        value={@value}
        class="input input-sm w-full"
        autocomplete="off"
      />
      <span :if={@errors[@key]} class="text-sm text-error">{@errors[@key]}</span>
    </label>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator}>
      <h1 class="text-2xl font-semibold">Settings</h1>

      <section id="fixed">
        <h2 class="text-xl font-semibold">Set at install</h2>
        <p>
          Forum domain: <strong id="forum-domain">{@domain}</strong>
          (forums are <em>name</em>.{@domain}).
          It is set by <code>IDEJO_FORUM_DOMAIN</code>: every forum's address depends on it.
        </p>
        <p>Backup storage: <strong id="backup-storage">this server, {@exports}</strong>.</p>
        <p :if={!@offsite} id="offsite-storage">
          Off-server copies (OP-02): <strong>off</strong>. Set <code>IDEJO_HUB_S3_*</code>
          and <code>IDEJO_HUB_BACKUP_AGE_RECIPIENT</code>
          in <code>deploy/.env</code>
          to turn them on.
        </p>
        <p :if={@offsite} id="offsite-storage">
          Off-server copies (OP-02): every backup, encrypted with age to <code class="break-all">{@offsite.recipient}</code>, to
          <strong>{@offsite.endpoint}/{@offsite.bucket}/{@offsite.prefix}</strong>
          (set in <code>deploy/.env</code>).
        </p>
      </section>

      <form id="settings" phx-submit="save" class="space-y-4">
        <section id="smtp" class="space-y-2">
          <h2 class="text-xl font-semibold">Email for forums</h2>
          <p class="text-sm">
            A server here replaces <code>HUB_SMTP_*</code>
            (now: {if @env_smtp, do: @env_smtp[:host], else: "none"}).
            It reaches a forum when its container is made: created, upgraded, restored or
            recreated ("Apply to all forums now", below the form).
            Each forum's owner can still set its own in the forum's Admin → Email.
          </p>
          <.field
            key="smtp_host"
            label="SMTP host"
            type="text"
            value={@values["smtp_host"]}
            errors={@errors}
          />
          <.field
            key="smtp_port"
            label="Port"
            type="text"
            value={@values["smtp_port"]}
            errors={@errors}
          />
          <.field
            key="smtp_security"
            label="Security (starttls, tls or none)"
            type="text"
            value={@values["smtp_security"]}
            errors={@errors}
          />
          <.field
            key="smtp_username"
            label="Username"
            type="text"
            value={@values["smtp_username"]}
            errors={@errors}
          />
          <.field
            key="smtp_password"
            label={if @password_set?, do: "Password (set; leave empty to keep)", else: "Password"}
            type="password"
            value=""
            errors={@errors}
          />
          <label :if={@password_set?} class="text-sm">
            <input type="checkbox" name="settings[clear_smtp_password]" value="true" />
            Remove the password
          </label>
          <.field
            key="smtp_from"
            label={"Sender address (empty: #{IdejoHub.Settings.sender()})"}
            type="email"
            value={@values["smtp_from"]}
            errors={@errors}
          />
          <p class="text-sm">
            The Hub's alerts and Idejo ID's emails send from it, and new forums get it as theirs:
            they send exactly as the Hub does, under their own name.
          </p>
        </section>

        <section id="alerts" class="space-y-2">
          <h2 class="text-xl font-semibold">Alerts</h2>
          <.field
            key="alert_email"
            label="Alert email (forum down, failed backup, disk full)"
            type="email"
            value={@values["alert_email"]}
            errors={@errors}
          />
        </section>

        <section id="reserved" class="space-y-2">
          <h2 class="text-xl font-semibold">Reserved subdomains</h2>
          <p class="text-sm">
            Refused for new forums, on top of the built-in list (hub, www, admin, mail, api, status…).
          </p>
          <label class="block">
            <span class="block text-sm font-medium">One per line or separated by commas</span>
            <textarea
              name="settings[reserved_subdomains]"
              id="setting-reserved_subdomains"
              class="textarea w-full"
              rows="4"
            >{Enum.join(@values["reserved_subdomains"] || [], "\n")}</textarea>
            <span :if={@errors["reserved_subdomains"]} class="text-sm text-error">{@errors[
              "reserved_subdomains"
            ]}</span>
          </label>
        </section>

        <%!-- SC-10: the "when" of the forum owners' disclosure page, in the operator's words. --%>
        <section id="access-policy" class="space-y-2">
          <h2 class="text-xl font-semibold">When you would access a forum</h2>
          <p class="text-sm">
            Shown to forum owners on <a href={IdejoHub.Identity.issuer() <> "/account/operator-access"}>what the Hub operator can access</a>,
            under what the Hub lets you do. Say when you would look at a forum's data or act on
            it (abuse reports, legal requests, recovery…), and how owners can reach you. Plain
            text; a blank line starts a new paragraph.
          </p>
          <label class="block">
            <span class="block text-sm font-medium">Your policy (at most 4000 characters)</span>
            <textarea
              name="settings[access_policy]"
              id="setting-access_policy"
              class="textarea w-full"
              rows="8"
            >{@values["access_policy"]}</textarea>
            <span :if={@errors["access_policy"]} class="text-sm text-error">{@errors["access_policy"]}</span>
          </label>
        </section>

        <%!-- Hub NF-07: members' privacy notice, as a standalone Idejo's (AD-02). --%>
        <section id="privacy" class="space-y-2">
          <h2 class="text-xl font-semibold">Privacy notice for members</h2>
          <p class="text-sm">
            Shown to members at <a href={IdejoHub.Identity.issuer() <> "/account/privacy"}>the sign-in address's privacy page</a>,
            linked from every member page: who runs this Hub, what Idejo IDs keep (email,
            names, the forums signed in to) and why, how long, and how to reach you. Plain
            text; a blank line starts a new paragraph.
          </p>
          <label class="block">
            <span class="block text-sm font-medium">Privacy notice (at most 50 000 characters)</span>
            <textarea
              name="settings[privacy_notice]"
              id="setting-privacy_notice"
              class="textarea w-full"
              rows="10"
            >{@values["privacy_notice"]}</textarea>
            <span :if={@errors["privacy_notice"]} class="text-sm text-error">{@errors[
              "privacy_notice"
            ]}</span>
          </label>
        </section>

        <button class="btn btn-primary">Save</button>
      </form>

      <section id="inbox" class="space-y-2">
        <h2 class="text-xl font-semibold">Members' inbox</h2>
        <p class="text-sm">
          Idejo in inbox mode at <code>{IdejoHub.Community.my_host()}</code>: each member's forums,
          the topics they follow and their private conversations (Idejo 0.3.5 or later).
          Forums lead there once their containers are made again.
        </p>
        <p :if={@inbox} id="inbox-status">
          <.link navigate={~p"/forums/#{@inbox.id}"}>The inbox</.link>: {@inbox.status}
        </p>
        <button
          :if={!@inbox}
          id="create-inbox"
          phx-click="create_inbox"
          class="btn btn-sm btn-primary"
          data-confirm="Set up the members' inbox, owned by you?"
        >
          Set up the members' inbox
        </button>
      </section>

      <section id="apply-all" class="space-y-2">
        <p class="text-sm">
          Changed the email settings? Running forums keep the old ones until their containers are
          made again.
        </p>
        <button
          phx-click="apply_all"
          class="btn btn-sm"
          data-confirm="Recreate every running and suspended forum with the current settings? Each running forum is briefly unavailable."
        >
          Apply to all forums now
        </button>
      </section>
    </Layouts.app>
    """
  end
end
