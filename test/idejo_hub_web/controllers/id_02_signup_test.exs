# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ID02SignupTest do
  @moduledoc """
  ID-02: sign-up on the Hub's own page (steward decision 2026-11-04): email and display name;
  first and last name optional, "Sennoma" and "Ulo" otherwise; the provider emails the link.
  """
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  alias IdejoHub.{Identity, Settings}
  alias IdejoHub.Identity.{Fake, Profiles, SetupWorker}

  @moduletag req: "ID-02"

  setup %{conn: conn} do
    Fake.start()
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)
    {:ok, _} = Settings.update(%{"smtp_host" => "smtp.hub.test"}, "op")
    %{conn: %{conn | host: "id.idejo.test"}}
  end

  # A username of its own unless the test gives one (they are unique among idejo IDs).
  defp sign_up(conn, params) do
    params = Map.put_new(params, "username", "user_#{System.unique_integer([:positive])}")
    post(conn, ~p"/account/sign-up", %{"signup" => params})
  end

  test "ID-02 the page is on the identity host only", %{conn: conn} do
    assert html_response(get(conn, ~p"/account/sign-up"), 200) =~ "Create your idejo ID"
    assert get(%{build_conn() | host: "hub.idejo.test"}, ~p"/account/sign-up").status == 404
  end

  test "ID-02 email and display name are enough; Zitadel gets Sennoma Ulo", %{conn: conn} do
    html =
      html_response(sign_up(conn, %{"email" => "Ana@Example.test", "display_name" => "Ana"}), 200)

    assert html =~ "Check your email"

    assert [{id, person}] = Map.to_list(Fake.people())
    assert person.email == "ana@example.test"
    assert person.display_name == "Ana"
    assert {person.given_name, person.family_name} == {"Sennoma", "Ulo"}
    assert Fake.invites() == [id]
  end

  test "ID-02 first and last name, when given, are used", %{conn: conn} do
    sign_up(conn, %{
      "email" => "b@x.test",
      "display_name" => "Bea",
      "given_name" => "Beatrix",
      "family_name" => "Kiddo"
    })

    assert [%{given_name: "Beatrix", family_name: "Kiddo"}] = Map.values(Fake.people())
  end

  test "ID-02 the names are behind a checkbox, and nothing needs JavaScript", %{conn: conn} do
    html = html_response(get(conn, ~p"/account/sign-up"), 200)
    assert html =~ ~s(id="signup-names-toggle")
    assert html =~ "hidden peer-checked:block"
    refute html =~ "<script>"
  end

  test "ID-02 required fields and an email already used", %{conn: conn} do
    html =
      html_response(
        sign_up(conn, %{"email" => "nope", "display_name" => "", "username" => "a@b.c"}),
        422
      )

    assert html =~ "Give your email address."
    assert html =~ "Choose a username"
    assert html =~ "Give the name people see"
    assert Fake.people() == %{}

    sign_up(conn, %{"email" => "c@x.test", "display_name" => "C"})

    assert html_response(sign_up(conn, %{"email" => "c@x.test", "display_name" => "C2"}), 422) =~
             "already uses this email"
  end

  test "ID-02 five sign-ups an hour from one address", %{conn: conn} do
    conn =
      Plug.Conn.put_req_header(
        conn,
        "x-forwarded-for",
        "203.0.113.#{System.unique_integer([:positive]) |> rem(250)}"
      )

    for n <- 1..5,
        do:
          assert(sign_up(conn, %{"email" => "r#{n}@x.test", "display_name" => "R"}).status == 200)

    assert sign_up(conn, %{"email" => "r6@x.test", "display_name" => "R"}).status == 429
  end

  test "ID-02 closed while the server cannot send email", %{conn: conn} do
    {:ok, _} = Settings.update(%{"smtp_host" => ""}, "op")
    Application.put_env(:idejo_hub, IdejoHub.Forums.Mail, shared_smtp: nil)
    assert html_response(get(conn, ~p"/account/sign-up"), 200) =~ "Sign-up is not open yet"
    assert sign_up(conn, %{"email" => "d@x.test", "display_name" => "D"}).status == 503
    assert Fake.people() == %{}
  end

  @tag req: "ID-08"
  test "ID-08 the provider is configured with the Hub's SMTP, after a change too" do
    assert_enqueued(worker: SetupWorker)
    assert :ok = perform_job(SetupWorker, %{})
    # The Hub's one sender (steward request 2026-11-06).
    sender = IdejoHub.Settings.sender()
    assert [{smtp, ^sender}] = Fake.configured()
    assert smtp[:host] == "smtp.hub.test"
  end

  test "ID-02 the username chosen is the idejo ID's public name; never twice, never an email", %{
    conn: conn
  } do
    # An address of its own: sign-ups are limited per address.
    conn = %{conn | remote_ip: {10, 3, 0, 7}}

    html_response(
      sign_up(conn, %{"email" => "u1@x.test", "display_name" => "U", "username" => "Ada_L"}),
      200
    )

    [user_id] = Map.keys(Fake.people())
    assert Profiles.get(user_id).username == "Ada_L"
    # Zitadel's own username stays the email, for signing in.
    refute Fake.people()[user_id] |> Map.get(:username) == "Ada_L"

    assert html_response(
             sign_up(conn, %{"email" => "u2@x.test", "display_name" => "U", "username" => "ada_l"}),
             422
           ) =~ "Another idejo ID already has that username."
  end
end
