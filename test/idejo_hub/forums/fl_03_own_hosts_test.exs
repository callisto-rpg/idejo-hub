# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.FL03OwnHostsTest do
  @moduledoc """
  FL-03: with the Hub or its sign-in one label under the forum domain (`hub.example.com`,
  `login.example.com`, forums on `example.com`), those labels can never be forum names.
  """
  use IdejoHub.DataCase, async: false

  alias IdejoHub.Forums
  alias IdejoHub.Forums.Subdomain

  @moduletag req: "FL-03"

  setup do
    endpoint = Application.fetch_env!(:idejo_hub, IdejoHubWeb.Endpoint)
    identity = Application.fetch_env!(:idejo_hub, IdejoHub.Identity)

    on_exit(fn ->
      Application.put_env(:idejo_hub, IdejoHubWeb.Endpoint, endpoint)
      Application.put_env(:idejo_hub, IdejoHub.Identity, identity)
    end)

    # Forums are on idejo.test in tests; put the Hub and its sign-in under it, with labels
    # that are not on the fixed reserved list.
    url = Keyword.put(endpoint[:url] || [], :host, "control.idejo.test")
    Application.put_env(:idejo_hub, IdejoHubWeb.Endpoint, Keyword.put(endpoint, :url, url))

    Application.put_env(
      :idejo_hub,
      IdejoHub.Identity,
      Keyword.put(identity, :domain, "members.idejo.test")
    )

    :ok
  end

  test "only hosts exactly one label under the forum domain count" do
    hosts = [
      "hub.example.com",
      "LOGIN.example.com",
      "id.hub.example.com",
      "example.com",
      "hub.other.org",
      nil,
      "xexample.com"
    ]

    assert Subdomain.labels_under(hosts, "example.com") == ["hub", "login"]
    assert Subdomain.labels_under(["hub.example.org"], "forums.example.org") == []
  end

  test "the Hub's own labels are refused, with a reason" do
    assert Subdomain.own_labels() == ["control", "members"]
    assert Subdomain.validate("control") == {:error, "is the address of the Hub or its sign-in"}
    assert Subdomain.validate("members") == {:error, "is the address of the Hub or its sign-in"}
    assert Subdomain.validate("tennis") == :ok
  end

  test "no forum can be created with them, and their hosts are never a forum's" do
    attrs = %{"subdomain" => "control", "display_name" => "F", "owner_email" => "o@example.test"}
    assert {:error, changeset} = Forums.create_forum(attrs, "operator")
    assert {"is the address of the Hub or its sign-in", _} = changeset.errors[:subdomain]

    assert Forums.for_host("control.idejo.test") == nil
    assert Forums.certificate_allowed?("control.idejo.test")
  end

  test "nothing extra is refused when the Hub is elsewhere" do
    url = [host: "hub.example.org"]

    Application.put_env(
      :idejo_hub,
      IdejoHubWeb.Endpoint,
      Keyword.put(Application.fetch_env!(:idejo_hub, IdejoHubWeb.Endpoint), :url, url)
    )

    Application.put_env(
      :idejo_hub,
      IdejoHub.Identity,
      Keyword.put(
        Application.fetch_env!(:idejo_hub, IdejoHub.Identity),
        :domain,
        "id.hub.example.org"
      )
    )

    assert Subdomain.own_labels() == []
    assert Subdomain.validate("control") == :ok
  end
end
