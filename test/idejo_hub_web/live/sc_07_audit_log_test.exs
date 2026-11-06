# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SC07AuditLogTest do
  @moduledoc "SC-07: the Hub's audit log, for the operator: who did what to which forum, when."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Forums}

  @moduletag req: "SC-07"

  setup %{conn: conn} do
    {conn, operator, _} = sign_in(conn)
    {:ok, tennis} = forum("sc07-tennis")
    {:ok, chess} = forum("sc07-chess")
    %{conn: conn, operator: operator, tennis: tennis, chess: chess}
  end

  defp forum(subdomain),
    do:
      Forums.create_forum(
        %{"subdomain" => subdomain, "display_name" => subdomain, "owner_email" => "o@x.test"},
        "op@hub.test"
      )

  test "SC-07 the operator sees every entry, newest first, with its forum", %{
    conn: conn,
    tennis: tennis
  } do
    {:ok, _} =
      Audit.record("op@hub.test", "forum.backup", "failed", tennis, %{"error" => "disk full"})

    {:ok, _} =
      Audit.record("op@hub.test", "settings.update", "ok", nil, %{"keys" => ["alert_email"]})

    {:ok, view, html} = live(conn, ~p"/audit")
    assert html =~ "Audit log"
    rows = view |> element("#audit") |> render()
    assert :binary.match(rows, "settings.update") < :binary.match(rows, "forum.backup")
    assert rows =~ "error: disk full"
    assert rows =~ "keys: alert_email"
    assert has_element?(view, ~s(#audit a[href="/forums/#{tennis.id}"]), "sc07-tennis")
  end

  test "SC-07 filters by forum, action, outcome and who, kept in the address", %{
    conn: conn,
    tennis: tennis,
    chess: chess
  } do
    {:ok, _} = Audit.record("op@hub.test", "forum.backup", "failed", tennis, %{})
    {:ok, _} = Audit.record("schedule", "forum.backup", "ok", chess, %{})
    {:ok, _} = Audit.record("other@hub.test", "forum.suspend", "ok", chess, %{})

    {:ok, view, _} = live(conn, ~p"/audit")

    view
    |> form("#audit-filter", filter: %{forum: "sc07-chess", action: "forum.b"})
    |> render_submit()

    assert_patch(view, ~p"/audit?#{[action: "forum.b", forum: "sc07-chess"]}")
    rows = view |> element("#audit") |> render()
    assert rows =~ "schedule"
    refute rows =~ "op@hub.test"
    refute rows =~ "forum.suspend"

    {:ok, view, _} = live(conn, ~p"/audit?outcome=failed")
    rows = view |> element("#audit") |> render()
    assert rows =~ "sc07-tennis" and not (rows =~ "sc07-chess")

    {:ok, view, _} = live(conn, ~p"/audit?actor=OTHER")
    assert view |> element("#audit") |> render() =~ "forum.suspend"

    # LIKE's wildcards are taken literally.
    {:ok, view, _} = live(conn, ~p"/audit?action=%25")
    assert has_element?(view, "#audit-empty")
  end

  test "SC-07 pages of 50, older entries a link away", %{conn: conn, tennis: tennis} do
    for n <- 1..55, do: {:ok, _} = Audit.record("op@hub.test", "forum.n#{n}", "ok", tennis, %{})

    {:ok, view, _} = live(conn, ~p"/audit?forum=sc07-tennis")
    assert has_element?(view, "#audit", "forum.n55")
    refute has_element?(view, "#audit", "forum.n5 ")

    view |> element("#audit-older") |> render_click()
    assert has_element?(view, "#audit", "forum.n1")
    refute has_element?(view, "#audit", "forum.n55")
    refute has_element?(view, "#audit-older")
  end

  test "SC-07 linked from every operator page and from each forum's page", %{
    conn: conn,
    tennis: tennis
  } do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(a[href="/audit"]), "Audit log")

    {:ok, view, _} = live(conn, ~p"/forums/#{tennis}")
    assert has_element?(view, ~s(#audit-filtered[href="/audit?forum=sc07-tennis"]))
  end

  test "SC-07 only operators see it" do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(build_conn(), ~p"/audit")
  end
end
