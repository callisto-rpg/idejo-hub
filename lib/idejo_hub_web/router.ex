# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.Router do
  use IdejoHubWeb, :router

  # The policy is set by IdejoHubWeb.Plugs.ContentSecurityPolicy below, with per-request
  # nonces, so Sobelow cannot see it.
  # sobelow_skip ["Config.CSP"]
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug IdejoHubWeb.OperatorAuth, :fetch_operator
    plug :put_root_layout, html: {IdejoHubWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug IdejoHubWeb.Plugs.ContentSecurityPolicy
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # SC-08: every operator page needs a signed-in operator (password and two-factor code).
  pipeline :operator do
    plug IdejoHubWeb.OperatorAuth, :require_operator
  end

  # The forums directory (steward decision 2026-11-06), only on forums.<forum domain>.
  pipeline :directory_host do
    plug IdejoHubWeb.Plugs.DirectoryHost
  end

  scope "/", IdejoHubWeb, host: "forums." do
    pipe_through [:directory_host, :browser]
    get "/", DirectoryController, :index
    # Who is looking, from the sign-in host (steward request 2026-11-06).
    get "/sign-in", DirectoryController, :sign_in
    get "/signed-in", DirectoryController, :signed_in
    post "/sign-out", DirectoryController, :sign_out
  end

  # The directory's search for Idejo's !forum plugin (steward request 2026-11-09): JSON, public.
  scope "/api", IdejoHubWeb, host: "forums." do
    pipe_through [:directory_host, :api]
    get "/forums", DirectoryController, :search
  end

  # ID-02: members' pages, only on the identity provider's host (id.<hub domain>).
  pipeline :identity_host do
    plug IdejoHubWeb.Plugs.IdentityHost
  end

  # Idejo servers not hosted here (steward decisions 2026-11-06): JSON, no session, so no
  # CSRF token; a registration key or client credentials are the authority.
  scope "/account/api", IdejoHubWeb do
    pipe_through [:identity_host, :api]

    post "/registrations", RegistryController, :create
    post "/registrations/verify", RegistryController, :verify
    get "/listing", RegistryController, :show_listing
    put "/listing", RegistryController, :update_listing
    get "/profile", CommunityController, :profile
    post "/profile", CommunityController, :fill_profile
  end

  # An Idejo ID's picture, public (steward decisions 2026-11-06).
  scope "/account/pictures", IdejoHubWeb do
    pipe_through [:identity_host]

    get "/:key", PictureController, :show
  end

  scope "/account", IdejoHubWeb do
    pipe_through [:identity_host, :browser]

    get "/sign-up", SignupController, :new
    post "/sign-up", SignupController, :create

    # ID-05, ID-06: the member's own page (signed in through the provider).
    get "/", AccountController, :show
    get "/sign-in", AccountController, :sign_in
    get "/callback", AccountController, :callback
    post "/sign-out", AccountController, :sign_out
    post "/forums/:forum_id", AccountController, :leave
    # SC-07: the audit log of a forum the member owns.
    get "/forums/:subdomain/log", AccountController, :log
    # SC-10: what the Hub operator can access, and when they would (public).
    get "/operator-access", AccountController, :operator_access
    # Hub NF-07: the privacy notice for members (public).
    get "/privacy", AccountController, :privacy
    post "/delete", AccountController, :delete
    post "/profile", AccountController, :update_profile
    get "/directory", AccountController, :directory
    post "/profile/picture", AccountController, :remove_picture
  end

  # SC-08: sign-in, two-factor setup and code, sign-out.
  scope "/", IdejoHubWeb do
    pipe_through :browser

    get "/sign-in", SessionController, :new
    post "/sign-in", SessionController, :create
    get "/sign-in/two-factor", SessionController, :two_factor
    post "/sign-in/two-factor", SessionController, :verify
    delete "/sign-out", SessionController, :delete
  end

  scope "/", IdejoHubWeb do
    pipe_through [:browser, :operator]

    live_session :operator, on_mount: {IdejoHubWeb.OperatorAuth, :require_operator} do
      # HA-01
      live "/", ForumListLive, :index
      # HA-02
      live "/forums/new", ForumNewLive, :new
      # FL-07
      live "/forums/import", ForumImportLive, :new
      # HA-03
      live "/forums/:id", ForumShowLive, :show
      # HA-04
      live "/server", ServerLive, :show
      # HA-05
      live "/settings", SettingsLive, :edit
      # SC-07
      live "/audit", AuditLive, :index
      # HA-06
      live "/identities", IdentitiesLive, :index
      live "/identities/:id", IdentityShowLive, :show
      # Outside forums (steward decisions 2026-11-06)
      live "/outside-forums", OutsideForumsLive, :index
    end

    # HA-07: operator accounts, for owners.
    live_session :owner,
      on_mount: [
        {IdejoHubWeb.OperatorAuth, :require_operator},
        {IdejoHubWeb.OperatorAuth, :require_owner}
      ] do
      live "/operators", OperatorsLive, :index
    end

    # HA-03: archive download (audited).
    get "/forums/:forum_id/archives/:id", ArchiveController, :show
  end

  # HN-02: called by Caddy on the internal network only (the Caddyfile refuses /internal/*
  # from outside). No session, no CSRF.
  scope "/internal", IdejoHubWeb do
    get "/caddy/ask", CaddyController, :ask
    get "/forum-unavailable", CaddyController, :forum_unavailable
    # Idejo's community menu, asked by forums on the forum network (steward decision 2026-11-06).
    get "/community", CommunityController, :index
    get "/community/profile", CommunityController, :profile
    post "/community/profile", CommunityController, :fill_profile
  end

  # Other scopes may use custom stacks.
  # scope "/api", IdejoHubWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:idejo_hub, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard",
        metrics: IdejoHubWeb.Telemetry,
        csp_nonce_assign_key: %{script: :script_csp_nonce, style: :style_csp_nonce}
    end
  end
end
