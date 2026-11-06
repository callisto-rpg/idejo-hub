# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP08AlertsTest do
  @moduledoc """
  OP-08: alerts by email when a forum is down for 5 minutes, a backup fails, or the disk is
  above 85%.
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn
  import Swoosh.TestAssertions

  alias IdejoHub.{Audit, Forums, Mailer, Settings}
  alias IdejoHub.Forums.CreateWorker
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Operations.{Alerts, BackupWorker, HealthWorker}

  @moduletag req: "OP-08"
  @moduletag :capture_log

  @to "alerts@hub.test"

  setup do
    Fake.start()
    health(200)
    on_exit(fn -> Postgres.drop("alert-a") end)
    {:ok, _} = Settings.update(%{"alert_email" => @to}, "op")
    %{forum: create("alert-a")}
  end

  defp health(status),
    do: Req.Test.stub(IdejoHub.Hosting.Health, fn conn -> send_resp(conn, status, "{}") end)

  defp create(subdomain) do
    {:ok, f} =
      Forums.create_forum(
        %{"subdomain" => subdomain, "display_name" => subdomain, "owner_email" => "o@x.test"},
        "op"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => f.id, "actor" => "op"})
    Forums.get_forum!(f.id)
  end

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(:second), -n * 60)

  defp subjects do
    for {:email, email} <- collected(), do: email.subject
  end

  defp collected do
    Stream.repeatedly(fn ->
      receive do
        {:email, _} = message -> message
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  describe "a forum down" do
    test "OP-08 an email after 5 minutes down, once, and one when it answers again", %{
      forum: forum
    } do
      health(503)
      :ok = perform_job(HealthWorker, %{})
      # Down for less than 5 minutes: nothing yet.
      assert_no_email_sent()

      {:ok, _} = Forums.update_state(Forums.get_forum!(forum.id), %{down_since: minutes_ago(5)})
      :ok = perform_job(HealthWorker, %{})

      assert_email_sent(fn email ->
        assert email.to == [{"", @to}]
        assert email.subject == "[Idejo Hub] alert-a.idejo.test is down"
        assert email.text_body =~ "has not answered its health check since"
        assert email.text_body =~ "/forums/#{forum.id}"
        assert email.from == {"Idejo Hub", Mailer.from_address()}
      end)

      # Still down a minute later: no second email.
      :ok = perform_job(HealthWorker, %{})
      assert subjects() == []

      health(200)
      :ok = perform_job(HealthWorker, %{})
      assert_email_sent(subject: "[Idejo Hub] alert-a.idejo.test is back up")
      assert Alerts.list_open() == []

      assert Enum.count(
               Audit.for_forum(forum.id),
               &(&1.action == "alert.email" and &1.outcome == "ok")
             ) ==
               2
    end

    test "OP-08 a forum suspended while down closes its alert without an email", %{forum: forum} do
      health(503)
      {:ok, forum} = Forums.update_state(forum, %{health: "down", down_since: minutes_ago(6)})
      :ok = Alerts.check_forums()
      assert_email_sent(subject: "[Idejo Hub] alert-a.idejo.test is down")

      {:ok, _} = Forums.update_state(forum, %{status: "suspended"})
      :ok = Alerts.check_forums()
      assert_no_email_sent()
      assert Alerts.list_open() == []
    end
  end

  describe "the disk" do
    test "OP-08 above 85% sends one email; under 80% the all clear" do
      gib = 1_073_741_824
      :ok = Alerts.check_disk(%{used: 86 * gib, available: 14 * gib})
      assert_email_sent(subject: "[Idejo Hub] The server's disk is 86% full")

      # Still high, then between 80% and 85%: nothing new.
      :ok = Alerts.check_disk(%{used: 90 * gib, available: 10 * gib})
      :ok = Alerts.check_disk(%{used: 83 * gib, available: 17 * gib})
      assert subjects() == []
      assert [%{key: "disk"}] = Alerts.list_open()

      :ok = Alerts.check_disk(%{used: 79 * gib, available: 21 * gib})
      assert_email_sent(subject: "[Idejo Hub] The server's disk is below 80% again")
      assert Alerts.list_open() == []

      # A reading that fails changes nothing.
      :ok = Alerts.check_disk(:unavailable)
      assert_no_email_sent()
    end
  end

  describe "a backup" do
    test "OP-08 a forum's failed backup sends an email", %{forum: forum} do
      Fake.exec_result(
        ["/app/bin/idejo-admin", "backup"],
        {:ok, %{exit_code: 1, output: "disk full"}}
      )

      {:ok, _} = Forums.update_state(forum, %{step: "backing_up"})

      assert {:error, _} =
               perform_job(BackupWorker, %{"forum_id" => forum.id, "actor" => "schedule"})

      assert_email_sent(fn email ->
        assert email.subject == "[Idejo Hub] Backup failed: alert-a.idejo.test"
        assert email.text_body =~ "failed at"
      end)
    end

    test "OP-08 the Hub's own failed backup sends an email" do
      :ok = Alerts.backup_failed("the Hub", nil, "pg_dump: connection refused")

      assert_email_sent(fn email ->
        assert email.subject == "[Idejo Hub] Backup failed: the Hub"
        assert email.text_body =~ "pg_dump: connection refused"
        assert email.text_body =~ "/server"
      end)
    end
  end

  describe "without an alert address" do
    test "OP-08 nothing is sent; the audit log says why" do
      {:ok, _} = Settings.update(%{"alert_email" => ""}, "op")
      :ok = Alerts.backup_failed("the Hub", nil, "boom")
      assert_no_email_sent()

      assert %{outcome: "failed", details: %{"error" => "no alert email set (Settings)"}} =
               IdejoHub.Repo.get_by!(IdejoHub.Audit.Entry, action: "alert.email")
    end
  end

  describe "the SMTP connection" do
    test "OP-08 follows the shared SMTP settings, as Idejo does (465 is TLS, else STARTTLS)" do
      starttls =
        Mailer.gen_smtp(%{host: "smtp.hub.test", port: nil, username: "u", password: "p"})

      assert starttls[:relay] == "smtp.hub.test" and starttls[:port] == 587
      assert starttls[:tls] == :always and starttls[:ssl] == false
      assert starttls[:auth] == :always and starttls[:username] == "u"
      assert starttls[:tls_options][:verify] == :verify_peer

      tls = Mailer.gen_smtp(%{host: "smtp.hub.test", port: "465"})
      assert tls[:ssl] == true and tls[:tls] == :never and tls[:auth] == :never
      # Without a username, no credentials at all (Swoosh refuses an empty username key).
      refute Keyword.has_key?(tls, :username)

      plain = Mailer.gen_smtp(%{host: "relay.local", port: 25, security: "none"})
      assert plain[:port] == 25 and plain[:ssl] == false and plain[:tls] == :never
    end
  end
end
