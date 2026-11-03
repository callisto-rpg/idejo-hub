# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.HN04DockerEngineTest do
  @moduledoc "HN-04: the engine adapter speaks the Docker API through docker-guard."
  use ExUnit.Case, async: true

  import Plug.Conn

  alias IdejoHub.Hosting.Docker.Engine

  @moduletag req: "HN-04"

  defp stub(fun), do: Req.Test.stub(Engine, fun)

  test "calls are versioned and go to docker-guard" do
    stub(fn conn ->
      assert conn.request_path == "/v1.44/_ping"
      send_resp(conn, 200, "OK")
    end)

    assert Engine.ping() == :ok
  end

  test "a refusal by docker-guard is reported as denied" do
    stub(fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, ~s|{"message":"docker-guard: denied (image)"}|)
    end)

    assert Engine.create_container("idejo-forum-tennis", %{}) ==
             {:error, {:denied, "docker-guard: denied (image)"}}
  end

  test "a missing container is :not_found" do
    stub(fn conn -> send_resp(conn, 404, ~s({"message":"No such container"})) end)
    assert Engine.inspect_container("idejo-forum-gone") == {:error, :not_found}
  end

  test "exec returns the exit code and the demultiplexed output" do
    stdout = "backup written: idejo-20261103.tar\n"
    stderr = "warning\n"

    stream =
      <<1, 0, 0, 0, byte_size(stdout)::32>> <>
        stdout <> <<2, 0, 0, 0, byte_size(stderr)::32>> <> stderr

    stub(fn conn ->
      case {conn.method, conn.path_info} do
        {"POST", ["v1.44", "containers", "idejo-forum-tennis", "exec"]} ->
          {:ok, body, conn} = read_body(conn)
          assert Jason.decode!(body)["Cmd"] == ["/app/bin/idejo-admin", "backup"]
          Req.Test.json(conn, %{"Id" => "e1"})

        {"POST", ["v1.44", "exec", "e1", "start"]} ->
          conn
          |> put_resp_content_type("application/vnd.docker.raw-stream")
          |> send_resp(200, stream)

        {"GET", ["v1.44", "exec", "e1", "json"]} ->
          Req.Test.json(conn, %{"ExitCode" => 0})
      end
    end)

    assert Engine.exec("idejo-forum-tennis", ["/app/bin/idejo-admin", "backup"]) ==
             {:ok, %{exit_code: 0, output: stdout <> stderr}}
  end

  test "a pull that fails while streaming is an error" do
    stub(fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"status":"Pulling"}\n{"error":"manifest unknown"}\n))
    end)

    assert Engine.pull_image("ghcr.io/callisto-rpg/idejo:9.9.9") ==
             {:error, {:status, 500, "manifest unknown"}}
  end

  describe "copy_from/3 (FL-06)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "copy-from-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp tar_of(entries) do
      tmp = Path.join(System.tmp_dir!(), "t-#{System.unique_integer([:positive])}.tar")
      :ok = :erl_tar.create(String.to_charlist(tmp), entries)
      bytes = File.read!(tmp)
      File.rm!(tmp)
      bytes
    end

    defp serve(bytes) do
      stub(fn conn ->
        conn |> put_resp_content_type("application/x-tar") |> send_resp(200, bytes)
      end)
    end

    test "extracts the one file asked for", %{dir: dir} do
      serve(tar_of([{~c"idejo-1.tar", "backup bytes"}]))

      assert {:ok, path} =
               Engine.copy_from("idejo-forum-x-export", "/data/backups/idejo-1.tar", dir)

      assert path == Path.join(dir, "idejo-1.tar")
      assert File.read!(path) == "backup bytes"
    end

    test "refuses other names, extra entries and paths", %{dir: dir} do
      for entries <- [
            [{~c"other.tar", "x"}],
            [{~c"idejo-1.tar", "x"}, {~c"extra", "y"}],
            [{~c"../idejo-1.tar", "x"}]
          ] do
        serve(tar_of(entries))

        assert {:error, {:archive, _}} =
                 Engine.copy_from("idejo-forum-x-export", "/data/backups/idejo-1.tar", dir)
      end

      refute File.exists?(Path.join(Path.dirname(dir), "idejo-1.tar"))
    end
  end
end
