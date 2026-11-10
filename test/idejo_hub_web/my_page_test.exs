# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.MyPageTest do
  @moduledoc """
  The members' page at my.<forum domain> (steward request 2026-11-10): Forums, Topics and
  Chats tabs; chats held by the Hub and written like Idejo topics without timers; the
  forums' chat service (tickets, unread counts); old conversations copied from forums.
  """
  use IdejoHubWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias IdejoHub.{Chats, Forums, Repo, Secrets}
  alias IdejoHub.Chats.{ForumLink, Tickets}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Identity
  alias IdejoHub.Identity.{Fake, Join}

  @my "my.idejo.test"

  setup do
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    Fake.start()
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)
    :ok
  end

  defp forum!(subdomain) do
    Repo.insert!(%Forum{
      subdomain: subdomain,
      display_name: "Club #{subdomain}",
      owner_email: "o@x.test",
      idejo_version: "0.3.4",
      memory_mb: 384,
      cpus: 0.5,
      status: "running",
      secret_key_base_enc: Secrets.encrypt("k", Forums.context(subdomain, :secret_key_base)),
      oidc_client_id: "client-#{subdomain}",
      db_password_enc: Secrets.encrypt("pw", Forums.context(subdomain, :db_password)),
      oidc_client_secret_enc:
        Secrets.encrypt("secret-#{subdomain}", Forums.context(subdomain, :oidc_client_secret))
    })
  end

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

  # Signed in on the members' page through the sign-in host, as a browser would.
  defp signed_in(subject) do
    start = %{build_conn() | host: @my} |> get(~p"/sign-in")
    "https://id.idejo.test/account/my?" <> query = redirected_to(start, 302)

    back =
      %{build_conn() | host: "id.idejo.test"}
      |> init_test_session(%{
        "member" => %{"sub" => subject, "at" => System.system_time(:second)}
      })
      |> get("/account/my?" <> query)

    "https://my.idejo.test/signed-in?" <> token_query = redirected_to(back, 302)
    done = start |> recycle() |> Map.put(:host, @my) |> get("/signed-in?" <> token_query)
    assert redirected_to(done, 302) == "/"
    done |> recycle() |> Map.put(:host, @my)
  end

  describe "chats" do
    test "only between Idejo IDs that share a forum, one per pair" do
      club = forum!("my-club")
      join!("ada", club)
      join!("bo", club)

      assert {:ok, chat} = Chats.start("ada", "bo")
      assert {:ok, %{id: id}} = Chats.start("bo", "ada")
      assert id == chat.id
      assert Chats.start("ada", "stranger") == {:error, :forbidden}
      assert Chats.start("ada", "ada") == {:error, :forbidden}
      assert Chats.get("cy", chat.id) == nil
    end

    test "messages grow with Enter, close with Ctrl+Enter, and count once as unread" do
      club = forum!("my-grow")
      join!("ada", club)
      join!("bo", club)
      {:ok, chat} = Chats.start("ada", "bo")

      {:ok, m1} = Chats.commit("ada", chat, "Hello")
      assert m1.state == "open"
      {:ok, m1b} = Chats.commit("ada", chat, "Hello **Bo**")
      assert m1b.id == m1.id and m1b.body_html =~ "<strong>Bo</strong>"
      assert Chats.unread_count("bo") == 1

      {:ok, closed} = Chats.commit("ada", chat, "Hello **Bo**. Bye", break: true)
      assert closed.id == m1.id and closed.state == "closed"
      {:ok, m2} = Chats.commit("ada", chat, "Again")
      assert m2.id != m1.id
      assert [%{unread: 2}] = Chats.list("bo")
      assert Chats.unread_count("bo") == 1

      :ok = Chats.mark_read("bo", chat)
      assert Chats.unread_count("bo") == 0

      # Editing and deleting are the author's, on closed messages.
      assert Chats.edit("bo", closed, "Not mine") == {:error, :forbidden}
      assert Chats.edit("ada", m2, "Open") == {:error, :forbidden}
      assert {:ok, %{edited: true}} = Chats.edit("ada", closed, "Hi Bo")
      assert Chats.edit("ada", closed, "  ") == {:error, :blank}
      assert {:ok, %{deleted_at: %DateTime{}}} = Chats.delete_own("ada", closed)

      # Raw HTML never reaches the page.
      {:ok, m3} = Chats.commit("bo", chat, "<script>alert(1)</script>", break: true)
      refute m3.body_html =~ "<script"
    end

    test "the chat page: Enter grows the message, the other person sees it live" do
      club = forum!("my-live")
      join!("ada", club)
      join!("bo", club)
      {:ok, chat} = Chats.start("ada", "bo")

      {:ok, ada_view, _} = live(signed_in("ada"), ~p"/chat/#{chat.id}")
      {:ok, bo_view, _} = live(signed_in("bo"), ~p"/chat/#{chat.id}")

      ada_view
      |> element("#composer")
      |> render_hook("commit", %{"body" => "Hi", "break" => false})

      assert render(bo_view) =~ "Hi"
      # The author's open message is the composer, not a second copy in the list.
      refute ada_view |> element("#chat-messages") |> render() =~ "Hi"

      ada_view
      |> element("#composer")
      |> render_hook("commit", %{"body" => "Hi there", "break" => true})

      assert render(bo_view) =~ "Hi there"
      assert ada_view |> element("#chat-messages") |> render() =~ "Hi there"

      [message] = Chats.messages(chat)

      bo_view
      |> element("#message-#{message.id} .chat-react-choices button", "👍")
      |> render_click()

      assert render(ada_view) =~ "👍 1"

      # Someone else's chat is not theirs to open.
      {:ok, _, html} =
        live(signed_in("cy"), ~p"/chat/#{chat.id}") |> follow_redirect(signed_in("cy"))

      assert html =~ "not yours"
    end

    test "Private Message from a forum starts the chat, through sign-in" do
      club = forum!("my-new")
      join!("ada", club)
      join!("bo", club)

      conn = %{build_conn() | host: @my} |> get(~p"/chat/new?with=bo")
      assert redirected_to(conn, 302) == "/sign-in"

      conn = signed_in("ada") |> get(~p"/chat/new?with=bo")
      "/chat/" <> id = redirected_to(conn, 302)
      assert Chats.get("ada", id)
    end
  end

  describe "the forums' chat service" do
    test "a ticket names its member only to the forum it was made for" do
      club = forum!("my-tix")
      other = forum!("my-tix2")
      ticket = Tickets.issue("ada", "topics", "forum:#{club.id}")

      conn =
        build_conn()
        |> basic("my-tix")
        |> post("/internal/community/chats/tickets", %{ticket: ticket})

      assert json_response(conn, 200) == %{"subject" => "ada", "scope" => "topics"}

      conn =
        build_conn()
        |> basic("my-tix2")
        |> post("/internal/community/chats/tickets", %{ticket: ticket})

      assert json_response(conn, 404)
      assert other

      conn = build_conn() |> post("/internal/community/chats/tickets", %{ticket: ticket})
      assert json_response(conn, 401)
    end

    test "unread counts, only about someone who joined that forum" do
      club = forum!("my-count")
      join!("ada", club)
      join!("bo", club)
      {:ok, chat} = Chats.start("ada", "bo")
      {:ok, _} = Chats.commit("ada", chat, "Hi", break: true)

      conn =
        build_conn() |> basic("my-count") |> get("/internal/community/chats/unread?subject=bo")

      assert json_response(conn, 200) == %{"unread" => 1}

      conn =
        build_conn() |> basic("my-count") |> get("/internal/community/chats/unread?subject=zed")

      assert json_response(conn, 401)
    end
  end

  describe "the members' page" do
    setup do
      Application.put_env(:idejo_hub, :chats_req_options, plug: {Req.Test, ForumLink})
      on_exit(fn -> Application.delete_env(:idejo_hub, :chats_req_options) end)
      :ok
    end

    test "forums are given the chats and topics pages" do
      {:ok, %{env: env}} = Forums.container_params(forum!("my-env"))
      assert env["IDEJO_CHAT_URL"] == "https://my.idejo.test/chat"
      assert env["IDEJO_TOPICS_URL"] == "https://my.idejo.test/topics"
    end

    test "answers only on its own host, and asks visitors to sign in" do
      assert %{build_conn() | host: "my.other.test"} |> get(~p"/sign-in") |> response(404)
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(%{build_conn() | host: @my}, ~p"/")
    end

    test "three tabs: forums joined, followed topics, chats copied from forums" do
      club = forum!("my-tabs")
      join!("ada", club)
      join!("bo", club)

      Req.Test.stub(ForumLink, fn conn ->
        ticket = conn.query_params["ticket"] || conn.body_params["ticket"]
        assert {:ok, %{subject: "ada"}} = Tickets.redeem(ticket, "forum:#{club.id}")

        case conn.request_path do
          "/community/topics" ->
            Req.Test.json(conn, %{
              "topics" => [
                %{
                  "id" => "t1",
                  "title" => "Garden plans",
                  "url" => "https://my-tabs.idejo.test/t/t1/garden-plans",
                  "unread" => 2,
                  "message_count" => 5,
                  "last_activity_at" => "2026-11-10T10:00:00Z",
                  "category" => %{
                    "name" => "General",
                    "url" => "https://my-tabs.idejo.test/c/general"
                  },
                  "first" => "Tomatoes first",
                  "latest" => [
                    %{
                      "author" => "Bo",
                      "text" => "And basil",
                      "url" => "https://my-tabs.idejo.test/m/1"
                    }
                  ],
                  "people" => [%{"name" => "Bo", "avatar" => nil}],
                  "people_count" => 1
                }
              ]
            })

          "/community/conversations" ->
            Req.Test.json(conn, %{
              "conversations" => [
                %{
                  "id" => "c1",
                  "subjects" => ["ada", "bo"],
                  "messages" => [
                    %{
                      "id" => "m1",
                      "author" => "bo",
                      "body_md" => "Old hello",
                      "body_html" => "<p>Old hello</p><script>x()</script>",
                      "opened_at" => "2026-10-01T09:00:00Z",
                      "reactions" => [%{"emoji" => "+1", "char" => "👍", "subject" => "ada"}]
                    }
                  ]
                }
              ],
              "remaining" => 1,
              "url" => "https://my-tabs.idejo.test/p"
            })

          "/community/conversations/moved" ->
            assert conn.body_params["ids"] == ["c1"]
            Req.Test.json(conn, %{"moved" => 1})
        end
      end)

      conn = signed_in("ada")
      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Club my-tabs"
      assert html =~ ~s(aria-current="page")

      html = view |> element("#tab-topics") |> render_click()
      html = if html =~ "Garden plans", do: html, else: render_async(view)
      assert html =~ "Garden plans" and html =~ "And basil" and html =~ "2 new"
      assert html =~ "Club my-tabs"

      view |> element("#tab-chats") |> render_click()
      html = render_async(view)
      assert html =~ "Old hello"
      assert html =~ "stayed in their forum"
      assert html =~ "https://my-tabs.idejo.test/p"

      # Copied once, sanitised, with its reaction; asked again within the hour, nothing.
      [%{chat: chat}] = Chats.list("ada")
      [message] = Chats.messages(chat)
      refute message.body_html =~ "script"
      assert [%{emoji: "👍", subject: "ada"}] = message.reactions
      assert :ok = ForumLink.import("ada", force: true)
      assert [_] = Chats.messages(chat)
    end
  end
end
