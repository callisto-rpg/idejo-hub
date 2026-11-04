# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.OP10HubBackupUITest do
  @moduledoc "OP-10: the server page shows the Hub's own backups and starts one."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.Forums.Export
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Operations.HubBackupWorker

  @moduletag req: "OP-10"
  @moduletag :capture_log

  setup %{conn: conn} do
    Fake.start()
    File.rm_rf!(Export.dir())
    {conn, operator, _} = sign_in(conn)
    %{conn: conn, operator: operator}
  end

  test "lists the newest dump and starts a backup as the operator", %{conn: conn, operator: op} do
    {:ok, view, html} = live(conn, ~p"/server")
    assert html =~ "Hub backups"
    assert html =~ "None yet."

    assert view |> element("#backup-hub") |> render_click() =~ "Hub backup started."
    assert view |> element("#backup-hub") |> render_click() =~ "A Hub backup is already running."
    assert_enqueued(worker: HubBackupWorker, args: %{"actor" => op.email})

    :ok = perform_job(HubBackupWorker, %{"actor" => op.email})
    {:ok, _view, html} = live(conn, ~p"/server")
    assert html =~ "Hub database"
    refute html =~ "None yet."
  end
end
