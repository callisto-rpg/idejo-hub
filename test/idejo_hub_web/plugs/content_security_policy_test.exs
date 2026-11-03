# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.Plugs.ContentSecurityPolicyTest do
  use IdejoHubWeb.ConnCase, async: true

  test "browser pages carry a strict policy whose nonce matches the inline script",
       %{conn: conn} do
    conn = get(conn, ~p"/sign-in")
    [policy] = get_resp_header(conn, "content-security-policy")

    assert policy =~ "default-src 'self'"
    assert policy =~ "frame-ancestors 'none'"
    refute policy =~ "unsafe-inline"

    nonce = conn.assigns.script_csp_nonce
    assert policy =~ "'nonce-#{nonce}'"
    assert html_response(conn, 200) =~ ~s(nonce="#{nonce}")
  end

  test "each request gets a new nonce", %{conn: conn} do
    first = get(conn, ~p"/sign-in").assigns.script_csp_nonce
    second = get(build_conn(), ~p"/").assigns.script_csp_nonce
    refute first == second
  end
end
