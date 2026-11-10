# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.Plugs.MyHost do
  @moduledoc """
  The members' page (steward request 2026-11-10) answers only on its own host,
  `my.<IDEJO_FORUM_DOMAIN>` (`IdejoHub.Community.my_host/0`); anywhere else, 404. Its pages
  show pictures from forums (their hosts are under the forum domain, or registered outside
  forums) and Idejo ID pictures (the sign-in host): the content security policy names them.
  """
  @behaviour Plug
  import Plug.Conn
  import Ecto.Query

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if conn.host == IdejoHub.Community.my_host() do
      outside =
        IdejoHub.Repo.all(
          from o in IdejoHub.Identity.OutsideForum,
            where: o.status == "registered",
            select: o.host
        )

      id_host = URI.parse(IdejoHub.Identity.issuer()).host
      assign(conn, :csp_img_hosts, [id_host | outside])
    else
      conn |> send_resp(404, "Not found") |> halt()
    end
  end
end
