# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations do
  @moduledoc """
  Operations across forums (OP). OP-05: `upgrade_all/2`.
  """

  import Ecto.Query

  alias IdejoHub.{Audit, Forums, Repo}
  alias IdejoHub.Operations.BulkUpgradeWorker

  @doc """
  OP-05: upgrades every running forum on an older version to `version`, one after another,
  stopping at the first failure (`BulkUpgradeWorker`). Forums that are not running are left
  out and listed as skipped. One run at a time.
  """
  @spec upgrade_all(String.t(), String.t()) ::
          {:ok, %{run: String.t(), forums: [String.t()], skipped: [String.t()]}}
          | {:error, :invalid_version | :nothing_to_upgrade | :already_running}
  def upgrade_all(version, actor) do
    with {:ok, target} <- parse(version),
         :ok <- not_running() do
      {upgrade, skipped} =
        Forums.list_forums()
        |> Enum.filter(&(Version.compare(Version.parse!(&1.idejo_version), target) == :lt))
        |> Enum.split_with(&(&1.status == "running"))

      start(version, actor, upgrade, skipped)
    end
  end

  defp start(_version, _actor, [], _skipped), do: {:error, :nothing_to_upgrade}

  defp start(version, actor, upgrade, skipped) do
    run = Ecto.UUID.generate()
    subdomains = Enum.map(upgrade, & &1.subdomain)
    skipped = Enum.map(skipped, & &1.subdomain)

    {:ok, _} =
      Audit.record(actor, "forums.upgrade_all", "requested", nil, %{
        "run" => run,
        "version" => version,
        "forums" => subdomains,
        "skipped" => skipped
      })

    {:ok, _job} =
      Oban.insert(
        BulkUpgradeWorker.new(%{
          "run" => run,
          "version" => version,
          "actor" => actor,
          "remaining" => Enum.map(upgrade, & &1.id),
          "done" => [],
          "skipped" => skipped
        })
      )

    {:ok, %{run: run, forums: subdomains, skipped: skipped}}
  end

  defp parse(version) do
    case Version.parse(version) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, :invalid_version}
    end
  end

  # A run is under way while its worker, or an upgrade it started, is not finished.
  defp not_running do
    busy =
      Repo.exists?(
        from j in Oban.Job,
          where: j.state in ["available", "scheduled", "executing", "retryable"],
          where:
            j.worker == "IdejoHub.Operations.BulkUpgradeWorker" or
              (j.worker == "IdejoHub.Operations.UpgradeWorker" and
                 fragment("? \\? 'bulk'", j.args))
      )

    if busy, do: {:error, :already_running}, else: :ok
  end
end
