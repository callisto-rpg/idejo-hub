# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.HA03ForumDetailTest do
  @moduledoc "HA-03: forum detail: health, backups (run, restore, download), upgrade, suspend, delete, audit log."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias IdejoHub.{Audit, Forums, Repo, Secrets}
  alias IdejoHub.Forums.{CreateWorker, Export, ExportWorker, SuspendWorker}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Operations.{BackupWorker, RestoreWorker, UpgradeWorker}

  @moduletag req: "HA-03"
  @moduletag :capture_log

  setup %{conn: conn} do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    File.rm_rf!(Export.dir())
    on_exit(fn -> for s <- ["ha03-a", "ha03-b"], do: Postgres.drop(s) end)

    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => "ha03-a", "display_name" => "Club A", "owner_email" => "o@a.test"},
        "op"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "op"})
    {conn, operator, _} = sign_in(conn)
    %{conn: conn, operator: operator, forum: Forums.get_forum!(forum.id)}
  end

  defp archive(forum, kind \\ "backup") do
    path = Path.join([Export.dir(), forum.subdomain, "idejo-20261103-010000.tar"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "tar bytes")

    Repo.insert!(%Export{
      forum_id: forum.id,
      subdomain: forum.subdomain,
      kind: kind,
      file_name: "idejo-20261103-010000.tar",
      size: 9,
      sha256: "abc123"
    })
  end

  test "the list links to the page, which shows the forum, its health and audit log", %{
    conn: conn,
    forum: forum
  } do
    {:ok, list, _} = live(conn, ~p"/")

    assert {:ok, view, _} =
             list |> element("#forum-ha03-a a") |> render_click() |> follow_redirect(conn)

    assert render_async(view) =~ "healthy (/health 200)"
    html = render(view)
    assert html =~ "Club A"
    assert html =~ "ha03-a.idejo.test"
    assert view |> element("#audit") |> render() =~ "forum.create"
    _ = forum
  end

  test "suspend, back up, export and upgrade queue their jobs as the operator", %{
    conn: conn,
    forum: forum,
    operator: op
  } do
    {:ok, view, _} = live(conn, ~p"/forums/#{forum}")

    view |> element("#backup") |> render_click()
    assert_enqueued(worker: BackupWorker, args: %{"forum_id" => forum.id, "actor" => op.email})
    Repo.update_all(IdejoHub.Forums.Forum, set: [step: nil])

    view |> element("#export") |> render_click()
    assert_enqueued(worker: ExportWorker, args: %{"forum_id" => forum.id})
    Repo.update_all(IdejoHub.Forums.Forum, set: [step: nil])

    assert view |> form("#upgrade", %{"version" => "0.0.1"}) |> render_submit() =~
             "newer than the current"

    view |> form("#upgrade", %{"version" => "0.2.0"}) |> render_submit()
    assert_enqueued(worker: UpgradeWorker, args: %{"forum_id" => forum.id, "version" => "0.2.0"})
    Repo.update_all(IdejoHub.Forums.Forum, set: [step: nil])

    view |> element("#suspend") |> render_click()
    assert_enqueued(worker: SuspendWorker, args: %{"forum_id" => forum.id, "actor" => op.email})
    assert view |> element("#step") |> render() =~ "suspending"
  end

  test "busy forums refuse a second action with a message", %{conn: conn, forum: forum} do
    {:ok, view, _} = live(conn, ~p"/forums/#{forum}")
    view |> element("#backup") |> render_click()
    assert view |> element("#export") |> render_click() =~ "Not now"
  end

  test "restore here, restore to a new subdomain, and nothing from another forum", %{
    conn: conn,
    forum: forum
  } do
    a = archive(forum)

    {:ok, other} =
      Forums.create_forum(
        %{"subdomain" => "ha03-b", "display_name" => "B", "owner_email" => "o@b.test"},
        "op"
      )

    foreign = archive(other)

    {:ok, view, _} = live(conn, ~p"/forums/#{forum}")

    assert render_click(view, "restore", %{"archive" => to_string(foreign.id)}) =~
             "belongs to another forum"

    view |> element("#archive-#{a.id} button", "Restore here") |> render_click()
    assert_enqueued(worker: RestoreWorker, args: %{"forum_id" => forum.id, "export_id" => a.id})
    Repo.update_all(IdejoHub.Forums.Forum, set: [step: nil])

    {:ok, _new_view, html} =
      view
      |> form("#restore-new", %{"archive" => to_string(a.id), "subdomain" => "ha03-c"})
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Creating ha03-c from this archive"
    assert Forums.get_by_subdomain("ha03-c").status == "creating"
  end

  test "download: the file, audited; another forum's archive is not found", %{
    conn: conn,
    forum: forum,
    operator: op
  } do
    a = archive(forum)
    response = get(conn, ~p"/forums/#{forum}/archives/#{a}")
    assert response.resp_body == "tar bytes"

    assert get_resp_header(response, "content-disposition") |> hd() =~
             "ha03-a-idejo-20261103-010000.tar"

    assert Enum.any?(
             Audit.for_forum(forum.id),
             &(&1.action == "forum.archive.download" and &1.actor == op.email)
           )

    {:ok, other} =
      Forums.create_forum(
        %{"subdomain" => "ha03-b", "display_name" => "B", "owner_email" => "o@b.test"},
        "op"
      )

    foreign = archive(other)
    assert_error_sent 404, fn -> get(recycle(conn), ~p"/forums/#{forum}/archives/#{foreign}") end
    assert get(build_conn(), ~p"/forums/#{forum}/archives/#{a}").status == 302
  end

  test "delete with grace, or now only with the subdomain typed", %{conn: conn, forum: forum} do
    {:ok, view, _} = live(conn, ~p"/forums/#{forum}")

    assert view |> form("#delete form", %{"confirm" => "wrong"}) |> render_submit() =~
             "Type the forum"

    refute_enqueued(worker: IdejoHub.Forums.DeleteWorker)

    view |> form("#delete form", %{"confirm" => "ha03-a"}) |> render_submit()

    assert_enqueued(
      worker: IdejoHub.Forums.DeleteWorker,
      args: %{"forum_id" => forum.id, "immediate" => true}
    )
  end

  test "the owner's link is shown once, then gone", %{conn: conn, forum: forum} do
    link = "https://ha03-a.idejo.test/users/reset-password/tok"

    {:ok, _} =
      Forums.update_state(forum, %{
        owner_invite: "operator",
        owner_link_enc: Secrets.encrypt(link, Forums.context("ha03-a", :owner_link))
      })

    {:ok, view, _} = live(conn, ~p"/forums/#{forum}")
    assert view |> element("#owner-link button") |> render_click() =~ link
    assert Forums.get_forum!(forum.id).owner_link_enc == nil

    {:ok, view, _} = live(conn, ~p"/forums/#{forum}")
    refute has_element?(view, "#owner-link")
  end
end
