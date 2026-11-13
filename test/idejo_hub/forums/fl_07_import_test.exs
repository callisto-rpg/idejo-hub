# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.FL07ImportTest do
  @moduledoc "FL-07: import an existing standalone idejo backup as a new Hub forum."
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums, Repo}
  alias IdejoHub.Forums.{CreateWorker, Export, Forum, Import}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.{Maintenance, Postgres}
  alias IdejoHub.Operations.RestoreWorker

  @moduletag req: "FL-07"
  @moduletag :capture_log

  @admin "/app/bin/idejo-admin"
  @key String.duplicate("k", 64)

  setup do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    File.rm_rf!(Export.dir())
    dir = Path.join(System.tmp_dir!(), "fl07-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    on_exit(fn -> for s <- ["fl07-a", "fl07-b"], do: Postgres.drop(s) end)
    %{dir: dir}
  end

  # A standalone idejo backup as Idejo.Backup writes it (or a broken one, by `entries`).
  defp backup(dir, entries \\ nil) do
    entries =
      entries ||
        [
          {"manifest.json",
           Jason.encode!(%{"format" => 1, "migration" => 20_261_104_120_000, "at" => "x"})},
          {"database.dump", "PGDMP dump"},
          {"uploads/0193.webp", "image"}
        ]

    path = Path.join(dir, "upload-#{System.unique_integer([:positive])}")
    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write])
    for {name, data} <- entries, do: :ok = :erl_tar.add(tar, data, String.to_charlist(name), [])
    :ok = :erl_tar.close(tar)
    path
  end

  defp attrs(subdomain),
    do: %{"subdomain" => subdomain, "display_name" => "Tennis", "owner_email" => "o@tennis.test"}

  defp create_job(forum),
    do: (all_enqueued(worker: CreateWorker, args: %{"forum_id" => forum.id}) |> hd()).args

  describe "the archive" do
    test "FL-07 a standalone backup passes the check", %{dir: dir} do
      assert {:ok, %{migration: 20_261_104_120_000}} = Import.check(backup(dir))
    end

    test "FL-07 anything else is refused", %{dir: dir} do
      manifest = {"manifest.json", Jason.encode!(%{"format" => 1, "migration" => 1})}
      dump = {"database.dump", "d"}
      not_tar = Path.join(dir, "plain")
      File.write!(not_tar, "not a tar")

      for path <- [
            not_tar,
            Path.join(dir, "missing"),
            backup(dir, [manifest]),
            backup(dir, [dump]),
            backup(dir, [{"manifest.json", ~s({"format": 2, "migration": 1})}, dump]),
            backup(dir, [{"manifest.json", "not json"}, dump]),
            backup(dir, [manifest, dump, {"../escape", "x"}]),
            backup(dir, [manifest, dump, {"uploads/a/b", "x"}]),
            backup(dir, [manifest, dump, {"uploads/.hidden", "x"}])
          ] do
        assert Import.check(path) == {:error, :not_a_backup}, path
      end
    end
  end

  describe "import_forum/4" do
    test "FL-07 creates the forum behind the page, without setup, then restores the archive", %{
      dir: dir
    } do
      path = backup(dir)
      assert {:ok, forum} = Forums.import_forum(path, attrs("fl07-a"), "operator")
      assert forum.status == "creating"
      # ID-07: the members' accounts are local.
      assert forum.local_accounts

      [export] = Forums.list_exports(forum)
      assert export.kind == "import"
      assert export.file_name =~ ~r/\Aidejo-\d{8}-\d{6}\.tar\z/
      assert File.read!(Export.path(export)) == File.read!(path)
      assert export.size == File.stat!(path).size

      assert export.sha256 ==
               :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

      args = create_job(forum)
      assert args["restore"] == %{"export_id" => export.id, "rotate_push_keys" => true}

      :ok = perform_job(CreateWorker, args)
      assert Maintenance.marked?(Forums.host(forum))

      refute Enum.any?(Fake.state().execs, fn {_c, cmd} -> Enum.at(cmd, 1) == "setup" end)

      [job] = all_enqueued(worker: RestoreWorker, args: %{"forum_id" => forum.id})
      assert :ok = perform_job(RestoreWorker, job.args)

      state = Fake.state()

      assert {"idejo-forum-fl07-a", "/data/backups/#{export.file_name}", File.read!(path)} in state.copied

      runs = for {name, cmd} <- state.runs_seen, do: {name, cmd}

      assert {"idejo-forum-fl07-a-restore", [@admin, "restore", export.file_name, "--yes"]} in runs

      assert {"idejo-forum-fl07-a-keys", [@admin, "rotate-push-keys", "--yes"]} in runs

      forum = Forums.get_forum!(forum.id)
      assert forum.status == "running"
      refute Maintenance.marked?(Forums.host(forum))

      entries = Audit.for_forum(forum.id)
      assert %{details: details} = Enum.find(entries, &(&1.action == "forum.import"))
      assert details["secret_key_base"] == "new"
      assert details["file"] == export.file_name

      assert Enum.any?(
               entries,
               &(&1.action == "forum.restore" and &1.outcome == "ok" and
                   &1.details["kind"] == "import")
             )
    end

    test "FL-07 the standalone's SECRET_KEY_BASE moves with its data, never into the log", %{
      dir: dir
    } do
      {:ok, forum} =
        Forums.import_forum(backup(dir), attrs("fl07-a"), "operator", secret_key_base: @key)

      assert Forums.secret(forum, :secret_key_base) == {:ok, @key}
      assert create_job(forum)["restore"]["rotate_push_keys"] == false

      entries = Audit.for_forum(forum.id)

      assert Enum.find(entries, &(&1.action == "forum.import")).details["secret_key_base"] ==
               "standalone"

      refute inspect(entries) =~ @key
    end

    test "FL-07 a refused file, key or form records nothing", %{dir: dir} do
      bad = backup(dir, [{"database.dump", "d"}])
      assert Forums.import_forum(bad, attrs("fl07-a"), "operator") == {:error, :not_a_backup}

      assert Forums.import_forum(backup(dir), attrs("fl07-a"), "operator",
               secret_key_base: "short"
             ) ==
               {:error, :invalid_key}

      {:ok, _} = Forums.import_forum(backup(dir), attrs("fl07-a"), "operator")
      assert {:error, %Ecto.Changeset{}} = Forums.import_forum(backup(dir), attrs("fl07-a"), "op")
      assert {:error, %Ecto.Changeset{}} = Forums.import_forum(backup(dir), attrs("www"), "op")

      assert [%Forum{subdomain: "fl07-a"}] = Repo.all(Forum)
      assert [_one] = Repo.all(Export)
      assert [_one_file] = File.ls!(Path.join(Export.dir(), "fl07-a"))
      refute File.exists?(Path.join(Export.dir(), "www"))
      assert all_enqueued(worker: CreateWorker) |> length() == 1
    end

    test "FL-07 never overwrites an archive kept under the same subdomain", %{dir: dir} do
      forum = %{id: 1, subdomain: "fl07-b"}
      {:ok, first} = Import.store(forum, backup(dir))
      {:ok, second} = Import.store(forum, backup(dir))
      assert first.file_name != second.file_name
      assert second.file_name =~ ~r/\Aidejo-\d{8}-\d{6}(-\d+)?\.tar\z/
      assert File.exists?(Export.path(first)) and File.exists?(Export.path(second))
    end
  end
end
