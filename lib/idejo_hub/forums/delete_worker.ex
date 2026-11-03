# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.DeleteWorker do
  @moduledoc """
  FL-05, first step: the final export, then the forum goes quiet until it is purged.

  1. A final export (`kind: "final"`, FL-06). If it fails, nothing is deleted.
  2. Its host shows the maintenance page (FL-04's mark) and its container stops.
  3. It becomes `deleting` with `purge_at` (30 days on, or now when the operator confirmed
     immediate deletion), and `PurgeWorker` is scheduled for then.

  A forum that failed to be created has nothing to export or remove: it is simply `deleted`.
  """
  use Oban.Worker, queue: :lifecycle, max_attempts: 1

  alias IdejoHub.Forums
  alias IdejoHub.Forums.{ExportWorker, PurgeWorker}
  alias IdejoHub.Hosting.{Docker, ForumContainer, Maintenance}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor} = args}) do
    forum = Forums.get_forum!(id)

    if forum.status == "failed" do
      Forums.finish_action(forum, actor, "forum.delete", %{status: "deleted"}, %{
        "export" => "none"
      })
    else
      delete(forum, actor, args["immediate"] == true)
    end
  end

  defp delete(forum, actor, immediate?) do
    with {:ok, export} <- ExportWorker.export(forum, "final"),
         :ok <- Maintenance.mark(Forums.host(forum)),
         :ok <- stop(forum) do
      purge_at = if immediate?, do: now(), else: DateTime.add(now(), grace_days(), :day)

      {:ok, _job} =
        Oban.insert(
          PurgeWorker.new(%{"forum_id" => forum.id, "actor" => actor}, scheduled_at: purge_at)
        )

      Forums.finish_action(
        forum,
        actor,
        "forum.delete",
        %{status: "deleting", purge_at: purge_at},
        %{
          "export" => export.file_name,
          "sha256" => export.sha256,
          "purge_at" => DateTime.to_iso8601(purge_at),
          "immediate" => immediate?
        }
      )
    else
      error ->
        if forum.status == "running", do: Maintenance.unmark(Forums.host(forum))
        Forums.fail_action(forum, actor, "forum.delete", error)
    end
  end

  defp stop(forum) do
    case Docker.stop_container(ForumContainer.name(forum.subdomain)) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp grace_days, do: Application.fetch_env!(:idejo_hub, Forums)[:deletion_grace_days]
end
