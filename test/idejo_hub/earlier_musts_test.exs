# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.EarlierMustsTest do
  @moduledoc """
  Hub milestone 4's exit check asks a passing test named after every Must. These Musts were
  built in milestones 2 and 3 without a test of their own name; each test here checks the
  Hub's part, and names where the rest is proved (Idejo's own tests, the exit checks).
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Plug.Conn

  alias IdejoHub.Forums
  alias IdejoHub.Forums.CreateWorker
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.{ForumContainer, Postgres}

  @moduletag :capture_log

  @root Path.expand("../..", __DIR__)
  defp read(path), do: File.read!(Path.join(@root, path))

  defp running_forum(subdomain) do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, &send_resp(&1, 200, "{}"))
    on_exit(fn -> Postgres.drop(subdomain) end)

    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => subdomain, "display_name" => "Club", "owner_email" => "o@x.test"},
        "operator"
      )

    :ok = perform_job(CreateWorker, %{"forum_id" => forum.id, "actor" => "operator"})
    Forums.get_forum!(forum.id)
  end

  defp env(forum) do
    {:ok, params} = Forums.container_params(forum)

    for "" <> pair <- ForumContainer.spec(params)["Env"], into: %{} do
      [k, v] = String.split(pair, "=", parts: 2)
      {k, v}
    end
  end

  @tag req: "ID-03"
  test "ID-03 a forum signs people in with their Idejo ID, and its own settings decide who joins" do
    env = forum_with_client("id03-club") |> env()

    # Idejo's OpenID Connect client (AC-09) makes the local member at the first sign-in.
    assert env["IDEJO_OIDC_ISSUER"] == IdejoHub.Identity.issuer()
    assert env["IDEJO_OIDC_CLIENT_ID"] && env["IDEJO_OIDC_CLIENT_SECRET"]
    # Approval and invitations stay the forum's own (its registration mode, Admin → Settings):
    # the Hub sets nothing about who may join.
    refute Enum.any?(Map.keys(env), &(&1 =~ ~r/REGISTRATION|INVITE|APPROV/))
    # deploy/test/m3/run.sh step 5: a first visit makes the account, after Idejo's consent.
    assert read("deploy/test/m3/run.sh") =~ "join both forums"
  end

  @tag req: "ID-04"
  test "ID-04 roles, profiles, bans and moderation stay in each forum: the Hub has no way to them" do
    # The idejo-admin commands the Hub runs (read as SC-06 reads them): none touches roles,
    # profiles or bans.
    source = Path.wildcard(Path.join(@root, "lib/**/*.ex")) |> Enum.map_join("\n", &File.read!/1)

    commands =
      Regex.scan(~r/@admin,\s*"([a-z-]+)"|"\/app\/bin\/idejo-admin",\s*"([a-z-]+)"/, source)
      |> Enum.flat_map(&tl/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    assert "backup" in commands
    refute Enum.any?(commands, &(&1 =~ ~r/ban|role|profile|moderat/))
    # The Hub never opens a forum's database: its PostgreSQL code only creates and drops them
    # (HN-05), and pg_hba lets a role open only its own database.
    postgres = read("lib/idejo_hub/hosting/postgres.ex")
    refute postgres =~ ~r/SELECT .* FROM (users|roles|bans|user_roles)/i
    # deploy/test/m3/run.sh steps 6-7: moderator on one forum, banned on the other, as each
    # forum's owner decided; the ban holds on one only.
    assert read("deploy/test/m3/run.sh") =~ "the ban holds on bravo only"
  end

  @tag req: "ID-09"
  test "ID-09 forums never receive a password; the Hub never asks for one" do
    # Sign-up asks email and display name; the password (or passkey) is set at Zitadel.
    signup = read("lib/idejo_hub_web/controllers/signup_html/new.html.heex")
    refute signup =~ ~s(type="password")
    # A forum is a confidential client with the code flow: it gets an ID token (subject,
    # email, display name), never credentials. Consent at the first join is Idejo's (AC-09).
    zitadel = read("lib/idejo_hub/identity/zitadel.ex")
    assert zitadel =~ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE"
    refute zitadel =~ "OIDC_GRANT_TYPE_PASSWORD"
    env = forum_with_client("id09-club") |> env()
    refute Enum.any?(env, fn {k, _} -> k =~ ~r/PASSWORD/ and k != "IDEJO_SMTP_PASSWORD" end)
  end

  @tag req: "HN-01"
  test "HN-01 one wildcard record for forums, records for the Hub and sign-in: no DNS change per forum" do
    docs = read("docs/deploying.md")

    assert docs =~
             "Point **three records** at the server, once. Adding a forum never needs a DNS change."

    assert docs =~ "| `*.forums.example.org` | A (and AAAA for IPv6) |"
    # Forums are reached through the one wildcard site; the Hub has no DNS code at all.
    assert read("deploy/Caddyfile") =~ "*.{$IDEJO_FORUM_DOMAIN} {"
    assert Path.wildcard(Path.join(@root, "lib/**/*dns*.ex")) == []
  end

  @tag req: "HN-08"
  test "HN-08 the Hub deploys with one Compose file and an install script, on Debian 13" do
    assert Path.wildcard(Path.join(@root, "deploy/*compose*.y*ml")) == [
             Path.join(@root, "deploy/docker-compose.yml")
           ]

    install = read("deploy/install.sh")
    assert install =~ ~s([ "${ID:-}" = debian ] && [ "${VERSION_ID:-}" = 13 ])
    # An update's new Caddyfile (a mounted file `up` does not notice) is loaded.
    assert install =~ "exec -T caddy caddy reload --config /etc/caddy/Caddyfile"
    # Before the health checks' wait, which stops the script when a service is slow.
    [before_wait, _] = String.split(install, ~s("${COMPOSE[@]}" up -d --wait\n), parts: 2)
    assert before_wait =~ "caddy reload"
    assert read("docs/deploying.md") =~ "Debian 13 (trixie)"
    # deploy/test/hn_08_install_settings.sh runs the installer's settings step in CI.
    assert File.exists?(Path.join(@root, "deploy/test/hn_08_install_settings.sh"))
  end

  @tag req: "NF-06"
  test "NF-06 the Hub release states the Idejo versions it supports, its default among them" do
    default = Application.fetch_env!(:idejo_hub, Forums)[:default_version]
    # The test config starts forums on 0.1.0; production's default is runtime.exs'.
    [_, production] =
      Regex.run(~r/IDEJO_DEFAULT_VERSION", "([0-9.]+)"/, read("config/runtime.exs"))

    assert default

    for doc <- ["README.md", "docs/deploying.md"] do
      assert read(doc) =~ "## Supported Idejo versions", doc
      assert read(doc) =~ "**Idejo #{production}**", doc
    end
  end

  @tag req: "LB-01"
  test "LB-01 the Hub is its own repository and release, apart from Idejo" do
    mix = read("mix.exs")
    assert mix =~ "app: :idejo_hub"
    assert [_, _version] = Regex.run(~r/version: "([0-9.]+)"/, mix)
    # It depends on no Idejo code: Idejo is only an image, driven through its contract.
    refute mix =~ ~r/\{:idejo,/
    assert File.exists?(Path.join(@root, "LICENSE"))
  end

  @tag req: "LB-03"
  test "LB-03 every forum's Source code link points to the exact Idejo version it runs" do
    forum = running_forum("lb03-club")
    assert env(forum)["IDEJO_SOURCE_URL"] == "https://github.com/callisto-rpg/Idejo/tree/v0.1.0"

    {:ok, forum} = Forums.update_state(forum, %{idejo_version: "0.2.0"})
    assert env(forum)["IDEJO_SOURCE_URL"] == "https://github.com/callisto-rpg/Idejo/tree/v0.2.0"
  end

  # A forum registered at the identity provider (fake), as milestone 3 makes them.
  defp forum_with_client(subdomain) do
    forum = running_forum(subdomain)
    secret = IdejoHub.Secrets.encrypt("s3cret", Forums.context(subdomain, :oidc_client_secret))

    {:ok, forum} =
      Forums.update_state(forum, %{
        oidc_client_id: "client-#{subdomain}",
        oidc_client_secret_enc: secret
      })

    forum
  end
end
