# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.Docker do
  @moduledoc """
  The Hub's only way to Docker (HN-04). Every call goes to the configured adapter:
  `IdejoHub.Hosting.Docker.Engine` in dev and production (HTTP to docker-guard, never the
  socket), `IdejoHub.Hosting.Docker.Fake` in tests.

  docker-guard refuses anything that is not a forum container, volume or image (steward
  decision 2026-11-03), so a refusal comes back as `{:error, {:denied, message}}`.
  """

  @type id :: String.t()
  @type error ::
          :not_found
          | {:denied, String.t()}
          | {:status, pos_integer(), String.t()}
          | {:unreachable, term()}

  @callback ping() :: :ok | {:error, error()}
  @callback pull_image(image :: String.t()) :: :ok | {:error, error()}
  @callback create_volume(name :: String.t(), labels :: map()) :: :ok | {:error, error()}
  @callback remove_volume(name :: String.t()) :: :ok | {:error, error()}
  @callback create_container(name :: String.t(), spec :: map()) :: {:ok, id()} | {:error, error()}
  @callback start_container(id()) :: :ok | {:error, error()}
  @callback stop_container(id(), timeout_seconds :: non_neg_integer()) :: :ok | {:error, error()}
  @callback remove_container(id()) :: :ok | {:error, error()}
  @callback inspect_container(id()) :: {:ok, map()} | {:error, error()}
  @callback list_forum_containers() :: {:ok, [map()]} | {:error, error()}
  @callback exec(id(), cmd :: [String.t()]) ::
              {:ok, %{exit_code: integer(), output: binary()}} | {:error, error()}
  @callback wait_container(id()) :: {:ok, exit_code :: integer()} | {:error, error()}
  @callback logs(id()) :: {:ok, binary()} | {:error, error()}
  # OP-07: memory in use (without the page cache, as `docker stats` counts it) and the limit.
  @callback stats(id()) ::
              {:ok, %{memory_bytes: non_neg_integer(), memory_limit_bytes: non_neg_integer()}}
              | {:error, error()}
  @callback copy_from(id(), path :: String.t(), dest_dir :: String.t()) ::
              {:ok, String.t()} | {:error, error() | {:archive, term()}}
  @callback copy_to(id(), file :: String.t(), dest_dir :: String.t()) ::
              :ok | {:error, error() | {:archive, term()}}

  def ping, do: adapter().ping()
  def pull_image(image), do: adapter().pull_image(image)
  def create_volume(name, labels), do: adapter().create_volume(name, labels)
  def remove_volume(name), do: adapter().remove_volume(name)
  def create_container(name, spec), do: adapter().create_container(name, spec)
  def start_container(id), do: adapter().start_container(id)
  def stop_container(id, timeout \\ 30), do: adapter().stop_container(id, timeout)
  def remove_container(id), do: adapter().remove_container(id)
  def inspect_container(id), do: adapter().inspect_container(id)
  def list_forum_containers, do: adapter().list_forum_containers()
  def exec(id, cmd), do: adapter().exec(id, cmd)
  def wait_container(id), do: adapter().wait_container(id)
  def logs(id), do: adapter().logs(id)
  def stats(id), do: adapter().stats(id)

  @doc "Copies one file out of a container (running or not) into `dest_dir`; returns its path."
  def copy_from(id, path, dest_dir), do: adapter().copy_from(id, path, dest_dir)

  @doc "Puts one local file into a container's `dest_dir` (running or not), under its own name."
  def copy_to(id, file, dest_dir), do: adapter().copy_to(id, file, dest_dir)

  @doc false
  def config(key), do: Application.fetch_env!(:idejo_hub, IdejoHub.Hosting)[key]

  defp adapter, do: config(:docker_adapter)
end
