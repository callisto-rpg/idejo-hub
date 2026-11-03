# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.HA01ForumListTest do
  @moduledoc "HA-01: the forum list, sorted and filtered by status, live."
  use IdejoHubWeb.ConnCase, async: false

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Forums, Repo}
  alias IdejoHub.Forums.Export

  @moduletag req: "HA-01"

  defp forum(subdomain, status, extra \\ %{}) do
    {:ok, forum} =
      Forums.create_forum(
        Map.merge(
          %{
            "subdomain" => subdomain,
            "display_name" => "Club #{subdomain}",
            "owner_email" => "o@#{subdomain}.test"
          },
          extra
        ),
        "operator"
      )

    {:ok, forum} = Forums.update_state(forum, %{status: status})
    forum
  end

  setup %{conn: conn} do
    {conn, _operator, _password} = sign_in(conn)
    %{conn: conn}
  end

  test "needs a signed-in operator" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/")
  end

  test "shows subdomain, name, owner, status, version, last backup and size", %{conn: conn} do
    tennis = forum("ha01-tennis", "running")
    forum("ha01-chess", "suspended")

    Repo.insert!(%Export{
      forum_id: tennis.id,
      subdomain: tennis.subdomain,
      kind: "backup",
      file_name: "idejo-20261103-020000.tar",
      size: 5_400_000,
      sha256: "0",
      inserted_at: ~U[2026-11-03 02:00:00Z]
    })

    {:ok, view, html} = live(conn, ~p"/")
    row = view |> element("#forum-ha01-tennis") |> render()

    for text <- [
          "ha01-tennis",
          "Club ha01-tennis",
          "o@ha01-tennis.test",
          "running",
          "0.1.0",
          "2026-11-03 02:00 UTC",
          "5.1 MB"
        ] do
      assert row =~ text, text
    end

    assert view |> element("#forum-ha01-chess") |> render() =~ "never"
    assert html =~ "Members"
  end

  test "filters by status and sorts, through the address", %{conn: conn} do
    forum("ha01-b", "running")
    forum("ha01-a", "suspended")
    forum("ha01-c", "running", %{"display_name" => "Aardvark"})

    {:ok, view, _} = live(conn, ~p"/?status=running")
    assert has_element?(view, "#forum-ha01-b")
    refute has_element?(view, "#forum-ha01-a")

    {:ok, view, _} = live(conn, ~p"/?sort=name")

    ids =
      view
      |> render()
      |> then(&Regex.scan(~r/id="forum-(ha01-[a-c])"/, &1))
      |> Enum.map(&List.last/1)

    # Aardvark, Club ha01-a, Club ha01-b.
    assert ids == ["ha01-c", "ha01-a", "ha01-b"]

    view |> element("#status-filter a", "suspended") |> render_click()
    assert_patch(view, ~p"/?sort=name&status=suspended")
    assert has_element?(view, "#forum-ha01-a")
    refute has_element?(view, "#forum-ha01-b")
  end

  test "shows changes as they happen", %{conn: conn} do
    forum = forum("ha01-live", "running")
    {:ok, view, _} = live(conn, ~p"/")
    refute render(view) =~ "suspending"

    {:ok, _} = Forums.update_state(forum, %{step: "suspending"})
    assert view |> element("#forum-ha01-live") |> render() =~ "suspending"

    forum("ha01-new", "creating")
    assert has_element?(view, "#forum-ha01-new")
  end

  test "deleted forums are not listed", %{conn: conn} do
    forum("ha01-gone", "deleted")
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#forum-ha01-gone")
  end
end
