# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.HubBackupWorker do
  @moduledoc """
  OP-10: one backup of the Hub's database and the identity provider's (`HubBackup.run/1`).
  Queued by `BackupScheduler` with the forums' backups, or from the server page
  (`Operations.backup_hub/1`); one at a time. Audited `hub.backup` (no forum). OP-02: each
  dump's encrypted off-server copy is queued (`OffsiteWorker`) when storage is configured.
  """
  use Oban.Worker,
    queue: :operations,
    max_attempts: 1,
    unique: [fields: [:worker], period: :infinity, states: [:available, :scheduled, :executing]]

  alias IdejoHub.Audit
  alias IdejoHub.Forums.Errors
  alias IdejoHub.Operations.{Alerts, HubBackup, OffsiteWorker}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"actor" => actor}}) do
    case HubBackup.run(keep()) do
      {:ok, backups, pruned} ->
        Enum.each(backups, &OffsiteWorker.queue/1)

        Audit.record(actor, "hub.backup", "ok", nil, %{
          "files" => Enum.map(backups, & &1.file_name),
          "sizes" => Enum.map(backups, & &1.size),
          "pruned" => pruned
        })

        :ok

      {:error, kind, reason, done} ->
        Enum.each(done, &OffsiteWorker.queue/1)

        Audit.record(actor, "hub.backup", "failed", nil, %{
          "failed" => kind,
          "error" => Errors.describe(reason),
          "files" => Enum.map(done, & &1.file_name)
        })

        # OP-08.
        Alerts.backup_failed("the Hub", nil, Errors.describe(reason))
        {:error, reason}
    end
  end

  defp keep, do: Application.fetch_env!(:idejo_hub, IdejoHub.Operations)[:backups_kept]
end
