# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.S3Fake do
  @moduledoc """
  OP-02 tests: an S3 bucket in memory behind `Req.Test` (`IdejoHub.Operations.Offsite`).
  Answers put, list (v2), delete and multipart uploads; refuses unsigned requests (403).
  `fail/1` makes every put answer 500.
  """
  import Plug.Conn

  @name __MODULE__

  def start do
    if Process.whereis(@name), do: Agent.stop(@name)

    {:ok, _} =
      Agent.start(fn -> %{objects: %{}, uploads: %{}, requests: [], fail: false} end, name: @name)

    Req.Test.stub(IdejoHub.Operations.Offsite, &call/1)
    :ok
  end

  def objects, do: Agent.get(@name, & &1.objects)
  def requests, do: Agent.get(@name, &Enum.reverse(&1.requests))
  def put_object(key, body), do: Agent.update(@name, &put_in(&1, [:objects, key], body))
  def fail(on?), do: Agent.update(@name, &%{&1 | fail: on?})

  def call(conn) do
    conn = fetch_query_params(conn)
    {body, conn} = read_all(conn, "")
    [bucket | rest] = conn.path_info
    key = Enum.join(rest, "/")
    q = conn.query_params
    signed? = match?(["AWS4-HMAC-SHA256 " <> _], get_req_header(conn, "authorization"))
    Agent.update(@name, &%{&1 | requests: [{conn.method, bucket, key, q} | &1.requests]})
    state = Agent.get(@name, & &1)

    cond do
      not signed? -> send_resp(conn, 403, "unsigned")
      state.fail and conn.method in ["PUT", "POST"] -> send_resp(conn, 500, "")
      true -> answer(conn, conn.method, key, q, body)
    end
  end

  defp answer(conn, "GET", "", %{"list-type" => "2", "prefix" => prefix}, _body) do
    keys = objects() |> Map.keys() |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort()
    xml = Enum.map_join(keys, &"<Contents><Key>#{&1}</Key></Contents>")

    send_resp(
      conn,
      200,
      "<ListBucketResult>#{xml}<IsTruncated>false</IsTruncated></ListBucketResult>"
    )
  end

  defp answer(conn, "POST", key, %{"uploads" => _}, _body) do
    id = "upload-#{System.unique_integer([:positive])}"
    Agent.update(@name, &put_in(&1, [:uploads, id], %{key: key, parts: %{}}))

    send_resp(
      conn,
      200,
      "<InitiateMultipartUploadResult><UploadId>#{id}</UploadId></InitiateMultipartUploadResult>"
    )
  end

  defp answer(conn, "PUT", _key, %{"partNumber" => n, "uploadId" => id}, body) do
    Agent.update(@name, &put_in(&1, [:uploads, id, :parts, String.to_integer(n)], body))
    conn |> put_resp_header("etag", ~s("etag-#{n}")) |> send_resp(200, "")
  end

  defp answer(conn, "POST", key, %{"uploadId" => id}, body) do
    %{parts: parts} = Agent.get(@name, & &1.uploads[id])

    listed =
      for [_, n] <- Regex.scan(~r"<PartNumber>(\d+)</PartNumber>", body), do: String.to_integer(n)

    true = listed == Enum.sort(Map.keys(parts))
    data = listed |> Enum.map(&parts[&1]) |> IO.iodata_to_binary()
    Agent.update(@name, fn s -> %{s | uploads: Map.delete(s.uploads, id)} end)
    put_object(key, data)
    send_resp(conn, 200, "<CompleteMultipartUploadResult/>")
  end

  defp answer(conn, "DELETE", _key, %{"uploadId" => id}, _body) do
    Agent.update(@name, fn s -> %{s | uploads: Map.delete(s.uploads, id)} end)
    send_resp(conn, 204, "")
  end

  defp answer(conn, "PUT", key, _q, body) do
    put_object(key, body)
    send_resp(conn, 200, "")
  end

  defp answer(conn, "DELETE", key, _q, _body) do
    Agent.update(@name, fn s -> %{s | objects: Map.delete(s.objects, key)} end)
    send_resp(conn, 204, "")
  end

  defp read_all(conn, acc) do
    case read_body(conn) do
      {:ok, data, conn} -> {acc <> data, conn}
      {:more, data, conn} -> read_all(conn, acc <> data)
    end
  end
end
