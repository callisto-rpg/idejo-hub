# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.DirectoryHTML do
  @moduledoc "The forums directory's page."
  use IdejoHubWeb, :html

  embed_templates "directory_html/*"

  @doc "The address parameters of another page of the same search."
  def page_params(%{search: ""}, page), do: [page: page]
  def page_params(%{search: search}, page), do: [q: search, page: page]
end
