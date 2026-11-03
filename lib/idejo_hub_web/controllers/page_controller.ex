# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.PageController do
  use IdejoHubWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
