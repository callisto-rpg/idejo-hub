# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.ExportWorker do
  @moduledoc """
  FL-06: exports a forum as a standard Idejo backup.

  A one-off container (`idejo-forum-<slug>-export`: the forum's image, environment and
  volumes) runs `idejo-admin backup` (Idejo AD-05, AD-09), which works whether the forum
  is running or suspended. The Hub reads the file name from its output (only
  `/data/backups/idejo-YYYYMMDD-HHMMSS.tar`), copies that file into its exports volume,
  records its size and SHA-256, and removes the one-off container. The file is Idejo's own
  backup format, so `idejo-admin restore` takes it on a standalone install.
  """
  use Oban.Worker, queue: :operations, max_attempts: 1

  alias IdejoHub.Forums
  alias IdejoHub.Forums.Archives
  alias IdejoHub.Hosting.ForumContainer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor} = args}) do
    forum = Forums.get_forum!(id)
    kind = Map.get(args, "kind", "export")

    case export(forum, kind) do
      {:ok, export} ->
        Forums.finish_action(forum, actor, "forum.export", %{}, %{
          "kind" => kind,
          "file" => export.file_name,
          "size" => export.size,
          "sha256" => export.sha256
        })

      error ->
        Forums.fail_action(forum, actor, "forum.export", error)
    end
  end

  @doc false
  # Also used by FL-05's deletion, inside its own job.
  def export(forum, kind) do
    with {:ok, params} <- Forums.container_params(forum),
         {:ok, run} <-
           ForumContainer.run_one_off(params, "export", ["/app/bin/idejo-admin", "backup"]) do
      try do
        Archives.collect(forum, run.id, run, kind)
      after
        ForumContainer.remove_one_off(forum.subdomain, "export")
      end
    end
  end
end
