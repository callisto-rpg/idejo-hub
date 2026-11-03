# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.Server do
  @moduledoc """
  HA-04: the server at a glance. CPU (load averages and cores), memory and disk come from
  Linux itself (`/proc`, `df`): the Hub's container sees the host's figures. PostgreSQL
  sizes come from `hub_database_sizes()` when the bundle's init script made it (names and
  sizes only; the Hub has no access to forum databases, HN-05), else the Hub's own database
  only. Running containers are the forum containers, through docker-guard.

  Every reading is independent: one that fails shows as unavailable, never an error page.
  """

  alias IdejoHub.Hosting.Docker
  alias IdejoHub.Repo

  @doc "A snapshot of the server."
  @spec snapshot() :: map()
  def snapshot do
    %{
      cpu: cpu(),
      memory: memory(),
      disk: disk(Application.fetch_env!(:idejo_hub, IdejoHub.Forums.Export)[:dir]),
      databases: databases(),
      containers: containers()
    }
  end

  @doc false
  def cpu(loadavg \\ read("/proc/loadavg")) do
    with {:ok, text} <- loadavg,
         [one, five, fifteen | _] <- String.split(text),
         {l1, _} <- Float.parse(one),
         {l5, _} <- Float.parse(five),
         {l15, _} <- Float.parse(fifteen) do
      %{load: [l1, l5, l15], cores: :erlang.system_info(:logical_processors_available)}
    else
      _ -> :unavailable
    end
  end

  @doc false
  def memory(meminfo \\ read("/proc/meminfo")) do
    with {:ok, text} <- meminfo,
         fields = parse_meminfo(text),
         total when is_integer(total) <- fields["MemTotal"],
         available when is_integer(available) <- fields["MemAvailable"] do
      %{total: total * 1024, available: available * 1024}
    else
      _ -> :unavailable
    end
  end

  defp parse_meminfo(text) do
    for line <- String.split(text, "\n"),
        [key, value] <- [String.split(line, ":", parts: 2)],
        [kb | _] <- [String.split(value)],
        {n, ""} <- [Integer.parse(kb)],
        into: %{},
        do: {key, n}
  end

  @doc false
  def disk(path) do
    with {output, 0} <- System.cmd("df", ["-kP", path], stderr_to_stdout: true),
         [_header, line | _] <- String.split(output, "\n", trim: true),
         [_fs, total, used, available | _] <- String.split(line),
         {total, ""} <- Integer.parse(total),
         {used, ""} <- Integer.parse(used),
         {available, ""} <- Integer.parse(available) do
      %{total: total * 1024, used: used * 1024, available: available * 1024}
    else
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  end

  # Names and sizes only. The bundle's function (03-database-sizes.sh) gives every database;
  # without it, only the databases this role may connect to (never an error, so nothing
  # breaks a surrounding transaction). `sql` is one of two literals, never user input.
  # sobelow_skip ["SQL.Query"]
  defp databases do
    sql =
      case Repo.query("SELECT to_regprocedure('hub_database_sizes()') IS NOT NULL", [],
             log: false
           ) do
        {:ok, %{rows: [[true]]}} ->
          "SELECT name, size FROM hub_database_sizes() ORDER BY size DESC"

        _ ->
          "SELECT datname, pg_database_size(datname) FROM pg_database " <>
            "WHERE NOT datistemplate AND has_database_privilege(datname, 'CONNECT') ORDER BY 2 DESC"
      end

    case Repo.query(sql, [], log: false) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [name, size] -> %{name: name, size: size} end)
      {:error, _} -> :unavailable
    end
  end

  defp containers do
    case Docker.list_forum_containers() do
      {:ok, list} ->
        list
        |> Enum.map(fn c ->
          %{
            name: c |> Map.get("Names", ["?"]) |> hd() |> String.trim_leading("/"),
            state: c["State"] || "unknown",
            status: c["Status"] || ""
          }
        end)
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        :unavailable
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read(path), do: File.read(path)
end
