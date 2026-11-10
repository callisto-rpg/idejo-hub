# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.MyController do
  @moduledoc """
  The members' page's plain routes (steward request 2026-11-10), on `my.<forum domain>`:

    * `/sign-in` → the sign-in host's `/account/my?state=` → `/signed-in?token=` (a
      `Phoenix.Token`, two minutes, naming the subject and this session's `state`), then
      back where the member was going (`my_return`, a path on this host);
    * `/sign-out`;
    * `/chat/new?with=<subject>`: Idejo's "Private Message" (its chat service): the chat
      with that Idejo ID, made on first use (`IdejoHub.Chats.start/2`).
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.{Chats, Identity}
  alias IdejoHubWeb.MyAuth

  @state_key "my_state"
  @return_key "my_return"

  def sign_in(conn, _params) do
    state = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    conn
    |> put_session(@state_key, state)
    |> redirect(
      external: Identity.issuer() <> "/account/my?" <> URI.encode_query(%{"state" => state})
    )
  end

  def signed_in(conn, %{"token" => token}) when is_binary(token) do
    state = get_session(conn, @state_key)
    return = get_session(conn, @return_key)
    conn = conn |> delete_session(@state_key) |> delete_session(@return_key)

    case Phoenix.Token.verify(
           IdejoHubWeb.Endpoint,
           IdejoHubWeb.AccountController.my_salt(),
           token,
           max_age: 120
         ) do
      {:ok, %{"sub" => subject, "state" => ^state}} when is_binary(state) ->
        conn
        |> configure_session(renew: true)
        |> put_session(MyAuth.member_key(), %{
          "sub" => subject,
          "at" => System.system_time(:second)
        })
        |> redirect(to: safe_return(return))

      _ ->
        conn
        |> put_flash(:error, "Signing in did not work. Please try again.")
        |> redirect(to: ~p"/sign-in-again")
    end
  end

  def signed_in(conn, _params), do: redirect(conn, to: ~p"/")

  def sign_in_again(conn, _params), do: render(conn, :sign_in_again, page_title: "Sign in")

  def sign_out(conn, _params),
    do: conn |> configure_session(drop: true) |> redirect(to: ~p"/sign-in-again")

  def new_chat(conn, params) do
    case MyAuth.subject(get_session(conn)) do
      nil ->
        conn
        |> put_session(
          @return_key,
          "/chat/new?" <> URI.encode_query(%{"with" => params["with"] || ""})
        )
        |> redirect(to: ~p"/sign-in")

      subject ->
        case Chats.start(subject, params["with"]) do
          {:ok, chat} ->
            redirect(conn, to: ~p"/chat/#{chat.id}")

          {:error, :rate_limited} ->
            conn
            |> put_flash(:error, "You are starting chats too quickly. Try again later.")
            |> redirect(to: ~p"/chat")

          {:error, :forbidden} ->
            conn
            |> put_flash(:error, "You cannot start a chat with this person.")
            |> redirect(to: ~p"/chat")
        end
    end
  end

  # Only a path on this host.
  defp safe_return("/" <> rest = path) when is_binary(rest) do
    if String.starts_with?(rest, ["/", "\\"]), do: "/", else: path
  end

  defp safe_return(_return), do: "/"
end
