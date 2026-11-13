# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.IdentityProfileTest do
  @moduledoc """
  An idejo ID's public username and picture (steward decisions 2026-11-06): forums the person
  signed in to read them and fill what is missing; the member changes them on their page.
  """
  use IdejoHubWeb.ConnCase, async: false

  alias IdejoHub.{Forums, Identity, Repo, Secrets}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Identity.{Fake, Join, OutsideForum, Profiles}

  # A tiny WebP: the RIFF header idejo's avatars start with.
  @webp <<"RIFF", 30::little-32, "WEBPVP8L", 17::little-32, 0::size(17 * 8), 0>>

  setup do
    Fake.start()
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)

    forum =
      Repo.insert!(%Forum{
        subdomain: "prof-club",
        display_name: "Club",
        owner_email: "o@x.test",
        idejo_version: "0.2.9",
        memory_mb: 384,
        cpus: 0.5,
        status: "running",
        oidc_client_id: "client-prof",
        secret_key_base_enc: Secrets.encrypt("k", Forums.context("prof-club", :secret_key_base)),
        db_password_enc: Secrets.encrypt("pw", Forums.context("prof-club", :db_password)),
        oidc_client_secret_enc:
          Secrets.encrypt("secret-prof", Forums.context("prof-club", :oidc_client_secret))
      })

    now = DateTime.utc_now(:second)

    Repo.insert!(
      Join.changeset(%Join{}, %{
        subject: "ada",
        forum_id: forum.id,
        state: "joined",
        first_at: now,
        last_at: now
      })
    )

    %{forum: forum}
  end

  defp hosted(method, params, secret \\ "secret-prof") do
    conn =
      build_conn()
      |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("client-prof", secret))

    case method do
      :get -> get(conn, "/internal/community/profile", params)
      :post -> post(conn, "/internal/community/profile", params)
    end
  end

  test "a forum fills only what the idejo ID lacks, and reads it back" do
    assert json_response(hosted(:get, %{"subject" => "ada"}), 200) ==
             %{"username" => nil, "picture" => nil}

    filled =
      hosted(:post, %{
        "subject" => "ada",
        "username" => "Ada_L",
        "picture" => Base.encode64(@webp)
      })
      |> json_response(200)

    assert filled["username"] == "Ada_L"
    assert "https://id.idejo.test/account/pictures/" <> file = filled["picture"]

    # A later link never overwrites.
    again =
      hosted(:post, %{
        "subject" => "ada",
        "username" => "Other",
        "picture" => Base.encode64(@webp)
      })
      |> json_response(200)

    assert again == filled

    # The picture is public, as WebP, cached for good.
    picture = get(%{build_conn() | host: "id.idejo.test"}, "/account/pictures/" <> file)
    assert picture.status == 200
    assert picture.resp_body == @webp
    assert get_resp_header(picture, "content-type") == ["image/webp"]
    assert get_resp_header(picture, "x-content-type-options") == ["nosniff"]

    assert get(%{build_conn() | host: "id.idejo.test"}, "/account/pictures/nope.webp").status ==
             404
  end

  test "not WebP, a bad username or one taken: skipped" do
    {:ok, _} = Profiles.set_username("bea", "Ada_L")

    filled =
      hosted(:post, %{
        "subject" => "ada",
        "username" => "ada_l",
        "picture" => Base.encode64("<svg/>")
      })
      |> json_response(200)

    assert filled == %{"username" => nil, "picture" => nil}

    assert hosted(:post, %{"subject" => "ada", "username" => "a@b.c"}) |> json_response(200) ==
             %{"username" => nil, "picture" => nil}
  end

  test "only for someone who signed in to that forum, with its own secret" do
    assert hosted(:get, %{"subject" => "bea"}).status == 401
    assert hosted(:get, %{"subject" => "ada"}, "wrong").status == 401
    assert hosted(:post, %{"subject" => "bea", "username" => "Bea"}).status == 401
    assert Profiles.get("bea").username == nil
  end

  test "an outside forum, at /account/api/profile, for someone who signed in there" do
    secret = "outside-secret"

    outside =
      Repo.insert!(%OutsideForum{
        host: "club.example.org",
        display_name: "Out",
        status: "registered",
        client_id: "client-out",
        secret_hash: :crypto.hash(:sha256, secret)
      })

    Repo.insert_all("outside_joins", [
      %{subject: "ada", outside_forum_id: outside.id, first_at: DateTime.utc_now(:second)}
    ])

    ask = fn subject ->
      %{build_conn() | host: "id.idejo.test"}
      |> put_req_header("authorization", Plug.BasicAuth.encode_basic_auth("client-out", secret))
      |> put_req_header("accept", "application/json")
      |> post("/account/api/profile", %{"subject" => subject, "username" => "Ada_Out"})
    end

    assert json_response(ask.("ada"), 200)["username"] == "Ada_Out"
    assert ask.("bea").status == 401
  end

  test "the member sees, renames and removes on their page" do
    {:ok, _} = Profiles.set_username("ada", "Ada_L")
    {:ok, _} = Profiles.set_picture("ada", @webp)
    {:ok, _} = Profiles.set_username("bea", "Taken")

    conn =
      %{build_conn() | host: "id.idejo.test"}
      |> init_test_session(%{"member" => %{"sub" => "ada", "at" => System.system_time(:second)}})

    html = conn |> get(~p"/account") |> html_response(200)
    assert html =~ ~s(id="account-picture")
    assert html =~ ~s(value="Ada_L")

    conn = Plug.Conn.put_private(conn, :plug_skip_csrf_protection, true)

    assert redirected_to(
             post(conn, ~p"/account/profile", %{"profile" => %{"username" => "taken"}})
           ) == "/account"

    assert Profiles.get("ada").username == "Ada_L"

    post(conn, ~p"/account/profile", %{"profile" => %{"username" => "Ada_Lovelace"}})
    assert Profiles.get("ada").username == "Ada_Lovelace"

    post(conn, ~p"/account/profile/picture", %{})
    assert Profiles.get("ada").picture_key == nil
  end

  test "a first sign-in at an outside forum is found when it asks" do
    secret = "s2"

    Repo.insert!(%OutsideForum{
      host: "fresh.example.org",
      display_name: "Fresh",
      status: "registered",
      client_id: "client-fresh",
      secret_hash: :crypto.hash(:sha256, secret)
    })

    # Signed in moments ago: not synced yet, read again when the forum asks.
    Fake.sign_in("cy", "client-fresh")
    assert IdejoHub.Community.member_of_client?("client-fresh", secret, "cy")
    refute IdejoHub.Community.member_of_client?("client-fresh", secret, "dan")
  end
end
