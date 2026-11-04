# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OffsiteWorker do
  @moduledoc """
  OP-02: uploads one backup's encrypted copy (`Offsite.copy/2`), records where it went
  (`offsite_key`, `offsite_at`), then keeps the newest `IDEJO_HUB_BACKUPS_KEPT` copies under
  its key prefix (per forum; per Hub database). Queued after each scheduled forum backup
  (`BackupWorker`, `"source" => "forum"`) and each Hub dump (`HubBackupWorker`, `"hub"`)
  while storage is configured. Three attempts; the last failure is audited
  (`forum.backup.offsite` / `hub.backup.offsite`, `failed`). A backup pruned locally before
  its turn is skipped.
  """
  use Oban.Worker, queue: :operations, max_attempts: 3

  alias IdejoHub.{Audit, Repo}
  alias IdejoHub.Forums.{Errors, Export}
  alias IdejoHub.Operations.{HubBackup, Offsite}
  alias IdejoHub.Operations.HubBackup.Backup

  @doc "Queues the copy of a forum backup or a Hub dump, if off-server storage is on."
  @spec queue(Export.t() | Backup.t()) :: :ok
  def queue(backup) do
    if Offsite.configured?() do
      source = if match?(%Backup{}, backup), do: "hub", else: "forum"
      Oban.insert!(new(%{"source" => source, "id" => backup.id}))
    end

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source" => source, "id" => id}} = job) do
    case load(source, id) do
      nil ->
        :ok

      backup ->
        target = target(source, backup)
        target |> copy() |> finish(backup, target, job)
    end
  end

  defp finish({:ok, details}, backup, target, _job) do
    backup
    |> Ecto.Changeset.change(offsite_key: target.key, offsite_at: now())
    |> Repo.update!()

    Audit.record("schedule", target.action, "ok", target.forum, details)
    :ok
  end

  defp finish({:error, reason}, backup, target, job) do
    if job.attempt >= job.max_attempts do
      Audit.record("schedule", target.action, "failed", target.forum, %{
        "file" => backup.file_name,
        "error" => Errors.describe(reason)
      })
    end

    {:error, reason}
  end

  defp copy(target) do
    with {:ok, size} <- Offsite.copy(target.path, target.key),
         {:ok, pruned} <- Offsite.prune(target.prune, keep()) do
      {:ok, %{"key" => target.key, "size" => size, "pruned" => pruned}}
    end
  end

  defp load("forum", id), do: Repo.get(Export, id)
  defp load("hub", id), do: Repo.get(Backup, id)

  defp target("forum", export) do
    %{
      path: Export.path(export),
      key: Offsite.forum_key(export.subdomain, export.file_name),
      prune: Offsite.forum_key(export.subdomain, "idejo-") |> String.trim_trailing(".age"),
      action: "forum.backup.offsite",
      # The row carries what the audit entry needs, also after the forum is deleted.
      forum: %{id: export.forum_id, subdomain: export.subdomain}
    }
  end

  defp target("hub", backup) do
    %{
      path: HubBackup.path(backup),
      key: Offsite.hub_key(backup.file_name),
      prune: Offsite.hub_key("#{backup.kind}-") |> String.trim_trailing(".age"),
      action: "hub.backup.offsite",
      forum: nil
    }
  end

  defp now, do: DateTime.utc_now(:second)
  defp keep, do: Application.fetch_env!(:idejo_hub, IdejoHub.Operations)[:backups_kept]
end
