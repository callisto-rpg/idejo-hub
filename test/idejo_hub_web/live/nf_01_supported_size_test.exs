# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.NF01SupportedSizeTest do
  @moduledoc """
  NF-01: 1 to 30 forums per server (steward decisions 2026-11-06). Forums start with
  `POOL_SIZE` 5, the bundle's PostgreSQL leaves room for 30 of them and some more, and past
  30 the Hub warns where a forum would be added, but allows it.
  deploy/test/nf_01_connections.sh holds those connections on the bundle's real PostgreSQL.
  """
  use IdejoHubWeb.ConnCase, async: false

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Forums, Repo}
  alias IdejoHub.Forums.{Export, Forum}
  alias IdejoHub.Hosting.ForumContainer

  @moduletag req: "NF-01"

  @compose Path.expand("../../../deploy/docker-compose.yml", __DIR__)

  setup %{conn: conn} do
    {conn, _operator, _password} = sign_in(conn)
    %{conn: conn}
  end

  defp forums!(count, status \\ "running") do
    for _ <- 1..count//1 do
      Repo.insert!(%Forum{
        subdomain: "nf01-#{System.unique_integer([:positive])}",
        display_name: "NF-01",
        owner_email: "owner@nf01.test",
        idejo_version: "0.2.3",
        memory_mb: 384,
        cpus: 0.5,
        status: status,
        secret_key_base_enc: "x"
      })
    end
  end

  test "NF-01 forums start with POOL_SIZE 5, whatever the caller passes" do
    params = %{
      slug: "nf01",
      version: "0.2.3",
      env: %{"POOL_SIZE" => "10"},
      memory_mb: 384,
      cpus: 0.5
    }

    for spec <- [
          ForumContainer.spec(params),
          ForumContainer.one_off_spec(params, ["/app/bin/idejo-admin", "backup"])
        ] do
      assert "POOL_SIZE=5" in spec["Env"]
      refute "POOL_SIZE=10" in spec["Env"]
    end
  end

  test "NF-01 the bundle's PostgreSQL has room for 30 forums, the Hub, Zitadel and more" do
    {:ok, compose} = YamlElixir.read_from_file(@compose)
    ["postgres", "-c", "max_connections=" <> limit] = compose["services"]["db"]["command"]
    limit = String.to_integer(limit)

    # A forum holds its pool and Oban's listener; the Hub 11, Zitadel 14 (measured idle);
    # backups and one-off jobs 10; 3 stay reserved for the superuser.
    per_forum = 5 + 1
    others = 11 + 14 + 10 + 3
    assert Forums.supported_forums() == 30
    assert Forums.supported_forums() * per_forum + others <= limit
    # Room past the warning: at least 10 more forums.
    assert div(limit - others, per_forum) >= Forums.supported_forums() + 10
  end

  test "NF-01 every forum not deleted counts" do
    forums!(2)
    forums!(1, "suspended")
    forums!(1, "failed")
    forums!(1, "deleting")
    forums!(3, "deleted")
    assert Forums.hosted_count() == 5
  end

  test "NF-01 creating a forum past 30 warns and stays allowed", %{conn: conn} do
    forums!(29)
    forums!(4, "deleted")
    {:ok, view, _} = live(conn, ~p"/forums/new")
    refute has_element?(view, "#forum-limit")

    forums!(1)
    {:ok, view, _} = live(conn, ~p"/forums/new")
    assert view |> element("#forum-limit[role=status]") |> render() =~ "hosts 30 forums"
    assert has_element?(view, "#new-forum button:not([disabled])")

    assert {:ok, _forum} =
             Forums.create_forum(
               %{"subdomain" => "nf01-past", "display_name" => "P", "owner_email" => "o@p.test"},
               "op"
             )

    assert Forums.hosted_count() == 31
  end

  test "NF-01 importing, or restoring to a new subdomain, past 30 warns too", %{conn: conn} do
    [forum | _] = forums!(30)
    {:ok, view, _} = live(conn, ~p"/forums/import")
    assert has_element?(view, "#forum-limit", "Idejo Hub supports up to 30 per server")

    File.rm_rf!(Export.dir())
    on_exit(fn -> File.rm_rf!(Export.dir()) end)
    path = Path.join([Export.dir(), forum.subdomain, "idejo-20261106-010000.tar"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "tar")

    Repo.insert!(%Export{
      forum_id: forum.id,
      subdomain: forum.subdomain,
      kind: "backup",
      file_name: Path.basename(path),
      size: 3,
      sha256: String.duplicate("0", 64)
    })

    {:ok, view, _} = live(conn, ~p"/forums/#{forum}")
    assert has_element?(view, "#forum-limit")
    assert has_element?(view, "#restore-new")
  end
end
