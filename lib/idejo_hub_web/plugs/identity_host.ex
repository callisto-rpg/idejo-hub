# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.Plugs.IdentityHost do
  @moduledoc """
  Members' pages (`/account`) answer only on the identity provider's host
  (`id.<hub domain>`), never on the operator's: the two keep apart (steward decision
  2026-11-03). Anywhere else, 404.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.host == IdejoHub.Identity.config(:domain),
      do: conn,
      else: conn |> send_resp(404, "Not found") |> halt()
  end
end
