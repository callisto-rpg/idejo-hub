# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.CLI do
  @moduledoc """
  HA-08: the Hub's command line for scripting and recovery, mirroring the main actions:
  list, create, back up, upgrade, suspend and resume a forum. `bin/hub-admin` runs these
  inside the running Hub (`rpc`), so the jobs run as they do from the interface.

  Each action starts as the interface's does, as actor `command line`, then waits for its
  end, read from its audit entry (`ok` or `failed`; every action writes one), so a script
  can rely on the exit code: `{:ok, message}`, `{:error, message, code}` with code 2 for an
  unknown forum, 1 otherwise. `timeout` (milliseconds) bounds the wait.
  """

  import Ecto.Query

  alias IdejoHub.{Audit, Forums, Repo}

  @actor "command line"
  @poll 1_000

  @doc "One line per forum not deleted: subdomain, status, version, health."
  @spec list() :: [String.t()]
  def list do
    for f <- Forums.list_forums() do
      Enum.join([f.subdomain, f.status, f.idejo_version, f.health || "-"], "\t")
    end
  end

  @doc "Creates a forum and waits until it runs (or fails)."
  def create(subdomain, display_name, owner_email, opts \\ []) do
    from = last_entry_id()

    attrs = %{
      "subdomain" => subdomain,
      "display_name" => display_name,
      "owner_email" => owner_email
    }

    case Forums.create_forum(attrs, @actor) do
      {:ok, forum} -> wait(forum, "forum.create", from, opts, "#{subdomain} created")
      {:error, %Ecto.Changeset{} = changeset} -> {:error, "Not created: " <> errors(changeset), 1}
    end
  end

  @doc "Backs a running forum up and waits for the backup."
  def backup(subdomain, opts \\ []),
    do: act(subdomain, "forum.backup", &Forums.backup_forum(&1, @actor), opts, "backed up")

  @doc "Suspends a running forum and waits until it is stopped."
  def suspend(subdomain, opts \\ []),
    do: act(subdomain, "forum.suspend", &Forums.suspend_forum(&1, @actor), opts, "suspended")

  @doc "Resumes a suspended forum and waits until it answers."
  def resume(subdomain, opts \\ []),
    do: act(subdomain, "forum.resume", &Forums.resume_forum(&1, @actor), opts, "resumed")

  @doc "Upgrades a running forum to `version` (OP-04) and waits: upgraded, or rolled back."
  def upgrade(subdomain, version, opts \\ []) do
    act(
      subdomain,
      "forum.upgrade",
      &Forums.upgrade_forum(&1, version, @actor),
      opts,
      "upgraded to #{version}"
    )
  end

  defp act(subdomain, action, start, opts, done) do
    with %Forums.Forum{} = forum <- Forums.get_by_subdomain(subdomain),
         from = last_entry_id(),
         {:ok, forum} <- start.(forum) do
      wait(forum, action, from, opts, "#{subdomain} #{done}")
    else
      nil -> {:error, "No forum is called #{subdomain}.", 2}
      {:error, reason} -> {:error, "Not started: " <> reason(reason), 1}
    end
  end

  # The action's end: its first `ok` or `failed` audit entry after `from`.
  defp wait(forum, action, from, opts, done) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, 1_800_000)
    poll = Keyword.get(opts, :poll, @poll)
    await(forum.id, action, from, deadline, poll, done)
  end

  defp await(forum_id, action, from, deadline, poll, done) do
    entry =
      Repo.one(
        from e in Audit.Entry,
          where:
            e.id > ^from and e.forum_id == ^forum_id and e.action == ^action and
              e.outcome in ["ok", "failed"],
          order_by: e.id,
          limit: 1
      )

    cond do
      entry && entry.outcome == "ok" ->
        {:ok, done}

      entry ->
        {:error, "Failed: " <> describe(entry.details), 1}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, "Still under way after the time allowed; see the Hub's audit log.", 1}

      true ->
        Process.sleep(poll)
        await(forum_id, action, from, deadline, poll, done)
    end
  end

  defp last_entry_id, do: Repo.one(from e in Audit.Entry, select: max(e.id)) || 0

  defp describe(%{"rolled_back" => true} = details),
    do: "#{details["error"] || "unhealthy"} (rolled back to the previous version)"

  defp describe(%{"error" => error}), do: error
  defp describe(_details), do: "see the Hub's audit log"

  defp reason(:invalid_state), do: "the forum is busy, or not in a state for this"
  defp reason(:not_newer), do: "choose a version newer than the current one"
  defp reason(:invalid_version), do: "give an exact version, for example 0.2.2"

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end
end
