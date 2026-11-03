# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP05UpgradeAllTest do
  @moduledoc "OP-05: upgrade all forums in sequence, stopping at the first failure."
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums, Operations, Repo}
  alias IdejoHub.Forums.{CreateWorker, Export, SuspendWorker}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Operations.BulkUpgradeWorker

  @moduletag req: "OP-05"
  @moduletag :capture_log

  @admin "/app/bin/idejo-admin"
  @subdomains ["op05-a", "op05-b", "op05-c", "op05-d"]

  setup do
    Fake.start()
    healthy_except(nil)
    File.rm_rf!(Export.dir())
    on_exit(fn -> for s <- @subdomains, do: Postgres.drop(s) end)

    forums = for s <- ["op05-a", "op05-b", "op05-c"], do: create(s)

    Fake.exec_result(
      [@admin, "backup"],
      {:ok,
       %{exit_code: 0, output: "Backup written to /data/backups/idejo-20261103-160000.tar\n"}}
    )

    Fake.put_file("/data/backups/idejo-20261103-160000.tar", "pre-upgrade")
    %{forums: forums}
  end

  # /health fails for `bad` once it runs 0.2.0.
  defp healthy_except(bad) do
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn ->
      image = get_in(Fake.state().containers, [conn.host, "Spec", "Image"])

      failing =
        bad && conn.host == "idejo-forum-#{bad}" && String.ends_with?(image || "", ":0.2.0")

      send_resp(conn, if(failing, do: 503, else: 200), "{}")
    end)
  end

  defp create(subdomain) do
    {:ok, forum} =
      Forums.create_forum(
        %{
          "subdomain" => subdomain,
          "display_name" => subdomain,
          "owner_email" => "o@example.test"
        },
        "operator"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    Forums.get_forum!(forum.id)
  end

  # Runs the chain: upgrades (lifecycle) and run steps (operations), until nothing is left.
  defp drain do
    a = Oban.drain_queue(queue: :operations)
    b = Oban.drain_queue(queue: :lifecycle)
    if a.success + a.failure + b.success + b.failure > 0, do: drain(), else: :ok
  end

  defp version(subdomain), do: Forums.get_by_subdomain(subdomain).idejo_version

  defp run_entry(outcome) do
    Repo.one(
      from e in IdejoHub.Audit.Entry,
        where: e.action == "forums.upgrade_all" and e.outcome == ^outcome
    )
  end

  test "upgrades every running forum, one after another" do
    assert {:ok, %{forums: ["op05-a", "op05-b", "op05-c"], skipped: []}} =
             Operations.upgrade_all("0.2.0", "operator")

    drain()

    for s <- ["op05-a", "op05-b", "op05-c"], do: assert(version(s) == "0.2.0")
    assert run_entry("ok").details["done"] == ["op05-a", "op05-b", "op05-c"]

    # In sequence: each forum's upgrade began after the previous one ended.
    upgrades =
      Audit.Entry
      |> Repo.all()
      |> Enum.filter(&(&1.action == "forum.upgrade"))
      |> Enum.map(&{&1.subdomain, &1.outcome})

    assert upgrades == [
             {"op05-a", "requested"},
             {"op05-a", "ok"},
             {"op05-b", "requested"},
             {"op05-b", "ok"},
             {"op05-c", "requested"},
             {"op05-c", "ok"}
           ]
  end

  test "stops at the first failure; the forums after it are not touched" do
    healthy_except("op05-b")
    {:ok, _} = Operations.upgrade_all("0.2.0", "operator")
    drain()

    assert version("op05-a") == "0.2.0"
    # Rolled back by OP-04.
    assert version("op05-b") == "0.1.0"
    assert Forums.get_by_subdomain("op05-b").status == "running"
    # Never attempted.
    assert version("op05-c") == "0.1.0"

    refute Enum.any?(
             Repo.all(Audit.Entry),
             &(&1.action == "forum.upgrade" and &1.subdomain == "op05-c")
           )

    entry = run_entry("failed")
    assert entry.details["done"] == ["op05-a"]
    assert entry.details["failed"] == "op05-b"
    assert entry.details["not_attempted"] == ["op05-c"]
    assert run_entry("ok") == nil
  end

  test "forums that are not running, or already up to date, are skipped", %{forums: [a, _b, _c]} do
    {:ok, _} = Forums.suspend_forum(a, "operator")
    :ok = perform_job(SuspendWorker, %{"forum_id" => a.id, "actor" => "operator"})
    d = create("op05-d")
    Repo.update!(Ecto.Changeset.change(d, idejo_version: "0.2.0"))

    assert {:ok, %{forums: ["op05-b", "op05-c"], skipped: ["op05-a"]}} =
             Operations.upgrade_all("0.2.0", "operator")

    drain()

    assert version("op05-a") == "0.1.0"
    assert run_entry("ok").details["done"] == ["op05-b", "op05-c"]
  end

  test "one run at a time, and only an exact version with something to do" do
    assert Operations.upgrade_all("latest", "operator") == {:error, :invalid_version}
    assert Operations.upgrade_all("0.1.0", "operator") == {:error, :nothing_to_upgrade}

    {:ok, _} = Operations.upgrade_all("0.2.0", "operator")
    assert Operations.upgrade_all("0.2.0", "operator") == {:error, :already_running}
    assert_enqueued(worker: BulkUpgradeWorker)
  end
end
