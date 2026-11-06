# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.CommunityDirectoryTest do
  @moduledoc """
  The forums directory at forums.<forum domain>, and the answers to Idejo's community menu
  (steward decisions 2026-11-06).
  """
  use IdejoHubWeb.ConnCase, async: false

  import Ecto.Query
  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Community, Forums, Repo, Secrets}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Hosting.ForumContainer
  alias IdejoHub.Identity.Join
  alias IdejoHubWeb.Accessibility

  @directory "forums.idejo.test"

  defp forum!(subdomain, attrs \\ %{}) do
    secret =
      Secrets.encrypt("secret-#{subdomain}", Forums.context(subdomain, :oidc_client_secret))

    Repo.insert!(
      struct(
        %Forum{
          subdomain: subdomain,
          display_name: "Club #{subdomain}",
          owner_email: "o@x.test",
          idejo_version: "0.2.5",
          memory_mb: 384,
          cpus: 0.5,
          status: "running",
          secret_key_base_enc: Secrets.encrypt("k", Forums.context(subdomain, :secret_key_base)),
          oidc_client_id: "client-#{subdomain}",
          db_password_enc: Secrets.encrypt("pw", Forums.context(subdomain, :db_password)),
          oidc_client_secret_enc: secret
        },
        attrs
      )
    )
  end

  defp join!(subject, forum, state \\ "joined") do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      Join.changeset(%Join{}, %{
        subject: subject,
        forum_id: forum.id,
        state: state,
        first_at: now,
        last_at: now
      })
    )
  end

  defp ask(forum_id, secret, subject) do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64("client-#{forum_id}:#{secret}"))
    |> get(~p"/internal/community?#{%{subject: subject}}")
  end

  test "the directory lists running forums not hidden, by name, on its own host only" do
    forum!("dir-b", %{display_name: "Bridge"})
    forum!("dir-a", %{display_name: "Archery"})
    forum!("dir-hidden", %{listed: false})
    forum!("dir-paused", %{status: "suspended"})

    html = %{build_conn() | host: @directory} |> get(~p"/") |> html_response(200)

    names =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#directory .directory-name")
      |> Enum.map(&LazyHTML.text/1)

    assert names == ["Archery", "Bridge"]
    assert html =~ ~s(href="https://dir-a.idejo.test/")
    assert Accessibility.audit(html) == []

    # Its host only: a look-alike host gets nothing; Caddy may get a certificate for it.
    assert %{build_conn() | host: "forums.other.test"} |> get(~p"/") |> response(404)
    assert Forums.certificate_allowed?(@directory)
    assert Community.directory_url() == "https://forums.idejo.test/"
  end

  test "no forum can take the directory's subdomain" do
    assert {:error, changeset} =
             Forums.create_forum(
               %{"subdomain" => "forums", "display_name" => "F", "owner_email" => "o@x.test"},
               "operator"
             )

    assert "is reserved" in IdejoHub.DataCase.errors_on(changeset).subdomain
  end

  test "the operator hides a forum from the directory and shows it again", %{conn: conn} do
    forum = forum!("dir-op")
    Req.Test.stub(IdejoHub.Hosting.Health, &Plug.Conn.send_resp(&1, 200, "{}"))
    {conn, operator, _} = sign_in(conn)
    {:ok, view, _} = live(conn, ~p"/forums/#{forum}")

    view |> element("#unlist") |> render_click()
    refute Repo.get!(Forum, forum.id).listed
    refute %{build_conn() | host: @directory} |> get(~p"/") |> html_response(200) =~ "Club dir-op"

    view |> element("#list") |> render_click()
    assert Repo.get!(Forum, forum.id).listed

    actions =
      Repo.all(from e in Audit.Entry, where: e.forum_id == ^forum.id, select: {e.action, e.actor})

    assert {"forum.unlisted", operator.email} in actions
    assert {"forum.listed", operator.email} in actions
  end

  test "a forum asks, with its own client's credentials, which other forums a member joined" do
    tennis = forum!("cm-tennis")
    chess = forum!("cm-chess", %{display_name: "Chess"})
    paused = forum!("cm-paused", %{status: "suspended"})
    left = forum!("cm-left")
    join!("ada", tennis)
    join!("ada", chess)
    join!("ada", paused)
    join!("ada", left, "left")

    response = ask("cm-tennis", "secret-cm-tennis", "ada")

    assert json_response(response, 200) == %{
             "communities" => [%{"name" => "Chess", "url" => "https://cm-chess.idejo.test/"}]
           }

    # A wrong secret, another forum's credentials, no credentials, or a person who never
    # joined the asking forum: nothing.
    assert ask("cm-tennis", "wrong", "ada").status == 401
    assert ask("cm-chess", "secret-cm-tennis", "ada").status == 401
    assert build_conn() |> get(~p"/internal/community?subject=ada") |> response(401)
    join!("bea", chess)
    assert ask("cm-tennis", "secret-cm-tennis", "bea").status == 401
  end

  test "forums get both community addresses with their sign-in settings" do
    forum = forum!("cm-env")
    {:ok, params} = Forums.container_params(forum)
    env = ForumContainer.spec(params)["Env"]
    assert "IDEJO_COMMUNITY_URL=http://hub:4000/internal/community" in env
    assert "IDEJO_COMMUNITY_DIRECTORY_URL=https://forums.idejo.test/" in env
  end

  test "the directory shows each forum as a card with its logo, no introduction" do
    forum!("dir-card", %{display_name: "Chess"})
    html = %{build_conn() | host: @directory} |> get(~p"/") |> html_response(200)
    doc = LazyHTML.from_document(html)

    card =
      LazyHTML.query(doc, ~s(#directory a.directory-card[href="https://dir-card.idejo.test/"]))

    assert LazyHTML.text(card) =~ "Chess"
    # Idejo's fixed logo address (0.2.9), allowed by the page's policy.
    assert LazyHTML.attribute(LazyHTML.query(card, "img.directory-logo"), "src") == [
             "https://dir-card.idejo.test/logo"
           ]

    assert [csp] =
             %{build_conn() | host: @directory}
             |> get(~p"/")
             |> get_resp_header("content-security-policy")

    assert csp =~ "img-src 'self' data: blob: https://*.idejo.test"
    refute html =~ "The forums on this server"
    # Ten or fewer forums: no search, no pages.
    refute html =~ "directory-search"
    refute html =~ "directory-pages"
  end

  test "past ten forums, a search and pages" do
    for n <- 1..23,
        do:
          forum!("dir-#{String.pad_leading("#{n}", 2, "0")}", %{
            display_name: "Club #{String.pad_leading("#{n}", 2, "0")}"
          })

    forum!("dir-chess", %{display_name: "Chess 50%"})
    conn = %{build_conn() | host: @directory}

    first = conn |> get(~p"/") |> html_response(200)
    doc = LazyHTML.from_document(first)
    assert doc |> LazyHTML.query("#directory li") |> Enum.count() == 10
    assert doc |> LazyHTML.query(~s(#directory-search input[name="q"])) |> Enum.count() == 1
    assert LazyHTML.text(LazyHTML.query(doc, "#directory-pages")) =~ "Page 1 of 3"
    assert first =~ ~s(href="/?page=2")

    last = conn |> get(~p"/?page=3") |> html_response(200)

    assert last |> LazyHTML.from_document() |> LazyHTML.query("#directory li") |> Enum.count() ==
             4

    # Past the last page: the last one.
    assert conn |> get(~p"/?page=9") |> html_response(200) =~ "Page 3 of 3"

    # By name or subdomain, any case; % and _ are only themselves.
    found = conn |> get(~p"/?q=CHESS") |> html_response(200)

    assert found
           |> LazyHTML.from_document()
           |> LazyHTML.query("#directory .directory-name")
           |> Enum.map(&LazyHTML.text/1) == ["Chess 50%"]

    assert conn |> get(~p"/?#{%{q: "50%"}}") |> html_response(200) =~ "Chess 50%"
    assert conn |> get(~p"/?#{%{q: "_"}}") |> html_response(200) =~ "directory-none"

    assert conn
           |> get(~p"/?#{%{q: "dir-1"}}")
           |> html_response(200)
           |> LazyHTML.from_document()
           |> LazyHTML.query("#directory li")
           |> Enum.count() == 10

    # A search keeps its pages.
    club = conn |> get(~p"/?q=club") |> html_response(200)
    assert club =~ ~r{href="/\?(q=club&amp;page=2|page=2&amp;q=club)"}
  end
end
