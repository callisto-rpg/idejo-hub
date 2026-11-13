# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.ID05MembersTest do
  @moduledoc """
  ID-05: the forums an idejo ID has joined (from the provider's sign-ins, never a forum's
  database), and leaving one: keeping the account (`idejo-admin leave`) or deleting it
  (`delete-account`). ID-06: deleting the identity deletes every forum account, then the
  person at the provider; a forum's last owner stops it.
  """
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums, Identity, Repo}
  alias IdejoHub.Forums.CreateWorker
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Identity.Fake, as: FakeId
  alias IdejoHub.Identity.{Join, Members, MemberWorker}

  @moduletag :capture_log
  @admin "/app/bin/idejo-admin"

  setup do
    Fake.start()
    FakeId.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, FakeId))

    on_exit(fn ->
      Application.put_env(:idejo_hub, Identity, original)
      for s <- ["id05-a", "id05-b"], do: Postgres.drop(s)
    end)

    {:ok, a} = forum("id05-a")
    {:ok, b} = forum("id05-b")

    {:ok, ada} =
      FakeId.create_person(%{
        email: "ada@x.test",
        display_name: "Ada",
        given_name: "Sennoma",
        family_name: "Ulo",
        language: "en"
      })

    %{a: a, b: b, ada: ada}
  end

  defp forum(subdomain) do
    {:ok, f} =
      Forums.create_forum(
        %{
          "subdomain" => subdomain,
          "display_name" => "Club " <> subdomain,
          "owner_email" => "o@x.test"
        },
        "op"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => f.id, "actor" => "op"})
    {:ok, Forums.get_forum!(f.id)}
  end

  defp execs(subdomain) do
    for {"idejo-forum-" <> ^subdomain, [@admin, cmd | args]} <- Fake.state().execs,
        cmd in ["leave", "delete-account"],
        do: [cmd | args]
  end

  defp run_jobs, do: Oban.drain_queue(queue: :operations, with_recursion: true)

  @tag req: "ID-05"
  test "ID-05 forums joined come from the provider's sign-ins; others are not listed", ctx do
    FakeId.sign_in(ctx.ada, ctx.a.oidc_client_id)
    FakeId.sign_in(ctx.ada, ctx.a.oidc_client_id)
    FakeId.sign_in("someone-else", ctx.b.oidc_client_id)
    FakeId.sign_in(ctx.ada, "the-hubs-own-client")
    :ok = Members.sync()

    assert [%Join{state: "joined", forum: %{subdomain: "id05-a"}}] = Members.forums_of(ctx.ada)
    # Read once: the next sync starts where this one stopped.
    assert Members.state().events_since
  end

  @tag req: "ID-05"
  test "ID-05 leaving keeps the account; signing in again joins again", ctx do
    FakeId.sign_in(ctx.ada, ctx.a.oidc_client_id)
    :ok = Members.sync()

    assert {:ok, %Join{state: "leaving"}} = Members.leave(ctx.ada, ctx.a.id, :leave)
    run_jobs()
    assert execs("id05-a") == [["leave", "--oidc-subject", ctx.ada]]
    assert [%Join{state: "left"} = join] = Members.forums_of(ctx.ada)

    assert Repo.get_by(Audit.Entry,
             action: "identity.forum_leave",
             outcome: "ok",
             actor: "member:" <> ctx.ada
           )

    Process.sleep(1100)
    FakeId.sign_in(ctx.ada, ctx.a.oidc_client_id)
    :ok = Members.sync()
    assert Repo.reload!(join).state == "joined"
  end

  @tag req: "ID-05"
  test "ID-05 deleting the account on one forum leaves the other; the last owner is refused",
       ctx do
    for f <- [ctx.a, ctx.b], do: FakeId.sign_in(ctx.ada, f.oidc_client_id)
    :ok = Members.sync()

    {:ok, _} = Members.leave(ctx.ada, ctx.a.id, :delete)
    run_jobs()
    assert execs("id05-a") == [["delete-account", "--oidc-subject", ctx.ada]]
    assert execs("id05-b") == []

    states = Map.new(Members.forums_of(ctx.ada), &{&1.forum.subdomain, &1.state})
    assert states == %{"id05-a" => "deleted", "id05-b" => "joined"}

    Fake.exec_result(
      [@admin, "delete-account"],
      {:ok,
       %{
         exit_code: 1,
         output:
           "That account is the server's last owner: give another account the owner role first.\n"
       }}
    )

    {:ok, _} = Members.leave(ctx.ada, ctx.b.id, :delete)
    run_jobs()
    assert %Join{state: "joined", error: "last_owner"} = Repo.get_by!(Join, forum_id: ctx.b.id)
  end

  @tag req: "ID-05"
  test "ID-05 a suspended forum is left through a one-off container; a busy one waits", ctx do
    FakeId.sign_in(ctx.ada, ctx.a.oidc_client_id)
    :ok = Members.sync()
    {:ok, a} = Forums.update_state(ctx.a, %{status: "suspended"})
    Fake.run_result([@admin, "leave"], 0, "Left\n")

    {:ok, join} = Members.leave(ctx.ada, a.id, :leave)
    assert {:ok, %Join{state: "left"}} = Members.run(join, :leave)

    # Not exec'd in the stopped container: a one-off ran it and is gone again.
    assert execs("id05-a") == []

    refute Map.has_key?(Fake.state().containers, "idejo-forum-id05-a-identity")

    {:ok, _} = Forums.update_state(a, %{status: "running", step: "upgrade"})
    {:ok, join} = join |> Join.changeset(%{state: "deleting"}) |> Repo.update()
    assert {:snooze, _} = Members.run(join, :delete)
  end

  @tag req: "ID-06"
  test "ID-06 deleting the identity deletes every forum account, then the person", ctx do
    for f <- [ctx.a, ctx.b], do: FakeId.sign_in(ctx.ada, f.oidc_client_id)
    :ok = Members.sync()

    assert {:ok, _} = Members.delete_identity(ctx.ada)
    assert {:error, :deleting} = Members.delete_identity(ctx.ada)
    assert {:error, :deleting} = Members.leave(ctx.ada, ctx.a.id, :leave)
    assert Members.deleting?(ctx.ada)
    run_jobs()

    for s <- ["id05-a", "id05-b"],
        do: assert(execs(s) == [["delete-account", "--oidc-subject", ctx.ada]])

    assert FakeId.deleted() == [ctx.ada]
    assert Members.deletion(ctx.ada).finished_at
    assert Enum.all?(Members.forums_of(ctx.ada), &(&1.state == "deleted"))
    assert Repo.get_by(Audit.Entry, action: "identity.delete", outcome: "ok")
  end

  @tag req: "ID-06"
  test "ID-06 a forum that refuses (its last owner) stops the deletion; the identity stays",
       ctx do
    for f <- [ctx.a, ctx.b], do: FakeId.sign_in(ctx.ada, f.oidc_client_id)
    :ok = Members.sync()

    Fake.exec_result(
      [@admin, "delete-account"],
      {:ok, %{exit_code: 1, output: "That account is the server's last owner.\n"}}
    )

    {:ok, _} = Members.delete_identity(ctx.ada)
    run_jobs()
    assert FakeId.deleted() == []
    assert Members.deletion(ctx.ada).error =~ "last_owner"
    refute Members.deleting?(ctx.ada)

    # Dealt with, asked again: it starts over.
    Fake.exec_result([@admin, "delete-account"], {:ok, %{exit_code: 0, output: ""}})
    {:ok, _} = Members.delete_identity(ctx.ada)
    run_jobs()
    assert FakeId.deleted() == [ctx.ada]
  end

  @tag req: "ID-06"
  test "ID-06 the only idejo-admin commands for members are leave and delete-account by subject",
       ctx do
    FakeId.sign_in(ctx.ada, ctx.a.oidc_client_id)
    :ok = Members.sync()
    {:ok, _} = Members.delete_identity(ctx.ada)
    assert_enqueued(worker: MemberWorker, args: %{"subject" => ctx.ada, "choice" => "identity"})
  end
end
