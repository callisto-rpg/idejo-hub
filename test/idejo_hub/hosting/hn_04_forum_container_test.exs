# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.HN04ForumContainerTest do
  @moduledoc "HN-04: one container per forum, own environment, volumes and limits."
  use ExUnit.Case, async: true

  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.ForumContainer

  @moduletag req: "HN-04"

  @params %{
    slug: "tennis",
    version: "0.1.0",
    env: %{
      "PHX_HOST" => "tennis.idejo.test",
      "DATABASE_URL" => "ecto://forum_tennis:secret@db/forum_tennis",
      "SECRET_KEY_BASE" => String.duplicate("k", 64),
      "IDEJO_UPLOADS_DIR" => "/somewhere/else"
    },
    memory_mb: 256,
    cpus: 0.5
  }

  setup do
    Fake.start()
    :ok
  end

  describe "spec/1" do
    test "the official image at the exact version, with memory and CPU limits" do
      spec = ForumContainer.spec(@params)
      assert spec["Image"] == "ghcr.io/callisto-rpg/idejo:0.1.0"
      assert spec["HostConfig"]["Memory"] == 256 * 1024 * 1024
      assert spec["HostConfig"]["NanoCpus"] == 500_000_000
      assert spec["Labels"] == %{"org.idejo.hub.forum" => "tennis"}
    end

    test "its own volumes, and the fixed directories win over the caller's" do
      spec = ForumContainer.spec(@params)

      assert [
               %{"Source" => "idejo-forum-tennis-uploads", "Target" => "/data/uploads"},
               %{"Source" => "idejo-forum-tennis-backups", "Target" => "/data/backups"}
             ] = spec["HostConfig"]["Mounts"]

      assert "IDEJO_UPLOADS_DIR=/data/uploads" in spec["Env"]
      refute "IDEJO_UPLOADS_DIR=/somewhere/else" in spec["Env"]
      assert "PHX_HOST=tennis.idejo.test" in spec["Env"]
    end

    test "what the Hub sends is what docker-guard allows" do
      config = %{image: "ghcr.io/callisto-rpg/idejo", network: "idejo-forums"}
      lookup = %{container_labels: fn _ -> :error end, exec_container: fn _ -> :error end}
      # The guard sees the body as JSON.
      body = @params |> ForumContainer.spec() |> Jason.encode!() |> Jason.decode!()

      create = %{
        method: "POST",
        path: ["containers", "create"],
        query: %{"name" => ForumContainer.name("tennis")},
        body: body
      }

      assert DockerGuard.Policy.check(create, config, lookup) == :ok

      for volume <- Map.values(ForumContainer.volumes("tennis")) do
        req = %{
          method: "POST",
          path: ["volumes", "create"],
          query: %{},
          body: %{"Name" => volume, "Labels" => %{"org.idejo.hub.forum" => "tennis"}}
        }

        assert DockerGuard.Policy.check(req, config, lookup) == :ok
      end

      pull = %{
        method: "POST",
        path: ["images", "create"],
        query: %{"fromImage" => ForumContainer.image("0.1.0")},
        body: nil
      }

      assert DockerGuard.Policy.check(pull, config, lookup) == :ok
    end
  end

  describe "provision/1" do
    test "pulls the image and creates the volumes and a stopped container" do
      assert {:ok, "idejo-forum-tennis"} = ForumContainer.provision(@params)

      state = Fake.state()
      assert MapSet.member?(state.images, "ghcr.io/callisto-rpg/idejo:0.1.0")

      assert Map.keys(state.volumes) == [
               "idejo-forum-tennis-backups",
               "idejo-forum-tennis-uploads"
             ]

      assert %{"Running" => false} = state.containers["idejo-forum-tennis"]
    end

    test "removes what it created when a step fails" do
      Fake.fail(:create_container, {:denied, "docker-guard: denied (image)"})

      assert {:error, {:denied, _}} = ForumContainer.provision(@params)

      state = Fake.state()
      assert state.volumes == %{}
      assert state.containers == %{}
    end

    test "a failed pull creates nothing" do
      Fake.fail(:pull_image, :not_found)

      assert {:error, {:image_unavailable, "ghcr.io/callisto-rpg/idejo:0.1.0"}} =
               ForumContainer.provision(@params)

      assert Fake.state().calls == [:pull_image]
    end
  end

  describe "remove/2" do
    test "removes the container, and the volumes only when asked" do
      {:ok, _id} = ForumContainer.provision(@params)

      assert ForumContainer.remove("tennis") == :ok
      assert Fake.state().containers == %{}
      assert map_size(Fake.state().volumes) == 2

      assert ForumContainer.remove("tennis", volumes: true) == :ok
      assert Fake.state().volumes == %{}
    end
  end
end
