# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.SuspendWorker do
  @moduledoc """
  FL-04, suspend: marks the forum's host for Caddy's maintenance page, then stops its
  container. Its database, volumes (uploads and backups) and container are kept. If the stop
  fails, the mark is removed again and the forum stays `running`.
  """
  use Oban.Worker, queue: :lifecycle, max_attempts: 1

  alias IdejoHub.Forums
  alias IdejoHub.Hosting.{Docker, ForumContainer, Maintenance}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor}}) do
    forum = Forums.get_forum!(id)
    host = Forums.host(forum)

    with :ok <- Maintenance.mark(host),
         :ok <- Docker.stop_container(ForumContainer.name(forum.subdomain)) do
      Forums.finish_action(forum, actor, "forum.suspend", %{status: "suspended"})
    else
      error ->
        Maintenance.unmark(host)
        Forums.fail_action(forum, actor, "forum.suspend", error)
    end
  end
end
