# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.OperatorAuth do
  @moduledoc """
  SC-08: who is signed in. `:fetch_operator` reads the session token
  (`Operators.get_operator_by_session/1`) into `conn.assigns.current_operator`;
  `:require_operator` sends anyone else to the sign-in page.

  Between the password and the code, the session holds only `pending_operator_id` and when
  the password was right (`pending_at`): five minutes to give the code. Signing in renews
  the session (no fixation).
  """
  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  alias IdejoHub.Operators

  @pending_seconds 300

  @impl true
  def init(action), do: action

  @impl true
  def call(conn, :fetch_operator) do
    operator = conn |> get_session(:operator_token) |> Operators.get_operator_by_session()
    assign(conn, :current_operator, operator)
  end

  def call(conn, :require_operator) do
    if conn.assigns[:current_operator] do
      conn
    else
      conn
      |> put_flash(:error, "Sign in first.")
      |> redirect(to: "/sign-in")
      |> halt()
    end
  end

  @doc "After the password: remembers who is half signed in."
  def put_pending(conn, operator) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:pending_operator_id, operator.id)
    |> put_session(:pending_at, System.os_time(:second))
  end

  @doc "The half-signed-in operator, if their five minutes are not over."
  def pending_operator(conn) do
    with id when is_integer(id) <- get_session(conn, :pending_operator_id),
         at when is_integer(at) <- get_session(conn, :pending_at),
         true <- System.os_time(:second) - at <= @pending_seconds do
      Operators.get_operator!(id)
    else
      _none -> nil
    end
  end

  @doc "After the code: a new session with the operator's token only."
  def sign_in(conn, operator) do
    token = Operators.create_session(operator)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:operator_token, token)
  end

  @doc "Ends the session, here and in the database."
  def sign_out(conn) do
    conn |> get_session(:operator_token) |> Operators.delete_session()
    conn |> configure_session(drop: true)
  end
end
