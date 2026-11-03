# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule DockerGuard.Router do
  @moduledoc """
  The guard's only endpoint: every request is decided by `DockerGuard.Policy`, then either
  refused with 403 or forwarded unchanged (apart from a rewritten query, when the policy
  asks for one) to the socket proxy, streaming both ways.

  Refusals are logged with the method, the path and the rule, never the body, which holds
  forum secrets.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias DockerGuard.{Policy, Upstream}
  alias Plug.Conn.Query

  # JSON bodies the policy reads (create, exec, volumes) are small; anything bigger is refused.
  @max_json_body 1_000_000
  @api_version ~r/\Av1\.\d{1,3}\z/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    Upstream.clear_body_conn()
    route(conn, opts)
  end

  defp route(%{path_info: [version | path]} = conn, _opts) do
    if Regex.match?(@api_version, version),
      do: decide(fetch_query_params(conn), version, path),
      else: deny(conn, :api_version)
  end

  defp route(conn, _opts), do: deny(conn, :api_version)

  defp decide(conn, version, path) do
    case read_json(conn, path) do
      {:ok, body, raw, conn} ->
        req = %{method: conn.method, path: path, query: conn.query_params, body: body}

        case Policy.check(req, config(), Upstream.lookup(version)) do
          :ok -> forward(conn, conn.query_string, raw)
          {:ok, %{query: query}} -> forward(conn, Query.encode(query), raw)
          {:deny, rule} -> deny(conn, rule)
        end

      {:deny, rule, conn} ->
        deny(conn, rule)
    end
  end

  # Bodies the policy must see are read whole and decoded; others are passed on as they are
  # (an archive upload is streamed, everything else is small).
  defp read_json(conn, path) do
    cond do
      Policy.needs_body?(conn.method, path) ->
        with {:ok, raw, conn} <- read_small(conn), do: decode(raw, conn)

      conn.method == "PUT" ->
        {:ok, nil, {:stream, body_stream(conn)}, conn}

      true ->
        with {:ok, raw, conn} <- read_small(conn), do: {:ok, nil, raw, conn}
    end
  end

  defp read_small(conn) do
    case read_body(conn, length: @max_json_body) do
      {:ok, raw, conn} -> {:ok, raw, conn}
      {:more, _partial, conn} -> {:deny, :body_too_large, conn}
      {:error, _reason} -> {:deny, :body_unreadable, conn}
    end
  end

  defp decode("", conn), do: {:ok, nil, "", conn}

  defp decode(raw, conn) do
    case Jason.decode(raw) do
      {:ok, body} when is_map(body) -> {:ok, body, raw, conn}
      _other -> {:deny, :body_not_json, conn}
    end
  end

  # Read while the request goes upstream (in this process). Each read returns a new conn
  # that knows how much of the body is read; the answer must go out on the last one
  # (`Upstream.body_conn/1`), or the server thinks the body is unread, waits for it to keep
  # the connection, times out and closes it under the Hub's next call (M2 exit check).
  defp body_stream(conn) do
    Stream.unfold(conn, fn
      :done ->
        nil

      conn ->
        case read_body(conn, length: 1_000_000, read_length: 1_000_000) do
          {:ok, data, conn} ->
            Upstream.put_body_conn(conn)
            {data, :done}

          {:more, data, conn} ->
            Upstream.put_body_conn(conn)
            {data, conn}

          {:error, _reason} ->
            nil
        end
    end)
  end

  defp forward(conn, query_string, body) do
    target =
      if query_string == "", do: conn.request_path, else: conn.request_path <> "?" <> query_string

    # A streamed upload keeps its length, so it goes on as a plain body, not chunked.
    headers =
      for name <- ["content-type", "content-length"],
          [value | _] <- [get_req_header(conn, name)],
          name == "content-type" or match?({:stream, _}, body),
          do: {name, value}

    case Upstream.stream(conn.method, target, headers, body, conn) do
      {:ok, conn} ->
        conn

      {:error, reason} ->
        Logger.error(
          "docker-guard: upstream failed for #{conn.method} #{conn.request_path}: #{inspect(reason)}"
        )

        error(conn, 502, "docker-guard: Docker is unreachable")
    end
  end

  # A container or exec that does not exist is reported as Docker would, so the Hub can tell
  # "already gone" from "refused".
  defp deny(conn, rule) when rule in [:unknown_container, :unknown_exec] do
    error(
      conn,
      404,
      "docker-guard: no such #{if rule == :unknown_exec, do: "exec instance", else: "container"}"
    )
  end

  defp deny(conn, rule) do
    Logger.warning("docker-guard: denied #{conn.method} #{conn.request_path} (#{rule})")
    error(conn, 403, "docker-guard: denied (#{rule})")
  end

  defp error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{message: message}))
    |> halt()
  end

  defp config do
    %{
      image: Application.fetch_env!(:docker_guard, :image),
      network: Application.fetch_env!(:docker_guard, :network)
    }
  end
end
