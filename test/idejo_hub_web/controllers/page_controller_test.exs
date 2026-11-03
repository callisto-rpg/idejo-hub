# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.PageControllerTest do
  use IdejoHubWeb.ConnCase

  test "GET / shows the Hub's placeholder page", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Idejo Hub"
  end
end
