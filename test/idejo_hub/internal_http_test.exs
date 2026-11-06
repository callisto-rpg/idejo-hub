# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.InternalHttpTest do
  @moduledoc """
  Every `/internal` route is asked over plain http on the internal networks (Caddy's `ask`
  and error page; forums' community menu), so production's `force_ssl` must leave each one
  out: redirected to https, a forum's menu silently listed nothing (steward report,
  2026-11-06). Tests run without `force_ssl`, so this reads `config/prod.exs`.
  """
  use ExUnit.Case, async: true

  test "production's https redirect leaves out every /internal route" do
    prod = Config.Reader.read!("config/prod.exs", env: :prod)
    excluded = prod[:idejo_hub][IdejoHubWeb.Endpoint][:force_ssl][:exclude][:paths]

    internal =
      for %{path: "/internal" <> _ = path} <- IdejoHubWeb.Router.__routes__(),
          uniq: true,
          do: path

    assert "/internal/community" in internal
    assert internal -- excluded == []
  end
end
