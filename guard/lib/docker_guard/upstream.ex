# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule DockerGuard.Upstream do
  @moduledoc """
  HTTP to the socket proxy, over the Unix socket the two containers share
  (`:upstream_socket`). In tests, `:req_options` points Req at a `Req.Test` stub instead.
  """

  import Plug.Conn

  # Long enough for `wait`, a followed log or a long `idejo-admin backup` streamed by exec.
  @receive_timeout :timer.hours(1)

  @doc "The lookups `DockerGuard.Policy` needs, through the proxy, for one API version."
  @spec lookup(String.t()) :: DockerGuard.Policy.lookup()
  def lookup(version) do
    %{
      container_labels: fn id ->
        with {:ok, %{"Config" => config}} <-
               get_json("/#{version}/containers/#{segment(id)}/json") do
          {:ok, config["Labels"] || %{}}
        end
      end,
      exec_container: fn id ->
        case get_json("/#{version}/exec/#{segment(id)}/json") do
          {:ok, %{"ContainerID" => container}} when is_binary(container) -> {:ok, container}
          _other -> :error
        end
      end
    }
  end

  defp get_json(path) do
    case Req.request(req(), method: :get, url: path) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      _other -> :error
    end
  end

  @doc """
  Sends one request upstream and streams the answer into `conn`. Returns the sent conn, or an
  error when the proxy could not be reached (nothing has been sent then).
  """
  @spec stream(
          String.t(),
          String.t(),
          [{String.t(), String.t()}],
          iodata() | {:stream, Enumerable.t()},
          Plug.Conn.t()
        ) ::
          {:ok, Plug.Conn.t()} | {:error, term()}
  def stream(method, target, headers, body, conn) do
    body = if match?({:stream, _}, body), do: elem(body, 1), else: body

    result =
      Req.request(req(),
        method: method |> String.downcase() |> String.to_existing_atom(),
        url: target,
        headers: headers,
        body: body,
        into: fn chunk, acc -> into_conn(chunk, acc, conn) end
      )

    case result do
      {:ok, %Req.Response{private: %{conn: conn}}} ->
        {:ok, conn}

      {:ok, %Req.Response{} = resp} ->
        {:ok, conn |> copy_headers(resp) |> send_resp(resp.status, "")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # First chunk: send status and headers, then stream every chunk as it arrives (exec
  # output, logs and archives are not buffered).
  defp into_conn({:data, data}, {req, resp}, conn) do
    conn =
      case resp.private do
        %{conn: sent} -> sent
        _first -> conn |> copy_headers(resp) |> send_chunked(resp.status)
      end

    case chunk(conn, data) do
      {:ok, conn} -> {:cont, {req, Req.Response.put_private(resp, :conn, conn)}}
      {:error, _closed} -> {:halt, {req, Req.Response.put_private(resp, :conn, conn)}}
    end
  end

  defp copy_headers(conn, resp) do
    Enum.reduce(resp.headers, conn, fn
      {name, values}, conn
      when name in ["content-type", "docker-experimental", "api-version", "ostype"] ->
        put_resp_header(conn, name, Enum.join(values, ", "))

      _header, conn ->
        conn
    end)
  end

  defp req do
    Req.new(
      [
        base_url: "http://docker",
        retry: false,
        redirect: false,
        compressed: false,
        receive_timeout: @receive_timeout
      ] ++ Application.get_env(:docker_guard, :req_options, [])
    )
  end

  defp segment(id), do: URI.encode(id, &URI.char_unreserved?/1)
end
