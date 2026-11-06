# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.HN06OwnContainersTest do
  @moduledoc """
  HN-06: the Hub and the identity provider run in their own containers, with their own
  database. Read from the bundle (deploy/docker-compose.yml and its postgres-init scripts);
  deploy/test/hn_06_databases.sh starts the bundle's PostgreSQL and checks the same by
  connecting as each role.

  Their databases sit on the PostgreSQL server the forums share (Hub spec §3, HN-05), each
  with its own role that may open only its own database. The one sanctioned crossing: the
  Hub holds Zitadel's database password to back it up (OP-10, steward decision 2026-11-04).
  """
  use ExUnit.Case, async: true

  @moduletag req: "HN-06"

  @deploy Path.expand("../../../deploy", __DIR__)

  setup_all do
    {:ok, compose} = YamlElixir.read_from_file(Path.join(@deploy, "docker-compose.yml"))
    init = fn name -> File.read!(Path.join([@deploy, "postgres-init", name])) end
    %{services: compose["services"], init: init}
  end

  test "HN-06 the Hub and Zitadel are containers of their own, from their own images", %{
    services: services
  } do
    hub = services["hub"]
    zitadel = services["zitadel"]

    # The Hub is built from this repository; Zitadel is its published, pinned image.
    assert hub["build"]["dockerfile"] == "Dockerfile"
    refute Map.has_key?(hub, "image")
    assert zitadel["image"] =~ ~r"^ghcr\.io/zitadel/zitadel:v[0-9.]+@sha256:[0-9a-f]{64}$"

    # Neither shares another container's namespaces.
    for service <- [hub, zitadel], key <- ~w(network_mode pid ipc) do
      refute Map.has_key?(service, key), "#{key} in #{inspect(Map.keys(service))}"
    end

    # Zitadel gets no Docker access and no way to the forums: only the default network.
    assert Map.get(zitadel, "networks", ["default"]) == ["default"]
    refute Enum.any?(zitadel["volumes"] || [], &(&1 =~ "docker.sock"))
  end

  test "HN-06 each connects to its own database, as its own role", %{services: services} do
    assert services["hub"]["environment"]["DATABASE_URL"] ==
             "ecto://idejo_hub:${HUB_DB_PASSWORD}@db/idejo_hub"

    env = services["zitadel"]["environment"]
    assert env["ZITADEL_DATABASE_POSTGRES_DATABASE"] == "zitadel"
    assert env["ZITADEL_DATABASE_POSTGRES_ADMIN_EXISTINGDATABASE"] == "zitadel"

    # Its "admin" connection is its own role too, never the server's superuser.
    for user <- ~w(USER ADMIN) do
      assert env["ZITADEL_DATABASE_POSTGRES_#{user}_USERNAME"] == "zitadel"
      assert env["ZITADEL_DATABASE_POSTGRES_#{user}_PASSWORD"] == "${ZITADEL_DB_PASSWORD}"
    end

    # The superuser's password goes to the database server alone.
    holders = for {name, s} <- services, inspect(s) =~ "POSTGRES_PASSWORD", do: name
    assert holders == ["db"]
  end

  test "HN-06 the init scripts make each its own role and database, closed to others", %{
    init: init
  } do
    hub = init.("01-hub-role.sh")
    assert hub =~ "CREATE ROLE idejo_hub LOGIN CREATEDB CREATEROLE NOSUPERUSER"
    assert hub =~ "CREATE DATABASE idejo_hub OWNER idejo_hub;"
    assert hub =~ "REVOKE ALL ON DATABASE idejo_hub FROM PUBLIC;"

    zitadel = init.("04-zitadel.sh")
    assert zitadel =~ "CREATE ROLE zitadel LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE"
    assert zitadel =~ "CREATE DATABASE zitadel OWNER zitadel;"
    assert zitadel =~ "REVOKE ALL ON DATABASE zitadel FROM PUBLIC;"

    # Over the network, a role opens only the database named after it.
    assert init.("02-forum-isolation.sh") =~ "host sameuser all all scram-sha-256"
  end
end
