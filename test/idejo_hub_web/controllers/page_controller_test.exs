# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.PageControllerTest do
  use IdejoHubWeb.ConnCase

  import IdejoHub.OperatorFixtures

  test "GET / shows the Hub's page to a signed-in operator", %{conn: conn} do
    {conn, _operator, _password} = sign_in(conn)
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Idejo Hub"
  end
end
