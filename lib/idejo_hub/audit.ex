# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Audit do
  @moduledoc """
  The Hub's audit log: who did what to which forum, when, and how it ended. Every lifecycle
  action writes entries from the start; SC-07 (milestone 4) shows them. Append-only (a
  database trigger refuses updates and deletes).

  `details` never holds a secret, an environment or command output (CLAUDE.md, Conventions).
  """

  alias IdejoHub.Audit.Entry
  alias IdejoHub.Repo

  @doc "Records an entry. `forum` may be nil for actions on no forum."
  @spec record(String.t(), String.t(), String.t(), map() | nil, map()) ::
          {:ok, Entry.t()} | {:error, Ecto.Changeset.t()}
  def record(actor, action, outcome, forum, details \\ %{}) do
    actor |> changeset(action, outcome, forum, details) |> Repo.insert()
  end

  @doc "The same entry as a changeset, for an `Ecto.Multi`."
  @spec changeset(String.t(), String.t(), String.t(), map() | nil, map()) :: Ecto.Changeset.t()
  def changeset(actor, action, outcome, forum, details \\ %{}) do
    Entry.changeset(%{
      actor: actor,
      action: action,
      outcome: outcome,
      forum_id: forum && forum.id,
      subdomain: forum && forum.subdomain,
      details: details
    })
  end

  @doc "A forum's entries, oldest first."
  @spec for_forum(integer()) :: [Entry.t()]
  def for_forum(forum_id) do
    import Ecto.Query
    Repo.all(from e in Entry, where: e.forum_id == ^forum_id, order_by: [e.inserted_at, e.id])
  end
end
