# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.BackupWorker do
  @moduledoc """
  OP-01: one scheduled backup of one running forum. `idejo-admin backup` runs inside its
  container (Idejo AD-09; it also keeps the forum's own last 7 in its volume), the Hub copies
  the file into its store as kind `backup` (`Forums.Archives`) and keeps that forum's newest
  14 (`:keep`), deleting older ones. Audited as `forum.backup`.

  Queued by `Operations.BackupScheduler` through `Forums.backup_forum/2`, which takes the
  forum's action slot (`step: "backing_up"`), so a backup never overlaps another action.
  """
  use Oban.Worker, queue: :operations, max_attempts: 1

  alias IdejoHub.Forums
  alias IdejoHub.Forums.Archives
  alias IdejoHub.Hosting.{Docker, ForumContainer}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor}}) do
    forum = Forums.get_forum!(id)
    container = ForumContainer.name(forum.subdomain)

    with {:ok, run} <- Docker.exec(container, ["/app/bin/idejo-admin", "backup"]),
         {:ok, backup} <- Archives.collect(forum, container, run, "backup") do
      pruned = Archives.prune(forum, "backup", keep())

      Forums.finish_action(forum, actor, "forum.backup", %{}, %{
        "file" => backup.file_name,
        "size" => backup.size,
        "sha256" => backup.sha256,
        "pruned" => pruned
      })
    else
      error -> Forums.fail_action(forum, actor, "forum.backup", error)
    end
  end

  defp keep, do: Application.fetch_env!(:idejo_hub, IdejoHub.Operations)[:backups_kept]
end
