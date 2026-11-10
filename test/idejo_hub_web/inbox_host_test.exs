# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.InboxHostTest do
  @moduledoc """
  The members' inbox (steward requests 2026-11-10): an Idejo container in inbox mode at
  my.<forum domain>, set up by the operator; forums sent there; the Hub relaying the
  inbox's questions to the forums with tickets, and the forums' unread counts to the inbox.
  """
  use IdejoHubWeb.ConnCase, async: false

  alias IdejoHub.Chats.{ForumLink, Tickets}
  alias IdejoHub.{Community, Forums, Repo, Secrets}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Identity
  alias IdejoHub.Identity.{Fake, Join, Profile}

  setup do
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    Fake.start()
    Application.put_env(:idejo_hub, :chats_req_options, plug: {Req.Test, ForumLink})

    on_exit(fn ->
      Application.put_env(:idejo_hub, Identity, original)
      Application.delete_env(:idejo_hub, :chats_req_options)
    end)

    :ok
  end

  defp forum!(subdomain, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Forum{
          subdomain: subdomain,
          display_name: "Club #{subdomain}",
          owner_email: "o@x.test",
          idejo_version: "0.3.5",
          memory_mb: 384,
          cpus: 0.5,
          status: "running",
          secret_key_base_enc: Secrets.encrypt("k", Forums.context(subdomain, :secret_key_base)),
          oidc_client_id: "client-#{subdomain}",
          db_password_enc: Secrets.encrypt("pw", Forums.context(subdomain, :db_password)),
          oidc_client_secret_enc:
            Secrets.encrypt("secret-#{subdomain}", Forums.context(subdomain, :oidc_client_secret))
        },
        attrs
      )
    )
  end

  defp inbox!, do: forum!("inbox", %{kind: "inbox", display_name: "Idejo", listed: false})

  defp join!(subject, forum) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      Join.changeset(%Join{}, %{
        subject: subject,
        forum_id: forum.id,
        state: "joined",
        first_at: now,
        last_at: now
      })
    )
  end

  defp basic(conn, subdomain),
    do:
      put_req_header(
        conn,
        "authorization",
        "Basic " <> Base.encode64("client-#{subdomain}:secret-#{subdomain}")
      )

  defp env(forum) do
    {:ok, %{env: env}} = Forums.container_params(forum)
    env
  end

  test "the operator sets up one inbox at my; no forum takes that name" do
    assert {:ok, inbox} = Forums.create_inbox("op@x.test", "op@x.test")
    assert inbox.kind == "inbox" and inbox.subdomain == "inbox" and not inbox.listed
    assert Forums.host(inbox) == "my.idejo.test"
    assert Forums.for_host("my.idejo.test").id == inbox.id
    assert inbox.display_name == "Idejo" and not inbox.local_accounts
    assert Forums.inbox().id == inbox.id
    assert Forums.create_inbox("op@x.test", "op@x.test") == {:error, :exists}

    changeset = Forums.change_new_forum(%{"subdomain" => "inbox", "display_name" => "Mine"})
    assert {"is reserved", _} = changeset.errors[:subdomain]
  end

  test "the inbox runs in inbox mode; forums lead there once it exists" do
    club = forum!("ib-club")
    refute Map.has_key?(env(club), "IDEJO_CHAT_URL")

    inbox = inbox!()
    assert env(inbox)["IDEJO_INBOX"] == "on"
    refute Map.has_key?(env(inbox), "IDEJO_CHAT_URL")
    assert env(club)["IDEJO_CHAT_URL"] == "https://my.idejo.test/chat"
    assert env(club)["IDEJO_TOPICS_URL"] == "https://my.idejo.test/topics"
    assert Forums.certificate_allowed?("my.idejo.test")
  end

  test "the inbox is never one of a member's forums" do
    club = forum!("ib-list")
    inbox = inbox!()
    join!("ada", club)
    join!("ada", inbox)

    assert Community.joined_hosts("ada") == MapSet.new(["ib-list.idejo.test"])
    assert [%{host: "ib-list.idejo.test"}] = ForumLink.forums("ada")

    conn = build_conn() |> basic("inbox") |> get("/internal/community?subject=ada")
    assert %{"communities" => [%{"name" => "Club ib-list"}]} = json_response(conn, 200)
  end

  test "the inbox's questions are relayed to the member's forums, with tickets" do
    club = forum!("ib-relay")
    inbox = inbox!()
    join!("ada", club)
    join!("ada", inbox)
    test = self()

    Req.Test.stub(ForumLink, fn conn ->
      ticket = conn.query_params["ticket"] || conn.body_params["ticket"]
      assert {:ok, %{subject: "ada"}} = Tickets.redeem(ticket, "forum:#{club.id}")

      case conn.request_path do
        "/community/topics" ->
          Req.Test.json(conn, %{"topics" => [%{"id" => "t1", "title" => "Garden plans"}]})

        "/community/conversations" ->
          Req.Test.json(conn, %{
            "conversations" => [%{"id" => "c1", "subjects" => ["ada", "bo"], "messages" => []}],
            "remaining" => 1,
            "url" => "https://ib-relay.idejo.test/p"
          })

        "/community/conversations/moved" ->
          send(test, {:moved, conn.body_params["ids"]})
          Req.Test.json(conn, %{"moved" => 1})
      end
    end)

    conn = build_conn() |> basic("inbox") |> get("/internal/community/inbox/topics?subject=ada")

    assert %{
             "forums" => [
               %{
                 "name" => "Club ib-relay",
                 "url" => "https://ib-relay.idejo.test/",
                 "topics" => [%{"title" => "Garden plans"}]
               }
             ]
           } =
             json_response(conn, 200)

    conn =
      build_conn() |> basic("inbox") |> get("/internal/community/inbox/conversations?subject=ada")

    assert %{
             "forums" => [
               %{
                 "host" => "ib-relay.idejo.test",
                 "remaining" => 1,
                 "conversations" => [%{"id" => "c1"}]
               }
             ]
           } = json_response(conn, 200)

    conn =
      build_conn()
      |> basic("inbox")
      |> post("/internal/community/inbox/conversations/moved", %{
        subject: "ada",
        host: "ib-relay.idejo.test",
        ids: ["c1"]
      })

    assert json_response(conn, 200) == %{"moved" => 1}
    assert_received {:moved, ["c1"]}

    # Only the inbox asks: a forum's own credentials, or none, are refused.
    assert build_conn()
           |> basic("ib-relay")
           |> get("/internal/community/inbox/topics?subject=ada")
           |> json_response(401)

    assert build_conn()
           |> get("/internal/community/inbox/topics?subject=ada")
           |> json_response(401)
  end

  test "a forum's ticket names its member only to that forum" do
    club = forum!("ib-tix")
    forum!("ib-tix2")
    ticket = Tickets.issue("ada", "topics", "forum:#{club.id}")

    conn =
      build_conn()
      |> basic("ib-tix")
      |> post("/internal/community/chats/tickets", %{ticket: ticket})

    assert json_response(conn, 200) == %{"subject" => "ada", "scope" => "topics"}

    conn =
      build_conn()
      |> basic("ib-tix2")
      |> post("/internal/community/chats/tickets", %{ticket: ticket})

    assert json_response(conn, 404)
  end

  test "a forum's sidebar count is asked of the inbox, with the inbox's credentials" do
    club = forum!("ib-count")
    inbox!()
    join!("bo", club)

    Req.Test.stub(ForumLink, fn conn ->
      assert conn.host == "idejo-forum-inbox"
      assert conn.request_path == "/community/inbox-unread"
      assert conn.query_params["subject"] == "bo"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("client-inbox:secret-inbox")
             ]

      Req.Test.json(conn, %{"unread" => 3})
    end)

    conn = build_conn() |> basic("ib-count") |> get("/internal/community/chats/unread?subject=bo")
    assert json_response(conn, 200) == %{"unread" => 3}

    conn =
      build_conn() |> basic("ib-count") |> get("/internal/community/chats/unread?subject=zed")

    assert json_response(conn, 401)
  end

  test "the inbox reads any Idejo ID's profile, never fills one" do
    inbox!()
    Repo.insert!(%Profile{subject: "bo", username: "bo_garden"})

    conn = build_conn() |> basic("inbox") |> get("/internal/community/profile?subject=bo")
    assert %{"username" => "bo_garden"} = json_response(conn, 200)

    assert build_conn()
           |> basic("inbox")
           |> get("/internal/community/profile?subject=nobody")
           |> json_response(401)

    conn =
      build_conn()
      |> basic("inbox")
      |> post("/internal/community/profile", %{subject: "bo", username: "other"})

    assert json_response(conn, 401)
  end
end
