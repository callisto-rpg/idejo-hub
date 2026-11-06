# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.DirectoryController do
  @moduledoc """
  The forums directory (steward decision 2026-11-06), at `https://forums.<forum domain>/`:
  every running forum the operator has not hidden (`IdejoHub.Community.directory/0`), public,
  plain HTML. Each forum's "Find more forums" (Idejo's community menu) leads here.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.Community

  def index(conn, params) do
    page =
      case Integer.parse(to_string(params["page"] || "1")) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    result = Community.directory_page(params["q"], page)

    conn
    # Outside forums' logos come from their own hosts: the page's policy allows those shown.
    |> assign(:csp_img_hosts, Enum.map(result.forums, & &1.host))
    |> render(:index,
      forums:
        Enum.map(result.forums, fn %{name: name, host: host} ->
          # The forum's logo at Idejo's fixed address (0.2.9; steward request 2026-11-06).
          %{name: name, url: "https://#{host}/", host: host, logo: "https://#{host}/logo"}
        end),
      result: result,
      browse?: result.listed > Community.per_page(),
      page_title: "Forums"
    )
  end
end
