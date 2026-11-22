# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.SyncWorker do
  @moduledoc """
  ID-05: reads new sign-ins into the joined forums every five minutes; then the passwords
  changed, for their notices (`PasswordNotices`, steward request 2026-11-22).
  """
  use Oban.Worker, queue: :operations, max_attempts: 1

  alias IdejoHub.Identity.{Members, PasswordNotices}

  @impl Oban.Worker
  def perform(_job) do
    with :ok <- Members.sync(), do: PasswordNotices.run()
  end
end
