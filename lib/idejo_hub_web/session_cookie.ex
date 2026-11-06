# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SessionCookie do
  @moduledoc """
  The session cookie's options (`IdejoHubWeb.Endpoint`).

  SC-08: encrypted, HttpOnly, host-only (no Domain, as SC-01 asks of forums), SameSite=Strict
  (no operator page is reached from another site), Secure outside development and tests.

  SC-02: every forum is same-site to the Hub, so SameSite does not keep a forum's pages from
  sending requests to it with this cookie; the CSRF token kept in the session does
  (`:protect_from_forgery` on every route that changes anything, and LiveView's socket checks
  it when it connects). Where the cookie is Secure it is named `__Host-idejo_hub`: browsers
  then let no subdomain set or overwrite it, so a forum's page cannot toss its own session
  (and the CSRF token that goes with it) at the Hub. Plain http (development, tests) cannot
  carry that prefix.
  """

  @doc "The options for `Plug.Session`, Secure or not."
  @spec options(boolean()) :: keyword()
  def options(secure?) do
    [
      store: :cookie,
      key: if(secure?, do: "__Host-idejo_hub", else: "_idejo_hub_key"),
      signing_salt: "+asp2I0Z",
      encryption_salt: "Gk3vQ0tL",
      same_site: "Strict",
      http_only: true,
      secure: secure?,
      path: "/"
    ]
  end
end
