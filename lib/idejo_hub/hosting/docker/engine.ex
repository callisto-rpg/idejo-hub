# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.Docker.Engine do
  @moduledoc """
  `IdejoHub.Hosting.Docker` over the Docker Engine API, through docker-guard (`:docker_url`).

  The API version is pinned to v1.44 (Docker 25 and later). Error messages from Docker
  are passed on, but never a request body: those hold forum secrets.
  """

  @behaviour IdejoHub.Hosting.Docker

  alias IdejoHub.Hosting.Docker

  @api "/v1.44"
  @forum_label "org.idejo.hub.forum"

  @impl true
  def ping do
    with {:ok, _body} <- request(:get, "/_ping"), do: :ok
  end

  @impl true
  def pull_image(image) do
    # Pulls stream progress as JSON lines; a failure can still arrive with status 200.
    with {:ok, body} <-
           request(:post, "/images/create",
             params: [fromImage: image],
             # Progress arrives as JSON lines, under a JSON content type.
             decode_body: false,
             receive_timeout: :timer.minutes(15)
           ) do
      body |> to_string() |> String.split("\n", trim: true) |> Enum.find_value(:ok, &pull_error/1)
    end
  end

  defp pull_error(line) do
    case Jason.decode(line) do
      {:ok, %{"error" => message}} -> {:error, {:status, 500, message}}
      _other -> nil
    end
  end

  @impl true
  def create_volume(name, labels) do
    with {:ok, _body} <-
           request(:post, "/volumes/create", json: %{"Name" => name, "Labels" => labels}),
         do: :ok
  end

  @impl true
  def remove_volume(name) do
    with {:ok, _body} <- request(:delete, "/volumes/#{segment(name)}"), do: :ok
  end

  @impl true
  def create_container(name, spec) do
    with {:ok, %{"Id" => id}} <-
           request(:post, "/containers/create", params: [name: name], json: spec),
         do: {:ok, id}
  end

  @impl true
  def start_container(id), do: action(id, "start")

  @impl true
  def stop_container(id, timeout) do
    with {:ok, _body} <-
           request(:post, "/containers/#{segment(id)}/stop",
             params: [t: timeout],
             receive_timeout: :timer.seconds(timeout + 30)
           ),
         do: :ok
  end

  @impl true
  def remove_container(id) do
    with {:ok, _body} <- request(:delete, "/containers/#{segment(id)}", params: [force: true]),
         do: :ok
  end

  @impl true
  def inspect_container(id), do: request(:get, "/containers/#{segment(id)}/json")

  @impl true
  def list_forum_containers do
    filters = Jason.encode!(%{"label" => [@forum_label]})
    request(:get, "/containers/json", params: [all: true, filters: filters])
  end

  @impl true
  def exec(id, cmd) do
    body = %{"Cmd" => cmd, "AttachStdout" => true, "AttachStderr" => true}

    with {:ok, %{"Id" => exec_id}} <-
           request(:post, "/containers/#{segment(id)}/exec", json: body),
         {:ok, stream} <-
           request(:post, "/exec/#{exec_id}/start",
             json: %{"Detach" => false, "Tty" => false},
             receive_timeout: :timer.hours(1)
           ),
         {:ok, %{"ExitCode" => code}} <- request(:get, "/exec/#{exec_id}/json") do
      {:ok, %{exit_code: code, output: demultiplex(to_string(stream))}}
    end
  end

  # Without a TTY, Docker frames stdout and stderr: 1 byte stream, 3 zero bytes, 4 bytes
  # length (big-endian), then the payload. Both streams are kept, in order.
  @doc false
  def demultiplex(<<stream, 0, 0, 0, size::32, rest::binary>>) when stream in 0..2 do
    case rest do
      <<payload::binary-size(^size), rest::binary>> -> payload <> demultiplex(rest)
      _truncated -> rest
    end
  end

  def demultiplex(other), do: other

  defp action(id, action) do
    with {:ok, _body} <- request(:post, "/containers/#{segment(id)}/#{action}"), do: :ok
  end

  defp request(method, path, opts \\ []) do
    req =
      Req.new(
        [
          base_url: Docker.config(:docker_url) <> @api,
          retry: false,
          redirect: false,
          compressed: false
        ] ++ Application.get_env(:idejo_hub, :docker_req_options, [])
      )

    case Req.request(req, [method: method, url: path] ++ opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      # 304: already started or stopped, which is what was asked.
      {:ok, %Req.Response{status: 304}} ->
        {:ok, ""}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 403, body: body}} ->
        {:error, {:denied, message(body)}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:status, status, message(body)}}

      {:error, exception} ->
        {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  defp message(%{"message" => message}) when is_binary(message), do: message

  defp message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"message" => message}} when is_binary(message) -> message
      _other -> String.slice(body, 0, 500)
    end
  end

  defp message(_body), do: ""

  defp segment(id), do: URI.encode(id, &URI.char_unreserved?/1)
end
