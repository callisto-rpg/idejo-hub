# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.HA05SettingsTest do
  @moduledoc "HA-05: settings: forum domain, SMTP, backup storage, alert email, reserved subdomains."
  use IdejoHubWeb.ConnCase, async: false

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Forums, Repo, Settings}
  alias IdejoHub.Forums.Mail
  alias IdejoHub.Settings.Setting

  @moduletag req: "HA-05"

  setup %{conn: conn} do
    original = Application.get_env(:idejo_hub, Mail)
    on_exit(fn -> Application.put_env(:idejo_hub, Mail, original || []) end)
    {conn, operator, _} = sign_in(conn)
    %{conn: conn, operator: operator}
  end

  defp save(view, params), do: view |> form("#settings", settings: params) |> render_submit()

  test "shows the forum domain and backup storage, set at install", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings")
    assert view |> element("#forum-domain") |> render() =~ "idejo.test"
    assert view |> element("#backup-storage") |> render() =~ "exports"
    refute has_element?(view, ~s(input[name="settings[forum_domain]"]))
  end

  test "SMTP set here replaces the environment's for forums; the password is encrypted",
       %{conn: conn, operator: op} do
    Application.put_env(:idejo_hub, Mail, shared_smtp: [host: "env.example.test"])
    {:ok, view, _} = live(conn, ~p"/settings")
    assert render(view) =~ "env.example.test"

    assert save(view, %{
             "smtp_host" => "smtp.hub.test",
             "smtp_port" => "587",
             "smtp_security" => "starttls",
             "smtp_username" => "hub",
             "smtp_password" => "s3cret"
           }) =~ "Settings saved"

    env = Mail.env("noreply@x.idejo.test")
    assert env["IDEJO_SMTP_HOST"] == "smtp.hub.test"
    assert env["IDEJO_SMTP_PASSWORD"] == "s3cret"
    refute Repo.get!(Setting, "smtp_password").value =~ "s3cret"

    # The password never goes back to the page; left empty, it stays.
    html = render(view)
    refute html =~ "s3cret"
    save(view, %{"smtp_host" => "smtp.hub.test", "smtp_password" => ""})
    assert Settings.get("smtp_password") == "s3cret"

    entry = Enum.find(Repo.all(Audit.Entry), &(&1.action == "settings.update"))
    assert entry.actor == op.email
    refute inspect(entry.details) =~ "s3cret"
  end

  test "values are checked", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings")

    html =
      save(view, %{"smtp_port" => "99999", "smtp_security" => "ssl", "alert_email" => "nope"})

    assert html =~ "must be a port number"
    assert html =~ "must be starttls, tls or none"
    assert html =~ "must be an email address"
    assert Settings.get("smtp_port") == nil
  end

  test "the alert email is stored", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings")
    save(view, %{"alert_email" => "ops@hub.test"})
    assert Settings.get("alert_email") == "ops@hub.test"
  end

  test "reserved subdomains are refused for new forums", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings")
    save(view, %{"reserved_subdomains" => "shop, Blog-2\nshop"})
    assert Settings.reserved_subdomains() == ["blog-2", "shop"]

    assert {:error, changeset} =
             Forums.create_forum(
               %{"subdomain" => "shop", "display_name" => "S", "owner_email" => "o@s.test"},
               "op"
             )

    assert %{subdomain: ["is reserved"]} = IdejoHub.DataCase.errors_on(changeset)
    assert html_response(get(conn, ~p"/settings"), 200) =~ "blog-2"
  end

  test "emptied settings are removed", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings")
    save(view, %{"alert_email" => "ops@hub.test"})
    save(view, %{"alert_email" => ""})
    assert Settings.get("alert_email") == nil
  end
end
