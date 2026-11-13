# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.Members do
  @moduledoc """
  ID-05, ID-06: what an idejo ID has joined, and leaving or deleting.

  Which forums: every sign-in to a forum's client is an event at the provider
  (`Identity.sign_ins_since/1`), read into `identity_joins` by `sync/0` (at each visit to
  the member's page and every five minutes); never a forum's database. A sign-in after
  leaving makes the forum "joined" again.

  Leaving a forum (steward decision 2026-11-03) is the person's choice: `:leave` keeps their
  account and messages there for a return with the same identity (idejo's `idejo-admin
  leave --oidc-subject`), `:delete` deletes their account there as the forum's own rules do
  (`delete-account`: anonymised, messages shown as "Deleted user"). Deleting the identity
  (ID-06) deletes the account on every forum joined, then the person at the provider; a
  forum that refuses (its last owner) stops it, with the reason shown.
  """
  import Ecto.Query

  require Logger

  alias IdejoHub.{Audit, Forums, Identity, Repo}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Hosting.{Docker, ForumContainer}
  alias IdejoHub.Identity.{Deletion, Join, MemberWorker, State}

  @admin "/app/bin/idejo-admin"

  ## Joined forums

  @doc "Reads new sign-ins from the provider into the joined forums."
  @spec sync() :: :ok | {:error, term()}
  def sync do
    state = state()

    with true <- Identity.enabled?() || :ok,
         {:ok, sign_ins} <- Identity.sign_ins_since(state.events_since) do
      forums = forums_by_client()
      outside = outside_by_client()

      for s <- sign_ins, forum_id = forums[s.client_id], do: record(s.user_id, forum_id, s.at)

      # Outside forums (steward decisions 2026-11-06): who signed in there, so the forum
      # may read and fill that person's idejo ID profile.
      for s <- sign_ins, outside_id = outside[s.client_id] do
        Repo.insert_all(
          "outside_joins",
          [
            %{
              subject: s.user_id,
              outside_forum_id: outside_id,
              first_at: DateTime.truncate(s.at, :second)
            }
          ],
          on_conflict: :nothing,
          conflict_target: [:subject, :outside_forum_id]
        )
      end

      case List.last(sign_ins) do
        nil -> :ok
        last -> state |> Ecto.Changeset.change(events_since: last.at) |> Repo.update!()
      end

      :ok
    end
  end

  defp outside_by_client do
    from(f in IdejoHub.Identity.OutsideForum,
      where: not is_nil(f.client_id),
      select: {f.client_id, f.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp forums_by_client do
    from(f in Forum,
      where: not is_nil(f.oidc_client_id) and f.status != "deleted",
      select: {f.oidc_client_id, f.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  # A sign-in after the person left (or deleted their account there) is a new join.
  defp record(subject, forum_id, at) do
    at = DateTime.truncate(at, :second)

    case Repo.get_by(Join, subject: subject, forum_id: forum_id) do
      nil ->
        %Join{}
        |> Join.changeset(%{subject: subject, forum_id: forum_id, first_at: at, last_at: at})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:subject, :forum_id])

      %Join{} = join ->
        rejoined? = join.state in ["left", "deleted"] and after?(at, join.changed_at)
        last = if DateTime.compare(at, join.last_at) == :gt, do: at, else: join.last_at
        attrs = %{last_at: last}
        attrs = if rejoined?, do: Map.merge(attrs, %{state: "joined", error: nil}), else: attrs
        join |> Join.changeset(attrs) |> Repo.update()
    end
  end

  defp after?(_at, nil), do: true
  defp after?(at, changed_at), do: DateTime.compare(at, changed_at) == :gt

  @doc "The forums this identity has joined (deleted forums left out), newest first."
  @spec forums_of(String.t()) :: [Join.t()]
  def forums_of(subject) do
    from(j in Join,
      join: f in assoc(j, :forum),
      where: j.subject == ^subject and f.status != "deleted",
      order_by: [desc: j.first_at],
      preload: [forum: f]
    )
    |> Repo.all()
  end

  ## Leaving one forum

  @doc """
  Leaves a forum (`:leave`, account kept) or deletes the account there (`:delete`): queued,
  done by `MemberWorker`. Only for a forum this identity has joined, and not while a
  deletion of the whole identity runs.
  """
  @spec leave(String.t(), integer(), :leave | :delete) ::
          {:ok, Join.t()} | {:error, :not_joined | :busy | :deleting}
  def leave(subject, forum_id, choice) when choice in [:leave, :delete] do
    if deleting?(subject),
      do: {:error, :deleting},
      else: start_leave(Repo.get_by(Join, subject: subject, forum_id: forum_id), choice)
  end

  defp start_leave(%Join{state: state} = join, choice) when state in ["joined", "left"] do
    pending = if choice == :leave, do: "leaving", else: "deleting"
    {:ok, join} = join |> Join.changeset(%{state: pending, error: nil}) |> Repo.update()

    {:ok, _} =
      Oban.insert(MemberWorker.new(%{"join_id" => join.id, "choice" => to_string(choice)}))

    {:ok, _} = audit(join.subject, "identity.forum_#{choice}", "requested", join)
    {:ok, join}
  end

  defp start_leave(%Join{}, _choice), do: {:error, :busy}
  defp start_leave(nil, _choice), do: {:error, :not_joined}

  @doc """
  Runs a leave or a delete on the forum. `{:ok, join}` when done (the forum had no account
  for this identity counts as done), `{:error, :last_owner}` when the forum refuses,
  `{:snooze, seconds}` while the forum is busy, `{:error, reason}` otherwise.
  """
  def run(%Join{} = join, choice) do
    join = Repo.preload(join, :forum, force: true)

    case admin(join.forum, command(choice, join.subject)) do
      {:ok, %{exit_code: code}} when code in [0, 2] ->
        done = if choice == :leave, do: "left", else: "deleted"

        {:ok, join} =
          join |> Join.changeset(%{state: done, error: nil, changed_at: now()}) |> Repo.update()

        {:ok, _} = audit(join.subject, "identity.forum_#{choice}", "ok", join)
        {:ok, join}

      {:ok, %{output: output}} ->
        reason = if output =~ "last owner", do: :last_owner, else: :refused
        failed(join, choice, reason)

      {:error, :busy} ->
        {:snooze, 30}

      {:error, reason} ->
        Logger.warning("ID-05: #{choice} on #{join.forum.subdomain} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Gives up on a leave or delete: the join goes back to joined with the reason."
  def failed(%Join{} = join, choice, reason) do
    {:ok, join} =
      join |> Join.changeset(%{state: "joined", error: Atom.to_string(reason)}) |> Repo.update()

    {:ok, _} =
      audit(join.subject, "identity.forum_#{choice}", "failed", join, %{
        "error" => to_string(reason)
      })

    {:error, reason}
  end

  # idejo's AC-09 commands, by the provider's subject (exit 0 done, 2 no such account).
  defp command(:leave, subject), do: [@admin, "leave", "--oidc-subject", subject]
  defp command(:delete, subject), do: [@admin, "delete-account", "--oidc-subject", subject]

  # `idejo-admin` in the forum: inside the running container, or a one-off from its image
  # while it is suspended. Not during another action on it (`step`), nor while it is
  # being made, failed or deleted.
  defp admin(%Forum{step: step}, _args) when not is_nil(step), do: {:error, :busy}

  defp admin(%Forum{status: "running"} = forum, cmd),
    do: Docker.exec(ForumContainer.name(forum.subdomain), cmd)

  defp admin(%Forum{status: "suspended"} = forum, cmd) do
    with {:ok, params} <- Forums.container_params(forum),
         {:ok, result} <- ForumContainer.run_one_off(params, "identity", cmd) do
      ForumContainer.remove_one_off(forum.subdomain, "identity")
      {:ok, result}
    end
  end

  defp admin(%Forum{status: "creating"}, _args), do: {:error, :busy}
  defp admin(%Forum{}, _args), do: {:error, :unavailable}

  ## Deleting the identity

  @doc "Whether a deletion of this identity is running (asked, not stopped, not done)."
  def deleting?(subject) do
    match?(%Deletion{error: nil, finished_at: nil}, Repo.get(Deletion, subject))
  end

  @doc "The deletion of this identity, if one was asked for."
  def deletion(subject), do: Repo.get(Deletion, subject)

  @doc """
  ID-06: deletes the identity. Every forum account first (each as its forum's rules say),
  then the person at the provider. Queued; the member's page shows how far it is. Asked
  again after a forum refused (`error` set), it starts over.
  """
  @spec delete_identity(String.t(), String.t() | nil, map()) ::
          {:ok, Deletion.t()} | {:error, :deleting}
  def delete_identity(subject, by \\ nil, details \\ %{}) do
    result =
      case Repo.get(Deletion, subject) do
        nil ->
          Repo.insert(%Deletion{subject: subject, requested_at: now()})

        %Deletion{error: error} = d when is_binary(error) ->
          Repo.update(Ecto.Changeset.change(d, error: nil, requested_at: now()))

        %Deletion{} ->
          {:error, :deleting}
      end

    with {:ok, deletion} <- result do
      _ = sync()
      {:ok, _} = Oban.insert(MemberWorker.new(%{"subject" => subject, "choice" => "identity"}))

      # HA-06: an operator handling a request made to them is the actor.
      {:ok, _} =
        Audit.record(
          by || actor(subject),
          "identity.delete",
          "requested",
          nil,
          Map.put(details, "subject", subject)
        )

      {:ok, deletion}
    end
  end

  @doc """
  Runs an identity deletion: each forum not yet done, then the provider. `:ok` when the
  identity is gone, `{:snooze, s}` while a forum is busy, `{:error, reason}` to retry,
  `{:cancel, reason}` when a forum refuses (the identity is kept, the reason shown).
  """
  def run_deletion(subject) do
    joins = forums_of(subject) |> Enum.reject(&(&1.state == "deleted"))

    case delete_each(joins) do
      :ok -> finish_deletion(subject)
      {:refused, join, reason} -> stop_deletion(subject, join, reason)
      other -> other
    end
  end

  @doc "Stops a deletion for good (a forum refused, or every retry failed): the identity stays."
  def stop_deletion(subject, join, reason) do
    where = if join, do: Forums.host(Repo.preload(join, :forum).forum) <> ": ", else: ""
    message = where <> to_string(reason)

    if deletion = Repo.get(Deletion, subject),
      do: Repo.update!(Ecto.Changeset.change(deletion, error: message))

    {:ok, _} =
      Audit.record(actor(subject), "identity.delete", "failed", nil, %{
        "subject" => subject,
        "error" => message
      })

    {:cancel, reason}
  end

  defp delete_each([]), do: :ok

  defp delete_each([join | rest]) do
    {:ok, join} = join |> Join.changeset(%{state: "deleting"}) |> Repo.update()

    case run(join, :delete) do
      {:ok, _} -> delete_each(rest)
      {:error, reason} when reason in [:last_owner, :refused] -> {:refused, join, reason}
      other -> other
    end
  end

  defp finish_deletion(subject) do
    with :ok <- Identity.delete_person(subject) do
      deletion = Repo.get!(Deletion, subject)
      Repo.update!(Ecto.Changeset.change(deletion, finished_at: now(), error: nil))

      {:ok, _} =
        Audit.record(actor(subject), "identity.delete", "ok", nil, %{"subject" => subject})

      :ok
    end
  end

  ## The members' pages' own client

  @secret_context "identity:account:client_secret"

  @doc "Registers the Hub's members' pages at the provider once (`SetupWorker`)."
  @spec ensure_account_client() :: :ok | {:error, term()}
  def ensure_account_client do
    state = state()

    if state.account_client_id do
      :ok
    else
      with {:ok, client} <- Identity.create_account_client(Identity.config(:domain)) do
        state
        |> Ecto.Changeset.change(
          account_app_id: client.app_id,
          account_client_id: client.client_id,
          account_client_secret_enc:
            IdejoHub.Secrets.encrypt(client.client_secret, @secret_context)
        )
        |> Repo.update!()

        :ok
      end
    end
  end

  @doc "The members' pages' client id and secret, once registered."
  @spec account_client() :: {:ok, {String.t(), String.t()}} | {:error, :not_ready}
  def account_client do
    state = state()

    with id when is_binary(id) <- state.account_client_id,
         {:ok, secret} <-
           IdejoHub.Secrets.decrypt(state.account_client_secret_enc, @secret_context) do
      {:ok, {id, secret}}
    else
      _ -> {:error, :not_ready}
    end
  end

  ## Bookkeeping

  @doc false
  def state do
    with nil <- Repo.get(State, 1) do
      Repo.insert!(%State{id: 1}, on_conflict: :nothing, conflict_target: :id)
      Repo.get!(State, 1)
    end
  end

  defp audit(subject, action, outcome, %Join{} = join, details \\ %{}) do
    join = Repo.preload(join, :forum)

    Audit.record(
      actor(subject),
      action,
      outcome,
      join.forum,
      Map.put(details, "subject", subject)
    )
  end

  # The person, by the provider's subject (never their email).
  defp actor(subject), do: "member:" <> subject

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
