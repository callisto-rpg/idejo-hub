# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.InboxFavouritesTest do
  @moduledoc """
  The inbox's Forums tab (steward request 2026-11-23): favourite forums, kept per idejo ID
  and forum; a forum joined while in 3 forums or fewer is a favourite at once; a member in 2
  forums or fewer with none gets all of them; "Mark as favourite" and "Leave forum" asked by
  the inbox.
  """
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Ecto.Query

  alias IdejoHub.{Forums, Repo, Secrets}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Identity
  alias IdejoHub.Identity.{Fake, Join, Members, MemberWorker}

  setup do
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    Fake.start()
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)
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

  defp inbox!, do: forum!("inbox", %{kind: "inbox", display_name: "idejo", listed: false})

  # Joins through sign-ins at the provider, one minute apart, as members do.
  defp sign_in!(subject, forums) do
    for {forum, i} <- Enum.with_index(forums) do
      Fake.sign_in(subject, forum.oidc_client_id, DateTime.add(DateTime.utc_now(), i, :minute))
    end

    :ok = Members.sync()
  end

  defp join!(subject, forum, favourite \\ false) do
    now = DateTime.utc_now(:second)

    Repo.insert!(
      Join.changeset(%Join{}, %{
        subject: subject,
        forum_id: forum.id,
        first_at: now,
        last_at: now,
        favourite: favourite
      })
    )
  end

  defp favourites(subject) do
    Repo.all(
      from j in Join,
        join: f in assoc(j, :forum),
        where: j.subject == ^subject and j.favourite,
        order_by: f.subdomain,
        select: f.subdomain
    )
  end

  # The inbox asks with its own client's credentials, in JSON.
  defp ask(path, body, credentials \\ "client-inbox:secret-inbox") do
    build_conn()
    |> put_req_header("authorization", "Basic " <> Base.encode64(credentials))
    |> put_req_header("content-type", "application/json")
    |> post("/internal/community/inbox/" <> path, Jason.encode!(body))
  end

  test "forums joined while in 3 or fewer are favourites; the inbox never is" do
    inbox = inbox!()
    forums = for n <- 1..5, do: forum!("fav-#{n}")

    sign_in!("ada", [inbox | forums])

    # Joined with 0, 1, 2 and 3 others: favourites; the fifth, with 4 others: not.
    assert favourites("ada") == ["fav-1", "fav-2", "fav-3", "fav-4"]
  end

  test "a member in 2 forums or fewer with no favourite gets them all, when the list is read" do
    inbox = inbox!()
    [a, b, c] = for n <- 1..3, do: forum!("fill-#{n}")
    join!("ada", inbox)
    join!("ada", a)
    join!("ada", b)

    conn =
      build_conn()
      |> put_req_header("authorization", "Basic " <> Base.encode64("client-inbox:secret-inbox"))
      |> get("/internal/community?subject=ada")

    assert %{"communities" => [%{"favourite" => true}, %{"favourite" => true}]} =
             json_response(conn, 200)

    # Three forums, none a favourite: left as they are.
    join!("bob", inbox)
    for forum <- [a, b, c], do: join!("bob", forum)
    assert Members.fill_favourites("bob") == 0
    assert favourites("bob") == []

    # Two forums, one a favourite already: the other stays as it is.
    join!("cy", a, true)
    join!("cy", b)
    assert Members.fill_favourites("cy") == 0
    assert favourites("cy") == ["fill-1"]
  end

  test "the inbox marks a forum as a favourite and back" do
    inbox!()
    club = forum!("fav-club")
    for n <- 1..3, do: join!("ada", forum!("fav-other-#{n}"))
    join!("ada", club)

    post = &ask("favourite", &1)
    host = Forums.host(club)
    conn = post.(%{subject: "ada", host: host, favourite: true})
    assert json_response(conn, 200) == %{"favourite" => true}
    assert favourites("ada") == ["fav-club"]

    conn = post.(%{subject: "ada", host: host, favourite: false})
    assert json_response(conn, 200) == %{"favourite" => false}
    assert favourites("ada") == []

    assert json_response(post.(%{subject: "bob", host: host, favourite: true}), 404) ==
             %{"error" => "not_joined"}

    assert json_response(post.(%{subject: "ada", host: "my.idejo.test", favourite: true}), 404)
    assert json_response(post.(%{subject: "ada", host: host}), 400)

    conn = ask("favourite", %{subject: "ada", host: host, favourite: true}, "client-x:nope")
    assert json_response(conn, 401)
  end

  test "the inbox leaves a forum, the account kept" do
    inbox!()
    club = forum!("leave-club")
    join = join!("ada", club)

    conn = ask("leave", %{subject: "ada", host: Forums.host(club)})

    assert json_response(conn, 200) == %{"state" => "leaving"}
    assert_enqueued(worker: MemberWorker, args: %{"join_id" => join.id, "choice" => "leave"})

    conn = ask("leave", %{subject: "ada", host: Forums.host(club)})

    assert json_response(conn, 409) == %{"error" => "busy"}

    conn = ask("leave", %{subject: "bob", host: Forums.host(club)})

    assert json_response(conn, 404)
  end
end
