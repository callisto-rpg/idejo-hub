# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ID05AccountTest do
  @moduledoc """
  ID-05, ID-06: the member's page at `https://<id host>/account`, signed in through the
  provider (code flow, PKCE, state, nonce; the ID token's claims checked).
  """
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  alias IdejoHub.{Forums, Identity, Repo}
  alias IdejoHub.Identity.Fake
  alias IdejoHub.Identity.{Join, Members, MemberWorker}

  @moduletag :capture_log

  setup %{conn: conn} do
    Fake.start()
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)
    :ok = Members.ensure_account_client()
    {:ok, {client_id, _}} = Members.account_client()

    {:ok, ada} =
      Fake.create_person(%{
        email: "ada@x.test",
        display_name: "Ada",
        given_name: "Sennoma",
        family_name: "Ulo",
        language: "en"
      })

    %{conn: %{conn | host: "id.idejo.test"}, client_id: client_id, ada: ada}
  end

  # Through the provider and back; `claims` override the ID token's.
  defp sign_in(conn, ctx, claims \\ %{}, path \\ ~p"/account/sign-in") do
    conn = get(conn, path)
    location = redirected_to(conn, 302)
    query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    now = System.system_time(:second)

    token =
      Map.merge(
        %{
          "iss" => "https://id.idejo.test",
          "aud" => [ctx.client_id],
          "sub" => ctx.ada,
          "exp" => now + 300,
          "auth_time" => now,
          "nonce" => query["nonce"]
        },
        claims
      )

    Fake.put_code("code-1", token)

    {get(
       recycle(conn),
       ~p"/account/callback?#{%{"code" => "code-1", "state" => query["state"]}}"
     ), query, location}
  end

  defp member?(conn), do: get_session(conn, "member") != nil

  @tag req: "ID-05"
  test "ID-05 signing in goes through the provider with PKCE, state and nonce", ctx do
    assert html_response(get(ctx.conn, ~p"/account"), 200) =~ "Sign in"
    {conn, query, location} = sign_in(ctx.conn, ctx)

    assert String.starts_with?(location, "https://id.idejo.test/oauth/v2/authorize?")
    assert query["client_id"] == ctx.client_id
    assert query["redirect_uri"] == "https://id.idejo.test/account/callback"
    assert query["code_challenge_method"] == "S256"
    assert byte_size(query["state"]) > 20 and byte_size(query["nonce"]) > 20
    assert redirected_to(conn) == ~p"/account"
    assert member?(conn)

    html = html_response(get(recycle(conn), ~p"/account"), 200)
    assert html =~ "Signed in as <strong>Ada</strong>"
  end

  @tag req: "ID-05"
  test "ID-05 a wrong issuer, audience, nonce, expiry or state is refused", ctx do
    for claims <- [
          %{"iss" => "https://elsewhere.test"},
          %{"aud" => ["another-client"]},
          %{"nonce" => "not-it"},
          %{"exp" => System.system_time(:second) - 1}
        ] do
      {conn, _, _} = sign_in(build_conn() |> Map.put(:host, "id.idejo.test"), ctx, claims)
      refute member?(conn), inspect(claims)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "did not work"
    end

    conn = get(ctx.conn, ~p"/account/sign-in")
    Fake.put_code("code-2", %{})
    conn = get(recycle(conn), ~p"/account/callback?code=code-2&state=forged")
    refute member?(conn)
  end

  @tag req: "ID-05"
  test "ID-05 the page lists the forums joined, each with leave or delete", ctx do
    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => "id05-c", "display_name" => "Chess", "owner_email" => "o@x.test"},
        "op"
      )

    {:ok, forum} = Forums.update_state(forum, %{status: "running", oidc_client_id: "client-c"})
    Fake.sign_in(ctx.ada, "client-c")
    {conn, _, _} = sign_in(ctx.conn, ctx)

    html = html_response(get(recycle(conn), ~p"/account"), 200)
    assert html =~ "Chess"
    assert html =~ "Leave (keep my account and messages)"
    assert html =~ "Delete my account there"
    refute html =~ "<script>"

    # Deleting needs the box ticked.
    conn = post(recycle(conn), ~p"/account/forums/#{forum.id}", %{"choice" => "delete"})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Tick the box"

    conn = post(recycle(conn), ~p"/account/forums/#{forum.id}", %{"choice" => "leave"})
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "kept"
    assert %Join{state: "leaving"} = Repo.get_by!(Join, forum_id: forum.id)
    assert_enqueued(worker: MemberWorker)

    # Not someone else's forum, and not signed out.
    assert post(
             build_conn() |> Map.put(:host, "id.idejo.test"),
             ~p"/account/forums/#{forum.id}",
             %{"choice" => "leave"}
           )
           |> redirected_to() == ~p"/account"
  end

  @tag req: "ID-06"
  test "ID-06 deleting the identity needs a fresh sign-in and the email typed", ctx do
    old = System.system_time(:second) - 600
    {conn, _, _} = sign_in(ctx.conn, ctx, %{"auth_time" => old})

    conn = post(recycle(conn), ~p"/account/delete", %{"email" => "ada@x.test"})
    assert redirected_to(conn) == ~p"/account/sign-in?fresh=1"
    refute Members.deletion(ctx.ada)

    {conn, query, _} = sign_in(recycle(conn), ctx, %{}, ~p"/account/sign-in?fresh=1")
    assert query["prompt"] == "login"
    assert redirected_to(conn) == ~p"/account#delete"

    conn = post(recycle(conn), ~p"/account/delete", %{"email" => "wrong@x.test"})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Type your email"

    conn = post(recycle(conn), ~p"/account/delete", %{"email" => " ADA@x.test "})
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Deleting your Idejo ID"
    assert Members.deleting?(ctx.ada)
    assert html_response(get(recycle(conn), ~p"/account"), 200) =~ "is being deleted"
  end

  @tag req: "ID-05"
  test "ID-05 the member's page answers only on the identity host" do
    assert get(%{build_conn() | host: "hub.idejo.test"}, ~p"/account").status == 404
  end
end
