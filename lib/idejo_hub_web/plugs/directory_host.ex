# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.Plugs.DirectoryHost do
  @moduledoc """
  The forums directory (steward decision 2026-11-06) answers only on its own host,
  `forums.<IDEJO_FORUM_DOMAIN>` (`IdejoHub.Community.directory_host/0`). Anywhere else, 404.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.host == IdejoHub.Community.directory_host(),
      do: conn,
      else: conn |> send_resp(404, "Not found") |> halt()
  end
end
