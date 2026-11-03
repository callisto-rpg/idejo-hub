# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.FL06StandaloneKeyTest do
  @moduledoc "FL-06: the forum's SECRET_KEY_BASE for a standalone restore of its export, audited."
  use IdejoHubWeb.ConnCase, async: false

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Forums, Repo}
  alias IdejoHub.Forums.Export

  @moduletag req: "FL-06"

  setup %{conn: conn} do
    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => "key-a", "display_name" => "A", "owner_email" => "o@a.test"},
        "op"
      )

    Repo.insert!(%Export{
      forum_id: forum.id,
      subdomain: "key-a",
      kind: "export",
      file_name: "x.tar",
      size: 1,
      sha256: "0"
    })

    {conn, operator, _} = sign_in(conn)
    %{conn: conn, operator: operator, forum: forum}
  end

  test "the operator gets the forum's key, audited, and the Hub keeps it", %{
    forum: forum,
    operator: op
  } do
    {:ok, stored} = Forums.secret(forum, :secret_key_base)
    assert Forums.reveal_secret_key_base(forum, op.email) == {:ok, stored}
    assert Forums.reveal_secret_key_base(forum, op.email) == {:ok, stored}

    reveals =
      for e <- Audit.for_forum(forum.id), e.action == "forum.secret_key_base.reveal", do: e

    assert length(reveals) == 2
    assert Enum.all?(reveals, &(&1.actor == op.email and not (inspect(&1.details) =~ stored)))
  end

  test "deleted forums too (their final export)", %{forum: forum, operator: op} do
    {:ok, deleted} = Forums.update_state(forum, %{status: "deleted"})
    assert {:ok, _key} = Forums.reveal_secret_key_base(deleted, op.email)
  end

  test "the forum page shows it on demand, beside the archives", %{conn: conn, forum: forum} do
    {:ok, stored} = Forums.secret(forum, :secret_key_base)
    {:ok, view, html} = live(conn, ~p"/forums/#{forum}")
    refute html =~ stored

    assert view |> element("#standalone-key button") |> render_click() =~ stored
    assert Enum.any?(Audit.for_forum(forum.id), &(&1.action == "forum.secret_key_base.reveal"))
  end
end
