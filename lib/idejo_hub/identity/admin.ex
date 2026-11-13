# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.Admin do
  @moduledoc """
  HA-06: identity administration, for the operator. Search idejo IDs at the provider; lock
  one for abuse (the provider refuses its sign-ins to every forum and to the members' page;
  sessions already open on a forum are that forum's own, and its moderators ban there) and
  unlock it; and handle deletion requests: the members' own (ID-06) under way or stopped,
  retried, and requests made to the operator, which run the same deletion (each forum's
  account as its rules say, then the ID).

  Every action is audited with the operator and the provider's id (`subject`), never the
  person's email: `identity.lock` and `identity.unlock` (with the reason), `identity.delete`
  (`requested`, with the reason, by the operator).
  """

  import Ecto.Query

  alias IdejoHub.{Audit, Identity, Repo}
  alias IdejoHub.Audit.Entry
  alias IdejoHub.Identity.{Deletion, Members}

  @doc "idejo IDs whose email, name or username contains `text`, any case (at most 50)."
  @spec search(String.t()) :: {:ok, [Identity.listed()]} | {:error, term()}
  def search(text), do: Identity.search_people(String.trim(text))

  @doc "One idejo ID, with the forums it joined and its deletion, if any."
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get(subject) do
    case Identity.person(subject) do
      {:ok, person} ->
        {:ok,
         Map.merge(person, %{
           id: subject,
           joins: Members.forums_of(subject),
           deletion: Members.deletion(subject)
         })}

      {:error, :not_found} ->
        # Gone from the provider: what the Hub still knows (a finished deletion).
        case Members.deletion(subject) do
          nil ->
            {:error, :not_found}

          deletion ->
            {:ok,
             %{id: subject, gone?: true, joins: Members.forums_of(subject), deletion: deletion}}
        end

      error ->
        error
    end
  end

  @doc "Locks an idejo ID for abuse; the reason is required and kept in the audit log."
  @spec lock(String.t(), String.t(), String.t()) :: :ok | {:error, :reason | term()}
  def lock(subject, reason, operator) do
    with {:ok, reason} <- reason(reason),
         :ok <- Identity.lock_person(subject) do
      {:ok, _} =
        Audit.record(operator, "identity.lock", "ok", nil, %{
          "subject" => subject,
          "reason" => reason
        })

      :ok
    end
  end

  @doc "Unlocks an idejo ID."
  @spec unlock(String.t(), String.t()) :: :ok | {:error, term()}
  def unlock(subject, operator) do
    with :ok <- Identity.unlock_person(subject) do
      {:ok, _} = Audit.record(operator, "identity.unlock", "ok", nil, %{"subject" => subject})
      :ok
    end
  end

  @doc """
  A deletion asked of the operator (by email, a letter): the ID's email typed again confirms
  it is the right one, and the reason (who asked, how) is kept. Runs as ID-06 does.
  """
  @spec delete(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Deletion.t()} | {:error, :email | :reason | :deleting | term()}
  def delete(subject, typed_email, reason, operator) do
    with {:ok, reason} <- reason(reason),
         {:ok, person} <- Identity.person(subject),
         :ok <- same_email(person, typed_email) do
      Members.delete_identity(subject, operator, %{"reason" => reason})
    end
  end

  @doc "Starts again a deletion that stopped (a forum refused, or every retry failed)."
  @spec retry(String.t(), String.t()) :: {:ok, Deletion.t()} | {:error, :not_stopped | term()}
  def retry(subject, operator) do
    case Members.deletion(subject) do
      %Deletion{error: error} when is_binary(error) ->
        Members.delete_identity(subject, operator, %{"retry" => true})

      _other ->
        {:error, :not_stopped}
    end
  end

  @doc "The deletion requests: under way or stopped first, then the latest finished; newest first."
  @spec deletions() :: [Deletion.t()]
  def deletions do
    Repo.all(
      from d in Deletion,
        order_by: [asc: not is_nil(d.finished_at), desc: d.requested_at],
        limit: 100
    )
  end

  @doc "What the Hub's audit log holds about this ID, newest first."
  @spec log(String.t()) :: [Entry.t()]
  def log(subject) do
    Repo.all(
      from e in Entry,
        where: fragment("?->>'subject' = ?", e.details, ^subject),
        order_by: [desc: e.id],
        limit: 100
    )
  end

  defp reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason}
      reason -> {:ok, String.slice(reason, 0, 500)}
    end
  end

  defp reason(_none), do: {:error, :reason}

  defp same_email(%{email: email}, typed) when is_binary(email) and is_binary(typed) do
    if String.downcase(String.trim(typed)) == String.downcase(email),
      do: :ok,
      else: {:error, :email}
  end

  defp same_email(_person, _typed), do: {:error, :email}
end
