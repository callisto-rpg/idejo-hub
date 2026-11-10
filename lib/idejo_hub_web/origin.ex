# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.Origin do
  @moduledoc """
  Where LiveView's socket may be opened from (SC-02): the Hub's own host (`PHX_HOST`) and the
  members' page, `my.<forum domain>` (steward request 2026-11-10), on the endpoint's scheme
  and nothing else: no forum's page, no other host.
  """

  @doc "Whether a browser's `Origin` may open the socket."
  @spec allowed?(URI.t()) :: boolean()
  def allowed?(%URI{scheme: scheme, host: host}) do
    url = Application.fetch_env!(:idejo_hub, IdejoHubWeb.Endpoint)[:url]
    own_scheme = to_string(url[:scheme] || "http")

    scheme == own_scheme and host in [url[:host], IdejoHub.Community.my_host()]
  end
end
