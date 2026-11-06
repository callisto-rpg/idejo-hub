# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.NF05HubDownTest do
  @moduledoc """
  NF-05: the Hub being down does not take forums down. Nothing on a forum's way depends on
  the Hub: Caddy proxies forum hosts straight to their containers and reads suspensions from
  files, forums sign in through Zitadel, and keep their own sessions. Read here from the
  bundle and from what the Hub gives a forum; deploy/test/m3/run.sh (step 6b) stops the Hub
  and checks the forum, a member's session and Zitadel in a browser.
  """
  use ExUnit.Case, async: true

  alias IdejoHub.Hosting.ForumContainer

  @moduletag req: "NF-05"

  @deploy Path.expand("../../../deploy", __DIR__)

  setup_all do
    {:ok, compose} = YamlElixir.read_from_file(Path.join(@deploy, "docker-compose.yml"))
    %{services: compose["services"], caddyfile: File.read!(Path.join(@deploy, "Caddyfile"))}
  end

  # The Caddyfile's site block for `host`, without comments.
  defp site(caddyfile, host) do
    [_, rest] = String.split(caddyfile, "\n" <> host <> " {\n", parts: 2)
    [block | _] = String.split(rest, "\n}\n", parts: 2)

    block
    |> String.split("\n")
    |> Enum.reject(&(String.trim(&1) |> String.starts_with?("#")))
    |> Enum.join("\n")
  end

  test "NF-05 Caddy starts and runs whatever state the Hub is in", %{services: services} do
    refute Map.has_key?(services["caddy"]["depends_on"] || %{}, "hub")
    assert services["caddy"]["restart"] == "unless-stopped"
    # Zitadel and its login screen neither.
    for name <- ~w(zitadel zitadel-login) do
      refute Map.has_key?(services[name]["depends_on"] || %{}, "hub"), name
    end
  end

  test "NF-05 forum hosts go straight to their forum; suspension is a file Caddy reads", %{
    caddyfile: caddyfile
  } do
    forums = site(caddyfile, "*.{$IDEJO_FORUM_DOMAIN}")

    # The Hub appears only once a forum itself has failed (502 to 504): its page saying so.
    [serving, errors] = String.split(forums, "handle_errors 502 503 504 {", parts: 2)
    refute serving =~ "hub:"
    assert errors =~ "rewrite * /internal/forum-unavailable"
    assert forums =~ "reverse_proxy idejo-forum-{re.forum.1}:4000"
    assert forums =~ "root /srv/forum-state/suspended"

    # Sign-in is Zitadel's; only the member page (/account) is the Hub's.
    identity = site(caddyfile, "{$IDEJO_ID_DOMAIN}")
    assert identity =~ "reverse_proxy h2c://zitadel:8080"
    assert identity =~ "reverse_proxy zitadel-login:3000"
    assert Regex.scan(~r/reverse_proxy hub:4000/, identity) |> length() == 1
    assert identity =~ "handle /account* {\n\t\treverse_proxy hub:4000"
  end

  test "NF-05 a forum's container needs nothing from the Hub to run" do
    spec =
      ForumContainer.spec(%{
        slug: "nf05",
        version: "0.2.3",
        env: %{
          "PHX_HOST" => "nf05.idejo.test",
          "IDEJO_OIDC_ISSUER" => IdejoHub.Identity.issuer(),
          "IDEJO_COMMUNITY_URL" => IdejoHub.Community.community_url()
        },
        memory_mb: 384,
        cpus: 0.5
      })

    # Docker restarts it by itself; it reaches no Hub address.
    assert spec["HostConfig"]["RestartPolicy"] == %{"Name" => "unless-stopped"}
    # The one Hub address a forum holds is Idejo's community menu (steward decision
    # 2026-11-06), which the browser fills only when it is opened, gives up after two seconds
    # and keeps an empty answer: with the Hub down, the menu lists nothing, the forum runs.
    hub_addresses =
      Enum.filter(spec["Env"], &(&1 =~ ~r{hub:4000|//hub[:/]}))
      |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))

    assert hub_addresses -- ["IDEJO_COMMUNITY_URL"] == []
    # It signs in through the identity provider's host, Zitadel's, not the Hub's.
    assert ("IDEJO_OIDC_ISSUER=https://" <>
              Application.fetch_env!(:idejo_hub, IdejoHub.Identity)[:domain]) in spec["Env"]
  end
end
