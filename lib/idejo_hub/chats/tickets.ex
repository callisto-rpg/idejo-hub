# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.Tickets do
  @moduledoc """
  Tickets (steward request 2026-11-10): before asking a forum about a member (their followed
  topics, their private conversations to copy), the Hub makes a random ticket naming that
  member, a scope (`topics`, `conversations`) and that forum's client (`"forum:<id>"`,
  `"outside:<id>"`), good for two minutes. The forum hands it back with its client id and
  secret (`IdejoHubWeb.ChatServiceController`); only that forum learns whom it names. Only
  the SHA-256 is stored.
  """
  import Ecto.Query

  alias IdejoHub.Chats.Ticket
  alias IdejoHub.Repo

  @seconds 120
  @scopes ~w(topics conversations)

  @doc "A new ticket for `subject`, `scope` and `client`."
  @spec issue(String.t(), String.t(), String.t()) :: String.t()
  def issue(subject, scope, client) when scope in @scopes do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    now = DateTime.utc_now(:second)

    Repo.delete_all(from t in Ticket, where: t.expires_at < ^now)

    Repo.insert!(%Ticket{
      token_hash: hash(token),
      subject: subject,
      scope: scope,
      client: client,
      expires_at: DateTime.add(now, @seconds)
    })

    token
  end

  @doc """
  What a ticket names, for the forum `client` it was made for:
  `{:ok, %{subject:, scope:}}`, else `:error` (unknown, expired, another forum's).
  """
  @spec redeem(term(), String.t() | nil) :: {:ok, map()} | :error
  def redeem(token, client) when is_binary(token) and is_binary(client) do
    now = DateTime.utc_now(:second)

    case Repo.get(Ticket, hash(token)) do
      %Ticket{client: ^client, expires_at: expires} = ticket ->
        if DateTime.compare(expires, now) == :gt,
          do: {:ok, %{subject: ticket.subject, scope: ticket.scope}},
          else: :error

      _ ->
        :error
    end
  end

  def redeem(_token, _client), do: :error

  defp hash(token), do: :crypto.hash(:sha256, token)
end
