# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.PurgeWorker do
  @moduledoc """
  FL-05, second step, at `purge_at`: removes the forum's container, volumes, database and
  role, its maintenance mark and its stored secrets, and marks it `deleted`. Its exports
  stay (the final one above all). Only for a forum still `deleting` (a cancelled deletion
  makes this job do nothing); run early, it waits.
  """
  use Oban.Worker,
    queue: :lifecycle,
    max_attempts: 3,
    unique: [keys: [:forum_id], states: :incomplete]

  alias IdejoHub.Forums
  alias IdejoHub.Hosting.{ForumContainer, Maintenance, Postgres}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor}}) do
    forum = Forums.get_forum!(id)

    cond do
      forum.status != "deleting" ->
        :ok

      DateTime.compare(forum.purge_at, DateTime.utc_now()) == :gt ->
        {:snooze, max(DateTime.diff(forum.purge_at, DateTime.utc_now()), 1)}

      true ->
        purge(forum, actor)
    end
  end

  defp purge(forum, actor) do
    with :ok <- ForumContainer.remove(forum.subdomain, volumes: true),
         :ok <- Postgres.drop(forum.subdomain),
         :ok <- Maintenance.unmark(Forums.host(forum)) do
      Forums.finish_action(
        forum,
        actor,
        "forum.purge",
        %{status: "deleted", purge_at: nil, db_password_enc: nil, owner_link_enc: nil}
      )
    else
      error -> Forums.fail_action(forum, actor, "forum.purge", error)
    end
  end
end
