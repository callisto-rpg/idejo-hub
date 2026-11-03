# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.BackupScheduler do
  @moduledoc """
  OP-01: run by Oban's cron (`IDEJO_HUB_BACKUP_CRON`, default daily at 02:00 UTC, an hour
  before Idejo's own 03:00 backup). Queues a backup for every running forum that is not busy
  with another action; a busy one is skipped until the next run and the skip is logged.
  """
  use Oban.Worker, queue: :operations, max_attempts: 1

  require Logger

  alias IdejoHub.Forums

  @impl Oban.Worker
  def perform(_job) do
    for forum <- Forums.list_forums(), forum.status == "running" do
      case Forums.backup_forum(forum, "schedule") do
        {:ok, _forum} ->
          :ok

        {:error, :invalid_state} ->
          Logger.warning("OP-01: #{forum.subdomain} is busy; no backup this time")
      end
    end

    :ok
  end
end
