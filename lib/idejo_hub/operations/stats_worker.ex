# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.StatsWorker do
  @moduledoc """
  HA-01: every 15 minutes (Oban cron), asks each running forum for its figures with
  `idejo-admin stats` (Idejo AD-09: one line of JSON, counts and sizes only) inside its
  container, and keeps them on the forum: members, topics, messages, database and uploads
  sizes, and when. A forum busy with an action is skipped this time. A forum on an Idejo
  without the command (0.1.0) keeps no figures; the list shows "—".
  """
  use Oban.Worker, queue: :operations, max_attempts: 1

  require Logger

  alias IdejoHub.Forums
  alias IdejoHub.Hosting.{Docker, ForumContainer}

  @keys ~w(members topics messages database_bytes uploads_bytes)

  @impl Oban.Worker
  def perform(_job) do
    for forum <- Forums.list_forums(), forum.status == "running", forum.step == nil do
      refresh(forum)
    end

    :ok
  end

  @doc "Asks one forum for its figures and keeps them."
  @spec refresh(Forums.Forum.t()) :: :ok | {:error, term()}
  def refresh(forum) do
    with {:ok, %{exit_code: 0, output: output}} <-
           Docker.exec(ForumContainer.name(forum.subdomain), ["/app/bin/idejo-admin", "stats"]),
         {:ok, stats} <- parse(output),
         {:ok, _forum} <-
           Forums.update_state(forum, Map.put(stats, :stats_at, DateTime.utc_now(:second))) do
      :ok
    else
      other ->
        Logger.info("HA-01: no figures from #{forum.subdomain} (#{inspect(other, limit: 3)})")
        {:error, :no_stats}
    end
  end

  # The last line that is a JSON object with the five numbers (the output may carry the
  # release's own notices before it).
  defp parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value({:error, :not_stats}, fn line ->
      with {:ok, %{} = map} <- Jason.decode(line),
           true <- Enum.all?(@keys, &(is_integer(map[&1]) and map[&1] >= 0)) do
        {:ok, Map.new(@keys, &{String.to_existing_atom(&1), map[&1]})}
      else
        _ -> nil
      end
    end)
  end
end
