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
  alias IdejoHub.Identity.Join

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

  @doc "Running forums the operator has not hidden, by name."
  @spec directory() :: [Forum.t()]
  def directory do
    Repo.all(
      from f in Forum,
        where: f.status == "running" and f.listed,
        order_by: [asc: fragment("lower(?)", f.display_name), asc: f.subdomain]
    )
  end

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
