# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.HN07FL02MailTest do
  @moduledoc """
  HN-07: each forum's sender and the shared SMTP. FL-02: the owner's invite, emailed by the
  forum, or kept for the operator to hand over once.
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.{CreateWorker, Mail}
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres

  @moduletag :capture_log

  @setup ["/app/bin/idejo-admin", "setup"]

  setup do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, 200, "{}") end)
    original = Application.get_env(:idejo_hub, Mail)

    on_exit(fn ->
      Application.put_env(:idejo_hub, Mail, original || [])
      for s <- ["mail-tennis", "mail-chess"], do: Postgres.drop(s)
    end)

    :ok
  end

  defp create(subdomain, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          "subdomain" => subdomain,
          "display_name" => "Tennis",
          "owner_email" => "owner@example.test"
        },
        extra
      )

    {:ok, forum} = Forums.create_forum(attrs, "operator")
    perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    Forums.get_forum!(forum.id)
  end

  defp env, do: Fake.state().containers |> Map.values() |> hd() |> get_in(["Spec", "Env"])

  describe "HN-07" do
    @tag req: "HN-07"
    test "each forum sends from its own address, by default noreply@<host>" do
      Fake.exec_result(
        @setup,
        {:ok, %{exit_code: 0, output: "An email … went to owner@example.test"}}
      )

      forum = create("mail-tennis")
      assert forum.mail_from == "noreply@mail-tennis.idejo.test"
      assert "IDEJO_SMTP_FROM=noreply@mail-tennis.idejo.test" in env()
      refute Enum.any?(env(), &String.starts_with?(&1, "IDEJO_SMTP_HOST="))
    end

    @tag req: "HN-07"
    test "the operator may give another sender address" do
      forum = create("mail-tennis", %{"mail_from" => "club@tennis.example"})
      assert "IDEJO_SMTP_FROM=club@tennis.example" in env()
      assert forum.mail_from == "club@tennis.example"

      {:error, changeset} =
        Forums.create_forum(
          %{
            "subdomain" => "mail-chess",
            "display_name" => "C",
            "owner_email" => "o@x.test",
            "mail_from" => "Club <a@b.c>"
          },
          "operator"
        )

      assert %{mail_from: [_]} = errors_on(changeset)
    end

    @tag req: "HN-07"
    test "a shared SMTP server set on the Hub reaches every forum" do
      Application.put_env(:idejo_hub, Mail,
        shared_smtp: [
          host: "smtp.example.test",
          port: "587",
          security: "starttls",
          username: "hub",
          password: "pw"
        ]
      )

      assert Mail.shared?()
      create("mail-tennis")

      for var <-
            ~w(IDEJO_SMTP_HOST=smtp.example.test IDEJO_SMTP_PORT=587 IDEJO_SMTP_SECURITY=starttls
                    IDEJO_SMTP_USERNAME=hub IDEJO_SMTP_PASSWORD=pw) do
        assert var in env(), var
      end
    end

    @tag req: "HN-07"
    test "empty shared settings are left out, so Idejo's defaults apply" do
      Application.put_env(:idejo_hub, Mail,
        shared_smtp: [host: "smtp.example.test", port: "", security: ""]
      )

      assert Mail.env("a@b.c") == %{
               "IDEJO_SMTP_HOST" => "smtp.example.test",
               "IDEJO_SMTP_FROM" => "a@b.c"
             }
    end
  end

  describe "FL-02" do
    @tag req: "FL-02"
    test "setup runs with the owner's email, never the operator's" do
      create("mail-tennis")

      assert [{"idejo-forum-mail-tennis", cmd}] = Fake.state().execs

      assert cmd == [
               "/app/bin/idejo-admin",
               "setup",
               "--name",
               "Tennis",
               "--owner-email",
               "owner@example.test"
             ]
    end

    @tag req: "FL-02"
    test "when the forum emailed the owner, nothing is kept" do
      Fake.exec_result(
        @setup,
        {:ok, %{exit_code: 0, output: "An email with a link went to owner@example.test"}}
      )

      forum = create("mail-tennis")
      assert forum.owner_invite == "emailed"
      assert forum.owner_link_enc == nil
      assert Forums.take_owner_link(forum, "operator") == {:error, :none}
    end

    @tag req: "FL-02"
    test "when it could not, the link is kept encrypted and handed over once, audited" do
      link = "https://mail-tennis.idejo.test/users/reset-password/AbC_12-x"

      output = """
      Tennis is set up. Its owner is owner@example.test (username owner).
      The email with their link could not be sent (no SMTP server).
      Give them this link to choose a password; it works once, for 7 days:

          #{link}
      """

      Fake.exec_result(@setup, {:ok, %{exit_code: 0, output: output}})
      forum = create("mail-tennis")

      assert forum.status == "running"
      assert forum.owner_invite == "operator"
      refute forum.owner_link_enc =~ "reset-password"

      assert Forums.take_owner_link(forum, "operator") == {:ok, link}
      forum = Forums.get_forum!(forum.id)
      assert forum.owner_link_enc == nil
      assert Forums.take_owner_link(forum, "operator") == {:error, :none}

      actions = for e <- Audit.for_forum(forum.id), do: {e.action, e.outcome}
      assert {"forum.owner_link.take", "ok"} in actions
      refute Enum.any?(Audit.for_forum(forum.id), &(inspect(&1.details) =~ "reset-password"))
    end

    @tag req: "FL-02"
    test "only a link to the forum's own address is taken" do
      output = "    https://evil.example/users/reset-password/abc\n"
      Fake.exec_result(@setup, {:ok, %{exit_code: 0, output: output}})
      forum = create("mail-tennis")
      assert forum.owner_invite == "emailed"
      assert forum.owner_link_enc == nil
    end
  end
end
