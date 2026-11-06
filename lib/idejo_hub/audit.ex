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

  @page 50

  @doc """
  SC-07: the operator's audit log, newest first, `@page` entries a page. Filters (strings,
  blank is none): `"forum"` (subdomain), `"action"` (starts with), `"outcome"`, `"actor"`
  (contains, any case); `"before"` an entry id, for the page after. Returns the entries and
  whether older ones remain.
  """
  @spec list(map()) :: {[Entry.t()], boolean()}
  def list(filters \\ %{}) do
    import Ecto.Query

    query =
      Enum.reduce(filters, from(e in Entry), fn
        {_key, value}, q when value in [nil, ""] -> q
        {"forum", subdomain}, q -> where(q, [e], e.subdomain == ^subdomain)
        {"action", action}, q -> where(q, [e], like(e.action, ^(escape_like(action) <> "%")))
        {"outcome", outcome}, q -> where(q, [e], e.outcome == ^outcome)
        {"actor", actor}, q -> where(q, [e], ilike(e.actor, ^("%" <> escape_like(actor) <> "%")))
        {"before", id}, q -> before(q, Integer.parse(id))
        _other, q -> q
      end)

    entries = Repo.all(from e in query, order_by: [desc: e.id], limit: @page + 1)
    {Enum.take(entries, @page), length(entries) > @page}
  end

  defp before(query, {id, ""}) do
    import Ecto.Query
    where(query, [e], e.id < ^id)
  end

  defp before(query, _not_an_id), do: query

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, "\\\\\\0")

  @doc "SC-07: a forum's newest `limit` entries, newest first (its owner's view)."
  @spec recent_for_forum(integer(), pos_integer()) :: [Entry.t()]
  def recent_for_forum(forum_id, limit \\ 200) do
    import Ecto.Query

    Repo.all(
      from e in Entry, where: e.forum_id == ^forum_id, order_by: [desc: e.id], limit: ^limit
    )
  end

  @doc "A forum's entries, oldest first."
  @spec for_forum(integer()) :: [Entry.t()]
  def for_forum(forum_id) do
    import Ecto.Query
    Repo.all(from e in Entry, where: e.forum_id == ^forum_id, order_by: [e.inserted_at, e.id])
  end
end
