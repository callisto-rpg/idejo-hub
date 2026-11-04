# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.MemberWorker do
  @moduledoc """
  ID-05, ID-06: a member's choice, done in the forum: `choice` `leave` or `delete` for one
  join (`join_id`), or `identity` (`subject`) for every forum and then the provider.
  Waits while a forum is busy with another action; retried with back-off when a forum or the
  provider cannot be reached; a forum that refuses (its last owner) ends it.
  """
  use Oban.Worker, queue: :operations, max_attempts: 10

  alias IdejoHub.Identity.{Join, Members}
  alias IdejoHub.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"choice" => "identity", "subject" => subject}} = job) do
    case Members.run_deletion(subject) do
      {:error, reason} = error ->
        if job.attempt >= job.max_attempts,
          do: Members.stop_deletion(subject, nil, reason),
          else: error

      other ->
        other
    end
  end

  def perform(%Oban.Job{args: %{"join_id" => id, "choice" => choice}} = job) do
    choice = if choice == "leave", do: :leave, else: :delete

    case Repo.get(Join, id) do
      nil -> :ok
      join -> join |> Members.run(choice) |> outcome(join, choice, job)
    end
  end

  defp outcome({:ok, _done}, _join, _choice, _job), do: :ok

  defp outcome({:error, reason}, _join, _choice, _job) when reason in [:last_owner, :refused],
    do: {:cancel, reason}

  # The last attempt gives up: the forum shows as joined again, with the reason.
  defp outcome({:error, reason}, join, choice, %{attempt: n, max_attempts: n}) do
    Members.failed(join, choice, reason)
    {:cancel, reason}
  end

  defp outcome(other, _join, _choice, _job), do: other
end
