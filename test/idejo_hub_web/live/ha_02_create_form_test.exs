# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.HA02CreateFormTest do
  @moduledoc "HA-02: the create-forum form, with a live check that the subdomain is free and valid."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Forums, Identity}
  alias IdejoHub.Forums.{CreateWorker, Forum}
  alias IdejoHub.Identity.Fake, as: Provider

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

  describe "an existing idejo ID as owner (FL-02, steward request 2026-11-23)" do
    setup do
      Provider.start()
      original = Application.get_env(:idejo_hub, Identity)
      Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Provider))
      on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)

      {:ok, ada} =
        Provider.create_person(%{
          email: "ada@x.test",
          email_verified: true,
          display_name: "Ada Lovelace"
        })

      {:ok, bob} =
        Provider.create_person(%{
          email: "bob@x.test",
          email_verified: false,
          display_name: "Bob Lovelace"
        })

      %{ada: ada, bob: bob}
    end

    defp choose_idejo_id(view),
      do: view |> form("#new-forum", owner_kind: "idejo_id") |> render_change()

    test "searches the IDs, picks one and creates the forum it owns", %{
      conn: conn,
      ada: ada,
      bob: bob
    } do
      {:ok, view, _} = live(conn, ~p"/forums/new")
      choose_idejo_id(view)
      refute has_element?(view, "#forum_owner_email")

      view |> form("#new-forum", owner_search: "LOVE") |> render_change()
      assert has_element?(view, "#owner-result-#{ada} button", "Ada Lovelace")
      refute has_element?(view, "#owner-result-#{bob} button")
      assert has_element?(view, "#owner-result-#{bob}", "email not verified")

      view |> element("#owner-result-#{ada} button") |> render_click()
      assert has_element?(view, "#owner-picked", "ada@x.test")

      {:ok, _list, _html} =
        view
        |> form("#new-forum",
          forum: %{
            subdomain: "ha02-ada",
            display_name: "Ada's",
            idejo_version: Forum.owner_subject_since()
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      forum = Forums.get_by_subdomain("ha02-ada")
      assert forum.owner_subject == ada
      assert forum.owner_email == "ada@x.test"
    end

    test "asks for an ID when none is picked, and for a recent enough idejo", %{
      conn: conn,
      ada: ada
    } do
      {:ok, view, _} = live(conn, ~p"/forums/new")
      choose_idejo_id(view)

      html =
        view
        |> form("#new-forum", forum: %{subdomain: "ha02-none", display_name: "None"})
        |> render_submit()

      assert html =~ "pick the idejo ID that owns the forum"
      assert Forums.get_by_subdomain("ha02-none") == nil

      view |> form("#new-forum", owner_search: "ada") |> render_change()
      view |> element("#owner-result-#{ada} button") |> render_click()

      html =
        view
        |> form("#new-forum",
          forum: %{subdomain: "ha02-old", display_name: "Old", idejo_version: "0.3.25"}
        )
        |> render_submit()

      assert html =~ "needs idejo #{Forum.owner_subject_since()} or later"
      assert Forums.get_by_subdomain("ha02-old") == nil
    end
  end

  test "without an identity provider, the owner is an email only", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/forums/new")
    refute has_element?(view, "#owner-kind")
    assert has_element?(view, "#forum_owner_email")
  end
end
