# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.OP05UpgradeAllUITest do
  @moduledoc "OP-05 from the forum list: upgrade all running forums."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.Forums
  alias IdejoHub.Operations.BulkUpgradeWorker

  @moduletag req: "OP-05"

  setup %{conn: conn} do
    {conn, operator, _} = sign_in(conn)

    for {s, status} <- [
          {"op05ui-a", "running"},
          {"op05ui-b", "running"},
          {"op05ui-c", "suspended"}
        ] do
      {:ok, f} =
        Forums.create_forum(
          %{"subdomain" => s, "display_name" => s, "owner_email" => "o@x.test"},
          "op"
        )

      {:ok, _} = Forums.update_state(f, %{status: status})
    end

    %{conn: conn, operator: operator}
  end

  test "starts the run as the operator and says what it does", %{conn: conn, operator: op} do
    {:ok, view, _} = live(conn, ~p"/")
    html = view |> form("#upgrade-all", %{"version" => "0.2.0"}) |> render_submit()

    assert html =~ "Upgrading op05ui-a, op05ui-b to 0.2.0"
    assert html =~ "Skipped (not running): op05ui-c"
    assert_enqueued(worker: BulkUpgradeWorker, args: %{"version" => "0.2.0", "actor" => op.email})

    assert view |> form("#upgrade-all", %{"version" => "0.2.0"}) |> render_submit() =~
             "already under way"
  end

  test "refuses a bad version or nothing to do", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    assert view |> form("#upgrade-all", %{"version" => "latest"}) |> render_submit() =~
             "exact version"

    assert view |> form("#upgrade-all", %{"version" => "0.1.0"}) |> render_submit() =~
             "already on that version"
  end
end
