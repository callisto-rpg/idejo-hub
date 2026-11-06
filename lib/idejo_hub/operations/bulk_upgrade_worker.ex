# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.BulkUpgradeWorker do
  @moduledoc """
  OP-05: upgrades every forum to one version, one after another, stopping at the first
  failure.

  `Operations.upgrade_all/2` picks the running forums on an older version (by subdomain)
  and queues this worker with them as `remaining`. Each run takes the next forum and starts
  its OP-04 upgrade, carrying the run along (`bulk` in `UpgradeWorker`'s arguments); when
  that upgrade succeeds, `continue/3` queues this worker again for the rest. When one fails
  (rolled back or not), the run stops there: the forums after it are not touched, and the
  audit lists what was done, where it stopped and what was left.

  A forum that is no longer running, is already on that version or newer, or was pinned to its
  version meanwhile (OP-06), is skipped. One busy with another action is waited for (snoozed
  a minute).
  """
  use Oban.Worker, queue: :operations, max_attempts: 1

  alias IdejoHub.{Audit, Forums}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"remaining" => []} = run}) do
    {:ok, _} = Audit.record(run["actor"], "forums.upgrade_all", "ok", nil, summary(run))
    :ok
  end

  def perform(%Oban.Job{args: %{"remaining" => [id | rest]} = run}) do
    forum = Forums.get_forum!(id)

    cond do
      forum.status != "running" or forum.pinned or not older?(forum, run["version"]) ->
        next(
          %{run | "remaining" => rest}
          |> Map.update("skipped", [forum.subdomain], &(&1 ++ [forum.subdomain]))
        )

      forum.step != nil ->
        {:snooze, 60}

      true ->
        bulk =
          Map.take(%{run | "remaining" => rest}, [
            "run",
            "version",
            "actor",
            "remaining",
            "done",
            "skipped"
          ])

        case Forums.upgrade_forum(forum, run["version"], run["actor"], bulk: bulk) do
          {:ok, _forum} -> :ok
          {:error, :invalid_state} -> {:snooze, 60}
          {:error, reason} -> stop(run, forum, inspect(reason))
        end
    end
  end

  @doc false
  # Called by UpgradeWorker when a forum of the run has been upgraded, or has failed.
  def continue(bulk, forum, :ok) do
    next(Map.update(bulk, "done", [forum.subdomain], &(&1 ++ [forum.subdomain])))
  end

  def continue(bulk, forum, {:error, message}) do
    stop(bulk, forum, message)
  end

  defp next(run) do
    {:ok, _job} = Oban.insert(new(run))
    :ok
  end

  defp stop(run, forum, message) do
    details =
      run
      |> summary()
      |> Map.merge(%{
        "failed" => forum.subdomain,
        "error" => message,
        "not_attempted" => subdomains(run["remaining"])
      })

    {:ok, _} = Audit.record(run["actor"], "forums.upgrade_all", "failed", nil, details)
    {:error, "stopped at #{forum.subdomain}: #{message}"}
  end

  defp summary(run) do
    %{
      "run" => run["run"],
      "version" => run["version"],
      "done" => run["done"] || [],
      "skipped" => run["skipped"] || []
    }
  end

  defp subdomains(ids), do: Enum.map(ids, &Forums.get_forum!(&1).subdomain)

  defp older?(forum, version),
    do: Version.compare(Version.parse!(forum.idejo_version), Version.parse!(version)) == :lt
end
