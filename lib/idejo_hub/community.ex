# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Community do
  @moduledoc """
  The forums directory and the community menu (steward decisions 2026-11-06).

  * `directory/0`: every running forum the operator has not hidden (`forums.listed`), by
    name, for the public page at `forums.<IDEJO_FORUM_DOMAIN>` (the subdomain `forums` is
    reserved, FL-03, so no forum can take it).
  * `joined/3`: answers a forum's `IDEJO_COMMUNITY_URL` request (Idejo's community menu): the
    other running forums a person joined (`identity_joins`, ID-05), asked by a forum that
    proves itself with its own OpenID Connect client id and secret (ID-01), and only about a
    person who joined that forum. Nothing else about the person leaves the Hub.
  """

  import Ecto.Query

  alias IdejoHub.{Forums, Repo}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Identity.{Join, Members, OutsideForums}

  @doc "The directory's host: `forums.<forum domain>`."
  @spec directory_host() :: String.t()
  def directory_host, do: "forums." <> Application.fetch_env!(:idejo_hub, Forums)[:domain]

  @doc "The directory's address, given to forums as `IDEJO_COMMUNITY_DIRECTORY_URL`."
  @spec directory_url() :: String.t()
  def directory_url, do: "https://" <> directory_host() <> "/"

  @doc """
  The address forums ask about a member's communities (`IDEJO_COMMUNITY_URL`): the Hub on
  the forum network, `/internal/*`, which Caddy never serves from outside.
  """
  @spec community_url() :: String.t()
  def community_url,
    do:
      Application.get_env(:idejo_hub, __MODULE__, [])[:url] ||
        "http://hub:4000/internal/community"

  @per_page 10

  @doc "Running forums the operator has not hidden, by name."
  @spec directory() :: [Forum.t()]
  def directory, do: Repo.all(listed() |> order_by_name())

  @doc """
  One page of the directory (steward requests 2026-11-06): the hosted forums listed and the
  outside forums an operator approved (`OutsideForums`), by name, those whose name or host
  holds `search` (any case), #{@per_page} a page. `%{forums: [%{name:, host:, members:}], page:,
  pages:, total:, listed:}`, where `listed` counts every listed forum (search and pages show
  past #{@per_page}).
  """
  @spec directory_page(String.t() | nil, pos_integer()) :: map()
  def directory_page(search, page) do
    search = (search || "") |> String.trim() |> String.slice(0, 100)

    all = from(e in subquery(entries()))

    matching =
      if search == "",
        do: all,
        else:
          (
            like = "%" <> String.replace(search, ~r/[\\%_]/, "\\\\\\0") <> "%"
            from e in all, where: ilike(e.name, ^like) or ilike(e.host, ^like)
          )

    total = Repo.aggregate(matching, :count)
    pages = max(div(total + @per_page - 1, @per_page), 1)
    page = page |> max(1) |> min(pages)

    %{
      forums:
        Repo.all(
          matching
          |> order_by([e], asc: fragment("lower(?)", e.name), asc: e.host)
          |> limit(@per_page)
          |> offset(^((page - 1) * @per_page))
        ),
      page: page,
      pages: pages,
      total: total,
      listed: Repo.aggregate(all, :count),
      search: search
    }
  end

  @doc """
  The hosts of the forums `subject` joined (steward request 2026-11-06): running hosted
  forums they are still a member of, and outside forums they signed in to.
  """
  @spec joined_hosts(String.t()) :: MapSet.t(String.t())
  def joined_hosts(subject) do
    suffix = "." <> Application.fetch_env!(:idejo_hub, Forums)[:domain]

    hosted =
      Repo.all(
        from j in Join,
          join: f in assoc(j, :forum),
          where: j.subject == ^subject and j.state == "joined" and f.status == "running",
          select: fragment("? || ?", f.subdomain, ^suffix)
      )

    outside =
      Repo.all(
        from j in "outside_joins",
          join: o in IdejoHub.Identity.OutsideForum,
          on: o.id == j.outside_forum_id,
          where: j.subject == ^subject and o.status == "registered",
          select: o.host
      )

    MapSet.new(hosted ++ outside)
  end

  @doc "The listed forums among `hosts`, by name, all of them: `[%{name:, host:}]`."
  @spec directory_of(MapSet.t(String.t())) :: [%{name: String.t(), host: String.t()}]
  def directory_of(hosts) do
    Repo.all(
      from e in subquery(entries()),
        where: e.host in ^MapSet.to_list(hosts),
        order_by: [asc: fragment("lower(?)", e.name), asc: e.host]
    )
  end

  @doc "How many forums a directory page holds."
  def per_page, do: @per_page

  defp listed, do: from(f in Forum, where: f.status == "running" and f.listed)

  # Hosted and outside forums alike: `%{name:, host:}`.
  defp entries do
    suffix = "." <> Application.fetch_env!(:idejo_hub, Forums)[:domain]

    # Members (steward request 2026-11-07): the hosted forum's count from its last `stats`;
    # unknown for outside forums.
    outside =
      from o in OutsideForums.listed_query(),
        select: %{name: o.display_name, host: o.host, members: type(^nil, :integer)}

    from f in listed(),
      select: %{
        name: f.display_name,
        host: fragment("? || ?", f.subdomain, ^suffix),
        members: f.members
      },
      union_all: ^outside
  end

  defp order_by_name(query),
    do: order_by(query, [f], asc: fragment("lower(?)", f.display_name), asc: f.subdomain)

  @doc """
  The other running forums `subject` joined, for the forum whose client is `client_id` with
  `secret`: `{:ok, [%{name:, url:}]}`, or `{:error, :unauthorized}` when the credentials are
  not a forum's, or the person never joined it.
  """
  @spec joined(String.t(), String.t(), String.t()) ::
          {:ok, [%{name: String.t(), url: String.t()}]} | {:error, :unauthorized}
  def joined(client_id, secret, subject) do
    with %Forum{} = forum <- forum_of_client(client_id),
         {:ok, stored} <- Forums.secret(forum, :oidc_client_secret),
         true <- Plug.Crypto.secure_compare(stored, secret),
         true <- joined?(subject, forum.id) do
      forums =
        Repo.all(
          from j in Join,
            join: f in assoc(j, :forum),
            where:
              j.subject == ^subject and j.state == "joined" and f.id != ^forum.id and
                f.status == "running",
            order_by: [asc: fragment("lower(?)", f.display_name)],
            select: f
        )

      {:ok,
       Enum.map(forums, &%{name: &1.display_name, url: "https://" <> Forums.host(&1) <> "/"})}
    else
      _ -> {:error, :unauthorized}
    end
  end

  @doc """
  Whether the forum whose client is `client_id` with `secret` (hosted or outside) may see
  and fill `subject`'s Idejo ID profile: that person signed in there. Sign-ins are read
  again once when not found (a first sign-in moments ago).
  """
  @spec member_of_client?(term(), term(), term()) :: boolean()
  def member_of_client?(client_id, secret, subject)
      when is_binary(client_id) and is_binary(secret) and is_binary(subject) and subject != "" do
    case client(client_id, secret) do
      nil ->
        false

      forum ->
        signed_in?(forum, subject) or (Members.sync() == :ok and signed_in?(forum, subject))
    end
  end

  def member_of_client?(_client_id, _secret, _subject), do: false

  defp client(client_id, secret) do
    with %Forum{} = forum <- forum_of_client(client_id),
         {:ok, stored} <- Forums.secret(forum, :oidc_client_secret),
         true <- Plug.Crypto.secure_compare(stored, secret) do
      forum
    else
      _ -> OutsideForums.authenticate(client_id, secret)
    end
  end

  defp signed_in?(%Forum{id: id}, subject), do: joined?(subject, id)

  defp signed_in?(%IdejoHub.Identity.OutsideForum{id: id}, subject) do
    Repo.exists?(
      from j in "outside_joins", where: j.subject == ^subject and j.outside_forum_id == ^id
    )
  end

  defp forum_of_client(client_id) when is_binary(client_id) and client_id != "",
    do: Repo.one(from f in Forum, where: f.oidc_client_id == ^client_id and f.status != "deleted")

  defp forum_of_client(_), do: nil

  defp joined?(subject, forum_id) do
    Repo.exists?(
      from j in Join,
        where: j.subject == ^subject and j.forum_id == ^forum_id and j.state == "joined"
    )
  end
end
