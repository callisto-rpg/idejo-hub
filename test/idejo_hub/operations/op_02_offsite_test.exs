# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP02OffsiteTest do
  @moduledoc "OP-02: off-server backup copy to S3-compatible storage, encrypted before upload."
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.Audit.Entry
  alias IdejoHub.{Forums, Repo, S3Fake}
  alias IdejoHub.Forums.{CreateWorker, Export}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Operations.{BackupWorker, HubBackup, HubBackupWorker, Offsite, OffsiteWorker}

  @moduletag req: "OP-02"
  @moduletag :capture_log

  @recipient "age143llv2nsl3c2832hcsmj4vhqkwp24y23zqd9cvsan4vk0cv3tuaqpth6vt"
  @backup ["/app/bin/idejo-admin", "backup"]

  setup do
    Fake.start()
    S3Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    File.rm_rf!(Export.dir())

    original = Application.fetch_env!(:idejo_hub, Offsite)
    on_exit(fn -> Application.put_env(:idejo_hub, Offsite, original) end)
    on_exit(fn -> Postgres.drop("op02-a") end)

    storage()
    %{forum: create("op02-a")}
  end

  defp storage(opts \\ []) do
    config =
      Application.fetch_env!(:idejo_hub, Offsite)
      |> Keyword.merge(
        endpoint: "https://s3.example.test",
        region: "eu-central-1",
        bucket: "backups",
        prefix: "hub1/",
        access_key_id: "AKIDEXAMPLE",
        secret_access_key: "s3-secret-key",
        recipient: @recipient
      )
      |> Keyword.merge(opts)

    Application.put_env(:idejo_hub, Offsite, config)
  end

  defp create(subdomain) do
    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => subdomain, "display_name" => "F", "owner_email" => "o@example.test"},
        "operator"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    Forums.get_forum!(forum.id)
  end

  defp back_up(forum, n) do
    path = "/data/backups/idejo-20261104-#{String.pad_leading("#{n}", 6, "0")}.tar"
    Fake.exec_result(@backup, {:ok, %{exit_code: 0, output: "Backup written to #{path}\n"}})
    Fake.put_file(path, "forum data #{n}\n")
    {:ok, forum} = Forums.backup_forum(Forums.get_forum!(forum.id), "schedule")
    :ok = perform_job(BackupWorker, %{"forum_id" => forum.id, "actor" => "schedule"})
    [export | _] = Forums.list_exports(forum)
    export
  end

  defp copy(source, id), do: perform_job(OffsiteWorker, %{"source" => source, "id" => id})

  defp entries(action), do: Repo.all(from e in Entry, where: e.action == ^action, order_by: e.id)

  test "a scheduled forum backup is encrypted to the public key, uploaded and recorded", %{
    forum: forum
  } do
    export = back_up(forum, 1)
    assert_enqueued(worker: OffsiteWorker, args: %{"source" => "forum", "id" => export.id})

    assert :ok = copy("forum", export.id)

    key = "hub1/forums/op02-a/#{export.file_name}.age"
    body = S3Fake.objects()[key]
    assert body =~ "AGE-FAKE #{@recipient}\n"
    refute body =~ "forum data 1"

    export = Repo.get!(Export, export.id)
    assert export.offsite_key == key and export.offsite_at
    # The local file stays; the encrypted one is not left behind.
    assert File.exists?(Export.path(export))
    assert File.ls!(Path.dirname(Export.path(export))) == [export.file_name]

    [entry] = entries("forum.backup.offsite")
    assert entry.outcome == "ok" and entry.forum_id == forum.id
    assert entry.details["key"] == key
    refute inspect(entry.details) =~ "s3-secret-key"
  end

  test "every request is signed with AWS Signature V4, path-style", %{forum: forum} do
    export = back_up(forum, 1)
    assert :ok = copy("forum", export.id)
    assert {"PUT", "backups", "hub1/forums/op02-a/" <> _, _} = hd(S3Fake.requests())
  end

  test "keeps the newest 14 copies per forum and deletes older ones", %{forum: forum} do
    for n <- 1..15,
        do:
          S3Fake.put_object(
            "hub1/forums/op02-a/idejo-20261101-#{String.pad_leading("#{n}", 6, "0")}.tar.age",
            "old"
          )

    S3Fake.put_object("hub1/forums/op02-b/idejo-20261101-000001.tar.age", "another forum")

    export = back_up(forum, 1)
    assert :ok = copy("forum", export.id)

    keys =
      S3Fake.objects()
      |> Map.keys()
      |> Enum.filter(&String.starts_with?(&1, "hub1/forums/op02-a/"))

    assert length(keys) == 14
    assert "hub1/forums/op02-a/#{export.file_name}.age" in keys
    refute "hub1/forums/op02-a/idejo-20261101-000002.tar.age" in keys
    assert S3Fake.objects()["hub1/forums/op02-b/idejo-20261101-000001.tar.age"]

    [entry] = entries("forum.backup.offsite")
    assert length(entry.details["pruned"]) == 2
  end

  test "large files go up as a multipart upload, a part at a time", %{forum: forum} do
    storage(part_size: 8)
    export = back_up(forum, 1)
    assert :ok = copy("forum", export.id)

    key = "hub1/forums/op02-a/#{export.file_name}.age"
    assert S3Fake.objects()[key] =~ "AGE-FAKE"
    parts = for {"PUT", _, ^key, %{"partNumber" => n}} <- S3Fake.requests(), do: n
    assert length(parts) > 1
  end

  test "the Hub's own dumps are copied under hub/, kept per database" do
    for n <- 1..15,
        do:
          S3Fake.put_object(
            "hub1/hub/hub-20261101-#{String.pad_leading("#{n}", 6, "0")}.dump.age",
            "old"
          )

    S3Fake.put_object("hub1/hub/zitadel-20261101-000001.dump.age", "zitadel")

    :ok = perform_job(HubBackupWorker, %{"actor" => "schedule"})
    [%{"id" => id}] = for j <- all_enqueued(worker: OffsiteWorker), do: j.args
    assert :ok = copy("hub", id)

    backup = Repo.get!(HubBackup.Backup, id)
    assert backup.offsite_key == "hub1/hub/#{backup.file_name}.age"

    hub_keys =
      S3Fake.objects() |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "hub1/hub/hub-"))

    assert length(hub_keys) == 14
    assert S3Fake.objects()["hub1/hub/zitadel-20261101-000001.dump.age"]
    assert [%{outcome: "ok", forum_id: nil}] = entries("hub.backup.offsite")
  end

  test "a failed upload is retried, audited only after the last attempt, and leaves nothing", %{
    forum: forum
  } do
    export = back_up(forum, 1)
    S3Fake.fail(true)

    assert {:error, {:s3_status, 500}} = copy("forum", export.id)
    assert entries("forum.backup.offsite") == []

    job =
      OffsiteWorker.new(%{"source" => "forum", "id" => export.id})
      |> Ecto.Changeset.apply_changes()

    assert {:error, _} = OffsiteWorker.perform(%{job | attempt: 3, max_attempts: 3})

    [entry] = entries("forum.backup.offsite")
    assert entry.outcome == "failed"
    assert entry.details["error"] == "the storage answered 500"
    refute Repo.get!(Export, export.id).offsite_key
    assert File.ls!(Path.dirname(Export.path(export))) == [export.file_name]
  end

  test "nothing is queued while storage is off", %{forum: forum} do
    storage(bucket: nil)
    back_up(forum, 1)
    refute_enqueued(worker: OffsiteWorker)
    assert S3Fake.requests() == []
  end

  test "a backup pruned before its turn is skipped" do
    assert :ok = copy("forum", -1)
    assert S3Fake.requests() == []
  end
end
