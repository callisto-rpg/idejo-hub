# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.SyncWorker do
  @moduledoc "ID-05: reads new sign-ins into the joined forums every five minutes."
  use Oban.Worker, queue: :operations, max_attempts: 1

  alias IdejoHub.Identity.Members

  @impl Oban.Worker
  def perform(_job), do: Members.sync()
end
