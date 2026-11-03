# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.HA02CreateFormTest do
  @moduledoc "HA-02: the create-forum form, with a live check that the subdomain is free and valid."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.CreateWorker

  @moduletag req: "HA-02"

  setup %{conn: conn} do
    {conn, operator, _password} = sign_in(conn)
    %{conn: conn, operator: operator}
  end

  defp type(view, subdomain),
    do: view |> form("#new-forum", forum: %{subdomain: subdomain}) |> render_change()

  test "the list links to the form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    assert {:ok, _form, _html} =
             view |> element("#new-forum-link") |> render_click() |> follow_redirect(conn)
  end

  test "checks the subdomain while typing", %{conn: conn} do
    {:ok, _} =
      Forums.create_forum(
        %{"subdomain" => "ha02-taken", "display_name" => "T", "owner_email" => "o@t.test"},
        "op"
      )

    {:ok, view, _} = live(conn, ~p"/forums/new")

    assert type(view, "ha02-free") =~ "Available: https://ha02-free.idejo.test"
    html = type(view, "ha02-taken")
    assert html =~ "is already used by another forum"
    refute html =~ "Available:"
    assert type(view, "www") =~ "is reserved"
    assert type(view, "Bad_Name") =~ "use lowercase letters"
  end

  test "creates the forum as the signed-in operator and goes back to the list", %{
    conn: conn,
    operator: operator
  } do
    {:ok, view, _} = live(conn, ~p"/forums/new")

    {:ok, _list, html} =
      view
      |> form("#new-forum",
        forum: %{subdomain: "ha02-new", display_name: "New Club", owner_email: "owner@new.test"}
      )
      |> render_submit()
      |> follow_redirect(conn, ~p"/")

    assert html =~ "Creating ha02-new.idejo.test"
    assert html =~ "forum-ha02-new"
    forum = Forums.get_by_subdomain("ha02-new")
    assert forum.status == "creating"

    assert_enqueued(
      worker: CreateWorker,
      args: %{"forum_id" => forum.id, "actor" => operator.email}
    )

    assert [%{actor: actor}] = Audit.for_forum(forum.id)
    assert actor == operator.email
  end

  test "errors stay on the form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/forums/new")

    html =
      view
      |> form("#new-forum",
        forum: %{subdomain: "ha02-x", display_name: "X", owner_email: "not-an-email"}
      )
      |> render_submit()

    assert html =~ "must be an email address"
    assert Forums.get_by_subdomain("ha02-x") == nil
  end
end
