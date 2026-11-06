# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.DirectoryController do
  @moduledoc """
  The forums directory (steward decision 2026-11-06), at `https://forums.<forum domain>/`:
  every running forum the operator has not hidden (`IdejoHub.Community.directory/0`), public,
  plain HTML. Each forum's "Find more forums" (Idejo's community menu) leads here.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.{Community, Forums}

  def index(conn, _params) do
    render(conn, :index,
      forums:
        Enum.map(Community.directory(), &{&1.display_name, "https://" <> Forums.host(&1) <> "/"}),
      page_title: "Forums"
    )
  end
end
