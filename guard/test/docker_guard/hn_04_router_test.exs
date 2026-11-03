# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule DockerGuard.HN04RouterTest do
  @moduledoc "HN-04: docker-guard forwards allowed calls to the socket proxy and refuses the rest."
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias DockerGuard.Router

  @moduletag req: "HN-04"
  @moduletag :capture_log

  defp call(method, path, body \\ nil) do
    conn =
      if body,
        do:
          method
          |> conn(path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, path)

    Router.call(conn, [])
  end

  # The socket proxy: answers inspects, and records what reached it.
  defp stub_upstream(test_pid) do
    Req.Test.stub(DockerGuard.Upstream, fn conn ->
      case {conn.method, conn.path_info} do
        {"GET", [_v, "containers", "idejo-forum-tennis", "json"]} ->
          Req.Test.json(conn, %{"Config" => %{"Labels" => %{"org.idejo.hub.forum" => "tennis"}}})

        {"GET", [_v, "containers", "caddy", "json"]} ->
          Req.Test.json(conn, %{"Config" => %{"Labels" => %{}}})

        _other ->
          {:ok, body, conn} = read_body(conn)
          send(test_pid, {:upstream, conn.method, conn.request_path, conn.query_string, body})

          conn
          |> put_resp_content_type("application/vnd.docker.raw-stream")
          |> send_resp(200, "streamed output")
      end
    end)
  end

  setup do
    stub_upstream(self())
    :ok
  end

  test "an allowed call is forwarded unchanged and the answer streamed back" do
    conn = call(:post, "/v1.44/containers/idejo-forum-tennis/start")
    assert conn.status == 200
    assert conn.resp_body == "streamed output"
    assert_received {:upstream, "POST", "/v1.44/containers/idejo-forum-tennis/start", "", ""}
  end

  test "a privileged create never reaches the proxy" do
    body = %{
      "Image" => "ghcr.io/callisto-rpg/idejo:0.1.0",
      "Labels" => %{"org.idejo.hub.forum" => "tennis"},
      "HostConfig" => %{
        "Privileged" => true,
        "Memory" => 1,
        "NanoCpus" => 1,
        "NetworkMode" => "idejo-forums"
      }
    }

    conn = call(:post, "/v1.44/containers/create?name=idejo-forum-tennis", body)
    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["message"] =~ "host_config_key"
    refute_received {:upstream, _, _, _, _}
  end

  test "another container cannot be inspected (its environment holds secrets)" do
    conn = call(:get, "/v1.44/containers/caddy/json")
    assert conn.status == 403
    refute_received {:upstream, _, _, _, _}
  end

  test "a container that does not exist is 404, as from Docker" do
    Req.Test.stub(DockerGuard.Upstream, fn conn ->
      conn |> put_status(404) |> Req.Test.json(%{"message" => "No such container"})
    end)

    assert call(:delete, "/v1.44/containers/idejo-forum-gone").status == 404
  end

  test "the listing query is rewritten to forum containers" do
    conn = call(:get, ~s(/v1.44/containers/json?all=1&filters={"name":["caddy"]}))
    assert conn.status == 200
    assert_received {:upstream, "GET", "/v1.44/containers/json", query, ""}
    assert %{"all" => "1", "filters" => filters} = URI.decode_query(query)
    assert Jason.decode!(filters) == %{"label" => ["org.idejo.hub.forum"]}
  end

  test "requests without an API version are refused" do
    assert call(:get, "/containers/json").status == 403
    assert call(:get, "/").status == 403
  end

  test "an exec body that is not JSON is refused" do
    conn =
      :post
      |> conn("/v1.44/containers/idejo-forum-tennis/exec", "not json")
      |> Router.call([])

    assert conn.status == 403
  end

  test "an archive upload keeps its length on the way to the proxy" do
    Req.Test.stub(DockerGuard.Upstream, fn conn ->
      case {conn.method, conn.path_info} do
        {"GET", [_v, "containers", "idejo-forum-tennis", "json"]} ->
          Req.Test.json(conn, %{"Config" => %{"Labels" => %{"org.idejo.hub.forum" => "tennis"}}})

        {"PUT", _} ->
          {:ok, body, conn} = read_body(conn)
          send(self(), {:put, get_req_header(conn, "content-length"), byte_size(body)})
          send_resp(conn, 200, "")
      end
    end)

    body = String.duplicate("t", 5000)

    conn =
      :put
      |> conn("/v1.44/containers/idejo-forum-tennis/archive?path=/data/backups", body)
      |> put_req_header("content-type", "application/x-tar")
      |> put_req_header("content-length", "5000")
      |> Router.call([])

    assert conn.status == 200
    assert_received {:put, ["5000"], 5000}
  end
end
