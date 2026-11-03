# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.Docker.Fake do
  @moduledoc """
  An in-memory Docker for unit tests (HN-04). Each test calls `start/0`, which gives the test
  process (and the processes it starts, through `$callers`) its own state, so async tests do
  not share containers.

  `fail/2` makes the next call to one function fail, to test clean-up; `exec_result/2` sets
  what an exec of a command prefix returns.
  """

  @behaviour IdejoHub.Hosting.Docker

  @key {__MODULE__, :server}

  @doc "Starts an empty Docker for the calling test."
  def start do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          containers: %{},
          volumes: %{},
          images: MapSet.new(),
          failures: %{},
          exec: [],
          execs: [],
          calls: []
        }
      end)

    Process.put(@key, pid)
    pid
  end

  @doc "The next call to `fun` returns `{:error, error}`."
  def fail(fun, error \\ {:status, 500, "fake failure"}),
    do: update(&put_in(&1, [:failures, fun], error))

  @doc "An exec whose command starts with `prefix` returns `result`."
  def exec_result(prefix, result),
    do: update(&Map.update!(&1, :exec, fn rules -> [{prefix, result} | rules] end))

  @doc """
  Containers, volumes and images as they are now, the calls made (names, oldest first) and
  the exec commands run (`execs`, `{container, cmd}`, oldest first).
  """
  def state,
    do: Agent.get(server(), &Map.update!(&1, :calls, fn calls -> Enum.reverse(calls) end))

  @impl true
  def ping, do: call(:ping, fn s -> {:ok, s} end)

  @impl true
  def pull_image(image),
    do: call(:pull_image, fn s -> {:ok, Map.update!(s, :images, &MapSet.put(&1, image))} end)

  @impl true
  def create_volume(name, labels) do
    call(:create_volume, fn s -> {:ok, put_in(s, [:volumes, name], labels)} end)
  end

  @impl true
  def remove_volume(name) do
    call(:remove_volume, fn s ->
      if Map.has_key?(s.volumes, name),
        do: {:ok, Map.update!(s, :volumes, &Map.delete(&1, name))},
        else: {{:error, :not_found}, s}
    end)
  end

  @impl true
  def create_container(name, spec) do
    call(:create_container, fn s ->
      cond do
        Map.has_key?(s.containers, name) ->
          {{:error, {:status, 409, "name in use"}}, s}

        not MapSet.member?(s.images, spec["Image"]) ->
          {{:error, :not_found}, s}

        true ->
          container = %{"Id" => name, "Name" => "/" <> name, "Spec" => spec, "Running" => false}
          {{:ok, name}, put_in(s, [:containers, name], container)}
      end
    end)
  end

  @impl true
  def start_container(id), do: set_running(:start_container, id, true)

  @impl true
  def stop_container(id, _timeout), do: set_running(:stop_container, id, false)

  @impl true
  def remove_container(id) do
    call(:remove_container, fn s ->
      if Map.has_key?(s.containers, id),
        do: {:ok, Map.update!(s, :containers, &Map.delete(&1, id))},
        else: {{:error, :not_found}, s}
    end)
  end

  @impl true
  def inspect_container(id) do
    call(:inspect_container, fn s ->
      case s.containers[id] do
        nil ->
          {{:error, :not_found}, s}

        c ->
          {{:ok,
            %{
              "Id" => id,
              "Name" => c["Name"],
              "Config" => c["Spec"],
              "State" => %{"Running" => c["Running"]}
            }}, s}
      end
    end)
  end

  @impl true
  def list_forum_containers do
    call(:list_forum_containers, fn s ->
      {{:ok,
        Enum.map(s.containers, fn {id, c} ->
          %{"Id" => id, "Names" => [c["Name"]], "Labels" => c["Spec"]["Labels"]}
        end)}, s}
    end)
  end

  @impl true
  def exec(id, cmd) do
    call(:exec, fn s ->
      if Map.has_key?(s.containers, id),
        do: {exec_rule(s.exec, cmd), Map.update!(s, :execs, &(&1 ++ [{id, cmd}]))},
        else: {{:error, :not_found}, s}
    end)
  end

  defp exec_rule(rules, cmd) do
    Enum.find_value(rules, {:ok, %{exit_code: 0, output: ""}}, fn {prefix, result} ->
      if List.starts_with?(cmd, prefix), do: result
    end)
  end

  defp set_running(fun, id, running?) do
    call(fun, fn s ->
      if Map.has_key?(s.containers, id),
        do: {:ok, put_in(s, [:containers, id, "Running"], running?)},
        else: {{:error, :not_found}, s}
    end)
  end

  # Records the call, then either returns an injected failure or applies `fun`.
  defp call(name, fun) do
    Agent.get_and_update(server(), fn s ->
      s = Map.update!(s, :calls, &[name | &1])

      case Map.pop(s.failures, name) do
        {nil, _failures} ->
          fun.(s)

        {error, failures} ->
          {{:error, error}, %{s | failures: failures}}
      end
    end)
  end

  defp update(fun), do: Agent.update(server(), fun)

  defp server do
    Enum.find_value([self() | Process.get(:"$callers", [])], &server_of/1) ||
      raise "IdejoHub.Hosting.Docker.Fake.start/0 was not called by this test"
  end

  defp server_of(pid) when pid == self(), do: Process.get(@key)

  defp server_of(pid) do
    with {:dictionary, dict} <- Process.info(pid, :dictionary),
         {@key, server} <- List.keyfind(dict, @key, 0) do
      server
    else
      _missing -> nil
    end
  end
end
