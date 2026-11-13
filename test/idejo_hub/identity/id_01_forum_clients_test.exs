# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.ID01ForumClientsTest do
  @moduledoc """
  ID-01: each forum is registered as an OpenID Connect client when created, its secret rotated
  on demand, and switched to idejo ID (idejo AC-09) through its environment. ID-07: local
  accounts per forum.
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Forums, Identity}
  alias IdejoHub.Forums.{CreateWorker, DeleteWorker, PurgeWorker, RecreateWorker}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Identity.Fake, as: FakeId

  @moduletag :capture_log

  setup do
    Fake.start()
    FakeId.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, FakeId))

    on_exit(fn ->
      Application.put_env(:idejo_hub, Identity, original)
      for s <- ["id01-a", "id01-b"], do: Postgres.drop(s)
    end)

    :ok
  end

  defp create(subdomain, extra \\ %{}) do
    {:ok, f} =
      Forums.create_forum(
        Map.merge(
          %{"subdomain" => subdomain, "display_name" => subdomain, "owner_email" => "o@x.test"},
          extra
        ),
        "op"
      )

    result = perform_job(CreateWorker, %{"forum_id" => f.id, "actor" => "op"})
    {result, Forums.get_forum!(f.id)}
  end

  defp env(subdomain) do
    Fake.state().containers["idejo-forum-#{subdomain}"]["Spec"]["Env"]
    |> Map.new(&(&1 |> String.split("=", parts: 2) |> List.to_tuple()))
  end

  defp recreate(forum, opts \\ []) do
    {:ok, f} = Forums.recreate_forum(forum, "op", opts)

    perform_job(RecreateWorker, %{
      "forum_id" => f.id,
      "actor" => "op",
      "was" => forum.status,
      "rotate_secret" => Keyword.get(opts, :rotate_secret, false)
    })
  end

  @tag req: "ID-01"
  test "ID-01 a new forum is registered at the provider and signs in through it" do
    {:ok, forum} = create("id01-a")

    assert [client] = Map.values(FakeId.clients())
    assert client.host == "id01-a.idejo.test"
    assert forum.oidc_app_id == client.app_id
    refute forum.oidc_client_secret_enc =~ client.client_secret

    env = env("id01-a")
    assert env["IDEJO_OIDC_ISSUER"] == "https://id.idejo.test"
    assert env["IDEJO_OIDC_CLIENT_ID"] == client.client_id
    assert env["IDEJO_OIDC_CLIENT_SECRET"] == client.client_secret
    assert env["IDEJO_OIDC_LABEL"] == "idejo ID"
    # idejo ID required by default (ID-07; steward decision 2026-11-06).
    assert env["IDEJO_LOCAL_ACCOUNTS"] == "off"
  end

  @tag req: "ID-01"
  test "ID-01 a failed registration fails the forum; a later failure removes the client" do
    FakeId.fail(:create_client)
    {{:error, message}, forum} = create("id01-a")
    assert message =~ "identity:"
    assert forum.status == "failed"
    refute Postgres.exists?("id01-a")

    Fake.fail(:create_container, {:denied, "test"})
    {{:error, _}, _} = create("id01-b")
    assert FakeId.clients() == %{}
  end

  @tag req: "ID-01"
  test "ID-01 rotating the secret makes the container again with the new one" do
    {:ok, forum} = create("id01-a")
    old = env("id01-a")["IDEJO_OIDC_CLIENT_SECRET"]

    {:ok, _} = Forums.rotate_identity(forum, "op")

    assert_enqueued(
      worker: RecreateWorker,
      args: %{"forum_id" => forum.id, "rotate_secret" => true}
    )

    assert :ok =
             perform_job(RecreateWorker, %{
               "forum_id" => forum.id,
               "actor" => "op",
               "was" => "running",
               "rotate_secret" => true
             })

    new = env("id01-a")["IDEJO_OIDC_CLIENT_SECRET"]
    assert new != old
    assert FakeId.clients()[forum.oidc_app_id].client_secret == new
  end

  @tag req: "ID-01"
  test "ID-01 a forum made before the provider is connected when it is made again" do
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, nil))
    {:ok, forum} = create("id01-a")
    refute Map.has_key?(env("id01-a"), "IDEJO_OIDC_ISSUER")
    assert env("id01-a")["IDEJO_LOCAL_ACCOUNTS"] == "on"

    Application.put_env(:idejo_hub, Identity, original)
    assert :ok = recreate(forum)
    assert env("id01-a")["IDEJO_OIDC_ISSUER"] == "https://id.idejo.test"
    assert Forums.get_forum!(forum.id).oidc_client_id
  end

  @tag req: "ID-01"
  test "ID-01 purging a forum removes its client" do
    {:ok, forum} = create("id01-a")

    Fake.run_result(
      ["/app/bin/idejo-admin", "backup"],
      0,
      "Backup written to /data/backups/idejo-20261104-010000.tar\n"
    )

    Fake.put_file("/data/backups/idejo-20261104-010000.tar", "x")
    {:ok, _} = Forums.delete_forum(forum, "op", immediate: true, confirm: "id01-a")

    :ok =
      perform_job(DeleteWorker, %{"forum_id" => forum.id, "actor" => "op", "immediate" => true})

    :ok = perform_job(PurgeWorker, %{"forum_id" => forum.id, "actor" => "op"})

    assert FakeId.clients() == %{}
    assert Forums.get_forum!(forum.id).oidc_client_id == nil
  end

  @tag req: "ID-07"
  test "ID-07 each forum may also allow local accounts, or idejo ID only" do
    {:ok, forum} = create("id01-a", %{"local_accounts" => "false"})
    assert env("id01-a")["IDEJO_LOCAL_ACCOUNTS"] == "off"

    {:ok, _} = Forums.set_local_accounts(Forums.get_forum!(forum.id), true, "op")

    assert :ok =
             perform_job(RecreateWorker, %{
               "forum_id" => forum.id,
               "actor" => "op",
               "was" => "running",
               "rotate_secret" => false
             })

    assert env("id01-a")["IDEJO_LOCAL_ACCOUNTS"] == "on"
  end

  @tag req: "ID-07"
  test "ID-07 new forums require an idejo ID unless the operator allows local accounts" do
    # The form's box starts unticked; a forum made without a choice requires an idejo ID.
    refute Ecto.Changeset.get_field(Forums.change_new_forum(), :local_accounts)
    {:ok, forum} = create("id01-a")
    refute forum.local_accounts

    {:ok, allowed} = create("id01-b", %{"local_accounts" => "true"})
    assert allowed.local_accounts
    assert env("id01-b")["IDEJO_LOCAL_ACCOUNTS"] == "on"
  end
end
