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
      # HA-03
      live "/forums/:id", ForumShowLive, :show
      # HA-04
      live "/server", ServerLive, :show
    end

    # HA-03: archive download (audited).
    get "/forums/:forum_id/archives/:id", ArchiveController, :show
  end

  # HN-02: called by Caddy on the internal network only (the Caddyfile refuses /internal/*
  # from outside). No session, no CSRF.
  scope "/internal", IdejoHubWeb do
    get "/caddy/ask", CaddyController, :ask
    get "/forum-unavailable", CaddyController, :forum_unavailable
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
