# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.ReleaseCheckWorker do
  @moduledoc "OP-09: the daily check for new Idejo releases (`Operations.Releases`)."
  use Oban.Worker, queue: :operations, max_attempts: 3, unique: [period: 3600]

  require Logger

  alias IdejoHub.Operations.Releases

  @impl Oban.Worker
  def perform(_job) do
    case Releases.check() do
      {:ok, _version} ->
        :ok

      {:error, :off} ->
        :ok

      {:error, reason} ->
        Logger.warning("OP-09: could not read Idejo's releases: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
