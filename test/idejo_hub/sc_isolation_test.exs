# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.SCIsolationTest do
  @moduledoc """
  SC-01, SC-05, SC-06, SC-09: checks that the Hub keeps forums apart from each other and from
  itself. Each test is tagged with its requirement.
  """
  use IdejoHubWeb.ConnCase, async: true

  alias IdejoHub.Hosting.ForumContainer

  @params %{
    slug: "sc-tennis",
    version: "0.1.0",
    env: %{"PHX_HOST" => "sc-tennis.idejo.test"},
    memory_mb: 384,
    cpus: 0.5
  }

  @compose Path.expand("../../deploy/docker-compose.yml", __DIR__)

  @tag req: "SC-01"
  test "SC-01 the Hub's own session cookie is host-only (no Domain)", %{conn: conn} do
    conn = get(conn, ~p"/sign-in")
    cookie = conn.resp_cookies["_idejo_hub_key"]
    refute Map.has_key?(cookie, :domain)
    # Forums' cookies are Idejo's SP-10 (host-only, guarded by Idejo's own test); the Hub
    # sets no variable that could change it.
    refute Enum.any?(ForumContainer.spec(@params)["Env"], &(&1 =~ ~r/COOKIE|DOMAIN/i))
  end

  @tag req: "SC-05"
  test "SC-05 every container the Hub makes has memory and CPU limits" do
    for spec <- [
          ForumContainer.spec(@params),
          ForumContainer.one_off_spec(@params, ["/app/bin/idejo-admin", "backup"])
        ] do
      assert spec["HostConfig"]["Memory"] == 384 * 1024 * 1024
      assert spec["HostConfig"]["NanoCpus"] == 500_000_000
    end
  end

  @tag req: "SC-06"
  test "SC-06 the Hub runs only Idejo's documented commands, never a way into a forum" do
    source =
      Path.wildcard(Path.expand("../../lib/**/*.ex", __DIR__))
      |> Enum.map_join("\n", &File.read!/1)

    # Commands the Hub gives idejo-admin: setup, backup, restore, rotate-push-keys, stats, and
    # for a member (ID-05, ID-06) leave and delete-account by their provider subject.
    used = Regex.scan(~r/@admin,\s*"([a-z-]+)"|"\/app\/bin\/idejo-admin",\s*"([a-z-]+)"/, source)
    used = used |> Enum.flat_map(&tl/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.sort()

    assert used == [
             "backup",
             "delete-account",
             "leave",
             "restore",
             "rotate-push-keys",
             "setup",
             "stats"
           ]

    # No owner-password reset, no remote shell into a forum's node.
    for forbidden <- ["reset-owner-password", "\"rpc\"", "\"remote\"", "\"eval\""] do
      refute source =~ forbidden, forbidden
    end
  end

  @tag req: "SC-09"
  test "SC-09 every operator page needs a signed-in operator", %{conn: conn} do
    open = [
      "/sign-in",
      "/sign-in/two-factor",
      "/internal/caddy/ask",
      "/internal/forum-unavailable",
      # Idejo's community menu: a forum's client credentials, not a sign-in (tested in
      # community_directory_test.exs).
      "/internal/community",
      # The forums directory's sign-in hand-off: a token signed by the Hub, not an operator
      # page (tested in community_directory_test.exs).
      "/signed-in",
      "/internal/community/profile",
      # Idejo's chat service: a forum's client credentials (tested in my_page_test.exs).
      "/internal/community/chats/unread"
    ]

    # Members' pages (ID-02) are for everyone, but only on the identity host (the directory's
    # search on the directory's): on the Hub's own host they do not exist.
    # SC-07's owner log is for its signed-in owner (tested in sc_07_owner_log_test.exs).
    members = [
      "/account/sign-up",
      "/account",
      "/account/sign-in",
      "/account/callback",
      "/account/forums/:subdomain/log",
      # SC-10: the disclosure page, public (tested in sc_10_disclosure_test.exs).
      "/account/operator-access",
      # Hub NF-07: the privacy notice, public (tested in nf_07_member_pages_test.exs).
      "/account/privacy",
      # Outside forums' listing: their client credentials, not a sign-in (tested in
      # outside_forums_test.exs).
      "/account/api/listing",
      # Idejo ID profiles: forums' client credentials; pictures are public (tested in
      # identity_profile_test.exs).
      "/account/api/profile",
      # The forums directory's hand-off: who is signed in here (community_directory_test.exs).
      "/account/directory",
      "/account/pictures/:key",
      # The forums directory's search as JSON, public like the page, only on the directory's
      # host (tested in community_directory_test.exs).
      "/api/forums",
      # The members' page (steward request 2026-11-10): only on my.<forum domain>, for a
      # signed-in Idejo ID, and its hand-off on the identity host (tested in my_page_test.exs).
      "/account/my",
      "/account/api/chats/unread",
      "/sign-in-again",
      "/topics",
      "/chat",
      "/chat/new",
      "/chat/:id"
    ]

    for path <- members do
      url = String.replace(path, ":subdomain", "x")
      assert get(recycle(conn), url).status == 404, "#{path} answers on the Hub's host"
    end

    open = open ++ members

    for %{verb: :get, path: path} <- IdejoHubWeb.Router.__routes__(),
        path not in open,
        not String.starts_with?(path, "/dev"),
        not String.starts_with?(path, "/live") do
      url = String.replace(path, ~r/:[a-z_]+/, "1")
      response = get(recycle(conn), url)
      assert response.status == 302 and redirected_to(response) == "/sign-in", "#{path} is open"
    end
  end

  @tag req: "SC-09"
  test "SC-09 forums get no Hub secret and cannot reach Docker" do
    env = ForumContainer.spec(@params)["Env"]
    refute Enum.any?(env, &(&1 =~ ~r/^(HUB_|DOCKER_|IDEJO_HUB_)/))

    {:ok, compose} = YamlElixir.read_from_file(@compose)
    services = compose["services"]
    # docker-guard is only on the internal `docker` network, which forums never join.
    assert services["docker-guard"]["networks"] == ["docker"]
    assert services["socket-proxy"]["network_mode"] == "none"
    assert compose["networks"]["docker"]["internal"] == true
    refute "docker" in (services["caddy"]["networks"] || [])
    refute "docker" in (services["db"]["networks"] || [])
  end
end
