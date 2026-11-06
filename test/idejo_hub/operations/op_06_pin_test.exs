# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP06PinTest do
  @moduledoc "OP-06: pin a forum to a version, so it is skipped by bulk upgrades (OP-05)."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Ecto.Query
  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias IdejoHub.{Audit, Forums, Operations, Repo}
  alias IdejoHub.Forums.{CreateWorker, Export}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres

  @moduletag req: "OP-06"
  @moduletag :capture_log

  @admin "/app/bin/idejo-admin"
  @subdomains ["op06-a", "op06-b"]

  setup %{conn: conn} do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, &send_resp(&1, 200, "{}"))
    File.rm_rf!(Export.dir())
    on_exit(fn -> for s <- @subdomains, do: Postgres.drop(s) end)

    Fake.exec_result(
      [@admin, "backup"],
      {:ok,
       %{exit_code: 0, output: "Backup written to /data/backups/idejo-20261106-160000.tar\n"}}
    )

    Fake.put_file("/data/backups/idejo-20261106-160000.tar", "pre-upgrade")
    {conn, _operator, _password} = sign_in(conn)
    %{conn: conn, forums: Enum.map(@subdomains, &create/1)}
  end

  defp create(subdomain) do
    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => subdomain, "display_name" => subdomain, "owner_email" => "o@op06.test"},
        "operator"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    Forums.get_forum!(forum.id)
  end

  defp drain do
    a = Oban.drain_queue(queue: :operations)
    b = Oban.drain_queue(queue: :lifecycle)
    if a.success + a.failure + b.success + b.failure > 0, do: drain(), else: :ok
  end

  defp version(subdomain), do: Forums.get_by_subdomain(subdomain).idejo_version

  test "OP-06 a pinned forum is left out of an upgrade of all forums", %{forums: [a, _b]} do
    assert {:ok, %{pinned: true}} = Forums.set_pinned(a, true, "operator")

    assert {:ok, %{forums: ["op06-b"], skipped: [], pinned: ["op06-a"]}} =
             Operations.upgrade_all("0.2.0", "operator")

    drain()
    assert version("op06-a") == "0.1.0"
    assert version("op06-b") == "0.2.0"

    requested =
      Repo.one(
        from e in Audit.Entry,
          where: e.action == "forums.upgrade_all" and e.outcome == "requested"
      )

    assert requested.details["pinned"] == ["op06-a"]

    assert Repo.get_by(Audit.Entry, action: "forum.pin", subdomain: "op06-a").details == %{
             "version" => "0.1.0"
           }
  end

  test "OP-06 pinned after the run was asked for, it is skipped when its turn comes", %{
    forums: [a, _b]
  } do
    {:ok, _} = Operations.upgrade_all("0.2.0", "operator")
    {:ok, _} = Forums.set_pinned(a, true, "operator")
    drain()

    assert version("op06-a") == "0.1.0"
    assert version("op06-b") == "0.2.0"

    done =
      Repo.one(
        from e in Audit.Entry, where: e.action == "forums.upgrade_all" and e.outcome == "ok"
      )

    assert done.details["skipped"] == ["op06-a"]
  end

  test "OP-06 all pinned: nothing to upgrade; unpinned, it is included again", %{
    forums: [a, b]
  } do
    {:ok, a} = Forums.set_pinned(a, true, "operator")
    {:ok, _} = Forums.set_pinned(b, true, "operator")
    assert {:error, :nothing_to_upgrade} = Operations.upgrade_all("0.2.0", "operator")

    {:ok, _} = Forums.set_pinned(a, false, "operator")
    assert Repo.get_by(Audit.Entry, action: "forum.unpin", subdomain: "op06-a")

    assert {:ok, %{forums: ["op06-a"], pinned: ["op06-b"]}} =
             Operations.upgrade_all("0.2.0", "operator")
  end

  test "OP-06 a pinned forum can still be upgraded on its own", %{forums: [a, _b]} do
    {:ok, a} = Forums.set_pinned(a, true, "operator")
    assert {:ok, _} = Forums.upgrade_forum(a, "0.2.0", "operator")
    drain()
    assert version("op06-a") == "0.2.0"
    assert Forums.get_by_subdomain("op06-a").pinned
  end

  test "OP-06 pinned and unpinned from the forum's page, shown in the list", %{
    conn: conn,
    forums: [a, _b]
  } do
    {:ok, view, _} = live(conn, ~p"/forums/#{a}")
    view |> element("#pin-version", "Pin to 0.1.0") |> render_click()
    assert has_element?(view, "#pin", "Pinned to 0.1.0: upgrades of all forums leave it out.")
    assert Forums.get_forum!(a.id).pinned

    {:ok, list, _} = live(conn, ~p"/")
    assert render(list) =~ "pinned"

    html = list |> form("#upgrade-all", version: "0.2.0") |> render_submit()
    assert html =~ "Pinned, left as they are: op06-a."

    view |> element("#unpin-version") |> render_click()
    refute Forums.get_forum!(a.id).pinned
    assert has_element?(view, "#pin-version")
  end
end
