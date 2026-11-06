# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ID02SignupReturnTest do
  @moduledoc """
  ID-02 (steward decision 2026-11-06): someone without an Idejo ID who comes from a forum's
  "No Idejo ID yet? Create one" (Idejo 0.2.6's IDEJO_OIDC_SIGN_UP_URL) signs up on the Hub's
  page and is led back to that forum. Only a running forum's own address is ever followed.
  """
  use IdejoHubWeb.ConnCase, async: false

  alias IdejoHub.{Forums, Identity, Repo, Secrets, Settings}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Hosting.ForumContainer
  alias IdejoHub.Identity.Fake

  @moduletag req: "ID-02"

  setup %{conn: conn} do
    Fake.start()
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)
    {:ok, _} = Settings.update(%{"smtp_host" => "smtp.hub.test"}, "op")
    # An address of its own: sign-ups are limited per address (five an hour), and the other
    # sign-up tests come from 127.0.0.1.
    conn = %{
      conn
      | host: "id.idejo.test",
        remote_ip: {10, 2, 0, System.unique_integer([:positive]) |> rem(250)}
    }

    %{conn: conn, forum: forum!("su-club", "running")}
  end

  defp forum!(subdomain, status) do
    secret = fn field -> Secrets.encrypt("x", Forums.context(subdomain, field)) end

    Repo.insert!(%Forum{
      subdomain: subdomain,
      display_name: "Club #{subdomain}",
      owner_email: "o@x.test",
      idejo_version: "0.2.6",
      memory_mb: 384,
      cpus: 0.5,
      status: status,
      secret_key_base_enc: secret.(:secret_key_base),
      db_password_enc: secret.(:db_password),
      oidc_client_id: "client-#{subdomain}",
      oidc_client_secret_enc: secret.(:oidc_client_secret)
    })
  end

  test "ID-02 each forum's Create one leads to the Hub's sign-up, coming back to it", %{
    forum: forum
  } do
    {:ok, params} = Forums.container_params(forum)
    env = ForumContainer.spec(params)["Env"]

    assert "IDEJO_OIDC_SIGN_UP_URL=https://id.idejo.test/account/sign-up?return_to=https%3A%2F%2Fsu-club.idejo.test%2F" in env
  end

  test "ID-02 coming from a forum, the page names it and leads back to its sign-in", %{
    conn: conn
  } do
    page =
      conn
      |> get(~p"/account/sign-up?return_to=https://su-club.idejo.test/")
      |> html_response(200)

    assert page =~ ~s(id="signup-from")
    assert page =~ ~s(<input type="hidden" name="return_to" value="https://su-club.idejo.test/")

    sent =
      conn
      |> post(~p"/account/sign-up", %{
        "signup" => %{"email" => "new@x.test", "display_name" => "New", "username" => "new_one"},
        "return_to" => "https://su-club.idejo.test/"
      })
      |> html_response(200)

    assert sent =~ ~s(id="signup-back")
    assert sent =~ ~s(href="https://su-club.idejo.test/users/sign-in")
    assert sent =~ "Club su-club"

    # A refused form keeps it.
    again =
      conn
      |> post(~p"/account/sign-up", %{
        "signup" => %{"email" => "x"},
        "return_to" => "https://su-club.idejo.test/"
      })
      |> html_response(422)

    assert again =~ ~s(name="return_to" value="https://su-club.idejo.test/")
  end

  test "ID-02 only a running forum's own address is followed", %{conn: conn} do
    forum!("su-paused", "suspended")

    for return_to <- [
          "https://evil.example/",
          "https://su-club.idejo.test.evil.example/",
          "http://su-club.idejo.test/",
          "https://su-club.idejo.test/users/settings",
          "https://su-club.idejo.test:8443/",
          "https://su-club.idejo.test/?next=https://evil.example/",
          "https://user@su-club.idejo.test/",
          "https://su-paused.idejo.test/",
          "https://nope.idejo.test/",
          "javascript:alert(1)"
        ] do
      page = conn |> get(~p"/account/sign-up?#{%{return_to: return_to}}") |> html_response(200)
      refute page =~ "signup-from", return_to
      refute page =~ ~s(name="return_to"), return_to
    end
  end
end
