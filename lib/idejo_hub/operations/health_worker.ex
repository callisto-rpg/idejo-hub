# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.HealthWorker do
  @moduledoc """
  OP-07: every minute (Oban cron, its own queue so a long backup never delays it), asks each
  running forum for its `/health` (idejo AD-15) and its container for its memory use, and
  keeps both on the forum: `health` (`ok` or `down`), when, `down_since` (the first check
  that found it down, for OP-08's alerts; cleared when it answers again), and memory in use
  and its limit. Forums are checked side by side, each within a few seconds.

  A forum busy with an action (`step`) is skipped: it is stopped or starting on purpose. A
  forum that is not running keeps no health: the list shows its status instead.
  """
  use Oban.Worker, queue: :health, max_attempts: 1, unique: [period: 50]

  require Logger

  alias IdejoHub.Forums
  alias IdejoHub.Hosting.{Docker, ForumContainer, Health}
  alias IdejoHub.Operations.Alerts

  @impl Oban.Worker
  def perform(_job) do
    now = DateTime.utc_now(:second)

    Forums.list_forums()
    |> Enum.filter(&(&1.status == "running" and &1.step == nil))
    |> Task.async_stream(&check(&1, now),
      max_concurrency: 8,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Stream.run()

    for forum <- Forums.list_forums(), forum.status != "running", forum.health != nil do
      Forums.update_state(forum, %{health: nil, health_at: nil, down_since: nil})
    end

    # OP-08: forums down for 5 minutes, and the disk, by email.
    Alerts.check_forums(now)
    Alerts.check_disk()
    :ok
  end

  @doc "Checks one forum and keeps what it found."
  @spec check(Forums.Forum.t(), DateTime.t()) :: {:ok, Forums.Forum.t()} | {:error, term()}
  def check(forum, now \\ DateTime.utc_now(:second)) do
    up? = Health.check(forum.subdomain) == :ok

    memory =
      case Docker.stats(ForumContainer.name(forum.subdomain)) do
        {:ok, stats} ->
          stats

        other ->
          Logger.info(
            "OP-07: no memory reading for #{forum.subdomain} (#{inspect(other, limit: 3)})"
          )

          %{memory_bytes: nil, memory_limit_bytes: nil}
      end

    Forums.update_state(
      forum,
      Map.merge(memory, %{
        health: if(up?, do: "ok", else: "down"),
        health_at: now,
        down_since: if(up?, do: nil, else: forum.down_since || now)
      })
    )
  end
end
