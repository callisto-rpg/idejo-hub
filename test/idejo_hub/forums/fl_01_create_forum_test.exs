# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.FL01CreateForumTest do
  @moduledoc """
  FL-01: creating a forum: database and role (real PostgreSQL), secrets, container (fake
  Docker), health, headless setup, and full clean-up when a step fails.
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums, Secrets}
  alias IdejoHub.Forums.CreateWorker
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres

  @moduletag req: "FL-01"
  @moduletag :capture_log

  @subdomains ["fl01-tennis", "fl01-chess", "fl01-clash"]

  setup do
    Fake.start()
    healthy(200)

    on_exit(fn ->
      for subdomain <- @subdomains, do: Postgres.drop(subdomain)
    end)

    :ok
  end

  defp healthy(status) do
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, status, "{}") end)
  end

  defp attrs(subdomain \\ "fl01-tennis") do
    %{
      "subdomain" => subdomain,
      "display_name" => "Tennis Club",
      "owner_email" => "owner@tennis.idejo.test"
    }
  end

  defp create_and_run(subdomain \\ "fl01-tennis") do
    {:ok, forum} = Forums.create_forum(attrs(subdomain), "operator")
    result = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    {result, Forums.get_forum!(forum.id)}
  end

  describe "create_forum/2" do
    test "records the forum as creating, with an encrypted SECRET_KEY_BASE, and queues the job" do
      assert {:ok, forum} = Forums.create_forum(attrs(), "operator")
      assert forum.status == "creating"
      assert forum.idejo_version == "0.1.0"
      assert forum.memory_mb == 384

      assert {:ok, secret_key_base} = Forums.secret(forum, :secret_key_base)
      assert String.length(secret_key_base) >= 64
      refute forum.secret_key_base_enc =~ secret_key_base

      assert_enqueued(worker: CreateWorker, args: %{"forum_id" => forum.id}, queue: :lifecycle)

      assert [%{action: "forum.create", outcome: "requested", actor: "operator"}] =
               Audit.for_forum(forum.id)
    end

    test "checks the subdomain (FL-03), email and version, and refuses a used subdomain" do
      assert {:error, changeset} =
               Forums.create_forum(%{attrs() | "subdomain" => "www"}, "operator")

      assert %{subdomain: ["is reserved"]} = errors_on(changeset)

      assert {:error, changeset} =
               Forums.create_forum(%{attrs() | "owner_email" => "nope"}, "operator")

      assert %{owner_email: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Forums.create_forum(Map.put(attrs(), "idejo_version", "latest"), "operator")

      assert %{idejo_version: [_]} = errors_on(changeset)

      {:ok, _} = Forums.create_forum(attrs(), "operator")
      assert {:error, changeset} = Forums.create_forum(attrs(), "operator")
      assert %{subdomain: ["is already used by another forum"]} = errors_on(changeset)
      refute_enqueued(worker: CreateWorker, args: %{"forum_id" => nil})
    end

    test "nothing is recorded or queued for an invalid request" do
      {:error, _} = Forums.create_forum(%{attrs() | "subdomain" => "ab"}, "operator")
      assert Forums.list_forums() == []
      refute_enqueued(worker: CreateWorker)
    end
  end

  describe "the creation job" do
    test "creates the database, the container with the forum's environment, and runs setup" do
      Fake.exec_result(
        ["/app/bin/idejo-admin", "setup"],
        {:ok, %{exit_code: 0, output: "set up"}}
      )

      assert {:ok, forum} = create_and_run()
      assert forum.status == "running"
      assert forum.step == nil

      assert Postgres.exists?("fl01-tennis")
      {:ok, db_password} = Forums.secret(forum, :db_password)

      state = Fake.state()
      container = state.containers["idejo-forum-fl01-tennis"]
      assert container["Running"]
      env = container["Spec"]["Env"]
      assert "PHX_HOST=fl01-tennis.idejo.test" in env
      assert "DATABASE_URL=ecto://forum_fl01_tennis:#{db_password}@db/forum_fl01_tennis" in env
      assert "IDEJO_SOURCE_URL=https://github.com/callisto-rpg/Idejo/tree/v0.1.0" in env
      {:ok, secret_key_base} = Forums.secret(forum, :secret_key_base)
      assert "SECRET_KEY_BASE=#{secret_key_base}" in env

      assert [
               :pull_image,
               :create_volume,
               :create_volume,
               :create_container,
               :start_container,
               :exec
             ] =
               state.calls

      assert [%{outcome: "requested"}, %{outcome: "ok"}] = Audit.for_forum(forum.id)
    end

    test "a forum that never becomes healthy is removed completely" do
      healthy(503)
      {{:error, message}, forum} = create_and_run()

      assert message == "health: no healthy answer in time"
      assert forum.status == "failed"
      assert forum.error == "health: no healthy answer in time"

      state = Fake.state()
      assert state.containers == %{}
      assert state.volumes == %{}
      refute Postgres.exists?("fl01-tennis")

      assert [_requested, %{outcome: "failed", details: %{"step" => "health"}}] =
               Audit.for_forum(forum.id)
    end

    test "a failed setup is removed completely" do
      Fake.exec_result(
        ["/app/bin/idejo-admin", "setup"],
        {:ok, %{exit_code: 1, output: "already set up"}}
      )

      {{:error, _}, forum} = create_and_run("fl01-chess")

      assert forum.error == "setup: idejo-admin setup exited with 1"
      assert Fake.state().containers == %{}
      refute Postgres.exists?("fl01-chess")
    end

    test "a refused container leaves no database behind" do
      Fake.fail(:create_container, {:denied, "docker-guard: denied (image)"})
      {{:error, _}, forum} = create_and_run()

      assert forum.error =~ "container: refused by docker-guard"
      assert Fake.state().volumes == %{}
      refute Postgres.exists?("fl01-tennis")
    end

    test "a database that already existed is never dropped" do
      {:ok, _creds} = Postgres.provision("fl01-clash")
      {{:error, _}, forum} = create_and_run("fl01-clash")

      assert forum.status == "failed"
      assert forum.error =~ "database: PostgreSQL:"
      assert Postgres.exists?("fl01-clash")
      assert Fake.state().calls == []
    end

    test "no secret reaches the forum row's error or the audit log" do
      healthy(503)
      {_, forum} = create_and_run()
      {:ok, secret_key_base} = Forums.secret(forum, :secret_key_base)

      for entry <- Audit.for_forum(forum.id) do
        refute inspect(entry.details) =~ secret_key_base
      end

      refute forum.error =~ secret_key_base
      refute inspect(forum) =~ secret_key_base
    end
  end

  test "secrets are bound to their forum (SC-04)" do
    {:ok, a} = Forums.create_forum(attrs("fl01-tennis"), "operator")
    {:ok, b} = Forums.create_forum(attrs("fl01-chess"), "operator")

    assert Secrets.decrypt(a.secret_key_base_enc, Forums.context(b.subdomain, :secret_key_base)) ==
             {:error, :invalid}
  end
end
