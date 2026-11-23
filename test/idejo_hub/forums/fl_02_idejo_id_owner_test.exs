# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.FL02IdejoIdOwnerTest do
  @moduledoc """
  FL-02 (steward request 2026-11-23): a new forum given to an existing idejo ID. Its email
  comes from the provider, verified; setup makes the owner already linked to the ID
  (`--owner-oidc-subject`, idejo AD-14), named as the ID is, with no password link.
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums, Identity}
  alias IdejoHub.Forums.{CreateWorker, Forum}
  alias IdejoHub.Hosting.Docker.Fake, as: Docker
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Identity.Fake, as: Provider
  alias IdejoHub.Identity.Profiles

  @moduletag req: "FL-02"
  @moduletag :capture_log

  @setup ["/app/bin/idejo-admin", "setup"]

  setup do
    Docker.start()
    Provider.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Provider))

    on_exit(fn ->
      Application.put_env(:idejo_hub, Identity, original)
      Postgres.drop("fl02-chess")
    end)

    {:ok, ada} = person("ada@x.test", "Ada Lovelace")
    %{ada: ada}
  end

  defp person(email, name, extra \\ %{}),
    do:
      Provider.create_person(
        Map.merge(
          %{
            email: email,
            email_verified: true,
            display_name: name,
            given_name: "Sennoma",
            family_name: "Ulo",
            language: "en"
          },
          extra
        )
      )

  defp attrs(subject, extra \\ %{}) do
    Map.merge(
      %{
        "subdomain" => "fl02-chess",
        "display_name" => "Chess Club",
        "owner_email" => "typed@elsewhere.test",
        "owner_subject" => subject,
        "idejo_version" => Forum.owner_subject_since()
      },
      extra
    )
  end

  defp owner_error(attrs) do
    assert {:error, changeset} = Forums.create_forum(attrs, "operator")
    assert %{owner_subject: [message]} = errors_on(changeset)
    refute_enqueued(worker: CreateWorker)
    message
  end

  test "the owner's email is the idejo ID's, never what the form sent", %{ada: ada} do
    assert {:ok, forum} = Forums.create_forum(attrs(ada), "operator")
    assert forum.owner_subject == ada
    assert forum.owner_email == "ada@x.test"

    assert [%{outcome: "requested", details: %{"owner_subject" => ^ada}}] =
             Audit.for_forum(forum.id)
  end

  test "an email owner stays as before: no subject" do
    assert {:ok, forum} = Forums.create_forum(attrs(" "), "operator")
    assert forum.owner_subject == nil
    assert forum.owner_email == "typed@elsewhere.test"
  end

  test "refuses an ID that cannot own a forum, and an idejo too old for it", %{ada: ada} do
    {:ok, bob} = person("bob@x.test", "Bob", %{email_verified: false})
    {:ok, eve} = person("eve@x.test", "Eve", %{state: "locked"})

    assert owner_error(attrs(bob)) =~ "has not verified their email"
    assert owner_error(attrs(eve)) =~ "is locked"
    assert owner_error(attrs("nobody")) =~ "is not an idejo ID"
    assert owner_error(attrs(ada, %{"idejo_version" => "0.3.25"})) =~ "needs idejo"

    Provider.fail(:person)
    assert owner_error(attrs(ada)) =~ "the identity provider did not answer"
  end

  test "refuses an idejo ID owner on a Hub without a provider", %{ada: ada} do
    Application.put_env(
      :idejo_hub,
      Identity,
      Keyword.put(Application.get_env(:idejo_hub, Identity), :adapter, nil)
    )

    assert owner_error(attrs(ada)) =~ "this Hub has none"
  end

  test "setup links the owner to the ID, named as the ID is, with no link", %{ada: ada} do
    {:ok, _} = Profiles.set_username(ada, "ada")
    Docker.exec_result(@setup, {:ok, %{exit_code: 0, output: "Chess Club is set up."}})

    {:ok, forum} = Forums.create_forum(attrs(ada), "operator")
    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    forum = Forums.get_forum!(forum.id)

    assert forum.status == "running"
    assert forum.owner_invite == "idejo_id"
    assert forum.owner_link_enc == nil

    assert [cmd] = for({_c, [_, "setup" | _] = cmd} <- Docker.state().execs, do: cmd)

    assert cmd == [
             "/app/bin/idejo-admin",
             "setup",
             "--name",
             "Chess Club",
             "--owner-email",
             "ada@x.test",
             "--owner-oidc-subject",
             ada,
             "--owner-name",
             "Ada Lovelace",
             "--owner-username",
             "ada"
           ]
  end

  test "without an idejo ID username, idejo makes one from the name", %{ada: ada} do
    {:ok, forum} = Forums.create_forum(attrs(ada), "operator")
    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})

    assert [cmd] = for({_c, [_, "setup" | _] = cmd} <- Docker.state().execs, do: cmd)
    assert Enum.take(cmd, -4) == ["--owner-oidc-subject", ada, "--owner-name", "Ada Lovelace"]
  end
end
