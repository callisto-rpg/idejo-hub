# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SC07OwnerLogTest do
  @moduledoc """
  SC-07: a forum's owner sees the part of the Hub's audit log about their forum, on their
  Idejo ID page, once their Idejo ID's email (verified) is the forum's owner email.
  """
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  alias IdejoHub.{Audit, Forums, Identity}
  alias IdejoHub.Identity.{Fake, Members}

  @moduletag req: "SC-07"
  @moduletag :capture_log

  setup %{conn: conn} do
    Fake.start()
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)
    :ok = Members.ensure_account_client()
    {:ok, {client_id, _}} = Members.account_client()

    {:ok, tennis} = forum("sc07-own", "Ada@X.test")
    {:ok, other} = forum("sc07-other", "someone@x.test")

    %{
      conn: %{conn | host: "id.idejo.test"},
      client_id: client_id,
      tennis: tennis,
      other: other
    }
  end

  defp forum(subdomain, owner),
    do:
      Forums.create_forum(
        %{
          "subdomain" => subdomain,
          "display_name" => "Forum #{subdomain}",
          "owner_email" => owner
        },
        "op@hub.test"
      )

  defp person(verified?) do
    {:ok, id} =
      Fake.create_person(%{
        email: "ada@x.test",
        email_verified: verified?,
        display_name: "Ada",
        given_name: "Sennoma",
        family_name: "Ulo",
        language: "en"
      })

    id
  end

  # Through the provider and back, as ID-05's test does.
  defp signed_in(conn, ctx, subject) do
    conn = get(conn, ~p"/account/sign-in")
    query = conn |> redirected_to(302) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    now = System.system_time(:second)

    Fake.put_code("code-1", %{
      "iss" => "https://id.idejo.test",
      "aud" => [ctx.client_id],
      "sub" => subject,
      "exp" => now + 300,
      "auth_time" => now,
      "nonce" => query["nonce"]
    })

    conn =
      get(
        recycle(conn),
        ~p"/account/callback?#{%{"code" => "code-1", "state" => query["state"]}}"
      )

    recycle(conn)
  end

  test "SC-07 the owner sees their forum's log; members who acted are never named", ctx do
    conn = signed_in(ctx.conn, ctx, person(true))

    {:ok, _} = Audit.record("op@hub.test", "forum.secret_key_base.reveal", "ok", ctx.tennis)

    {:ok, _} =
      Audit.record("schedule", "forum.backup", "ok", ctx.tennis, %{
        "file" => "idejo-1.tar",
        "key" => "s3/key"
      })

    {:ok, _} =
      Audit.record("member:user-77", "identity.forum_leave", "ok", ctx.tennis, %{
        "subject" => "user-77"
      })

    {:ok, _} = Audit.record("op@hub.test", "forum.suspend", "ok", ctx.other)

    page = html_response(get(conn, ~p"/account"), 200)
    assert page =~ "Forums you own"
    assert page =~ ~s(href="/account/forums/sc07-own/log")
    refute page =~ "sc07-other/log"

    log = html_response(get(conn, ~p"/account/forums/sc07-own/log"), 200)
    assert log =~ "SECRET_KEY_BASE shown to the operator"
    assert log =~ "Operator op@hub.test"
    assert log =~ "The Hub (scheduled)"
    assert log =~ "file: idejo-1.tar"
    assert log =~ "A member left through Idejo ID"
    assert log =~ "A member"
    refute log =~ "user-77"
    refute log =~ "s3/key"
    # Another forum's entries are not there.
    refute log =~ "Suspended"
  end

  test "SC-07 another forum's log is not found", ctx do
    conn = signed_in(ctx.conn, ctx, person(true))
    assert response(get(conn, ~p"/account/forums/sc07-other/log"), 404)
    assert response(get(conn, ~p"/account/forums/no-such/log"), 404)
  end

  test "SC-07 an email the provider has not verified shows no forum", ctx do
    conn = signed_in(ctx.conn, ctx, person(false))
    refute html_response(get(conn, ~p"/account"), 200) =~ "Forums you own"
    assert response(get(conn, ~p"/account/forums/sc07-own/log"), 404)
  end

  test "SC-07 signed out, nothing", ctx do
    assert response(get(ctx.conn, ~p"/account/forums/sc07-own/log"), 404)
  end
end
