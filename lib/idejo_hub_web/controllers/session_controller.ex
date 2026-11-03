# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SessionController do
  @moduledoc """
  SC-08: operator sign-in. Password first (`new`, `create`), then the two-factor code
  (`two_factor`, `verify`); an operator without two factor sets it up on the same page,
  confirming it with a first code. Messages never say whether an email exists.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.Operators
  alias IdejoHubWeb.OperatorAuth

  def new(conn, _params) do
    if conn.assigns.current_operator,
      do: redirect(conn, to: ~p"/"),
      else: render(conn, :new, form: Phoenix.Component.to_form(%{"email" => ""}, as: :session))
  end

  def create(conn, %{"session" => %{"email" => email, "password" => password}}) do
    case Operators.check_password(email, password) do
      {:ok, operator} ->
        conn |> OperatorAuth.put_pending(operator) |> redirect(to: ~p"/sign-in/two-factor")

      {:error, reason} ->
        conn
        |> put_flash(:error, message(reason))
        |> put_status(:unauthorized)
        |> render(:new, form: Phoenix.Component.to_form(%{"email" => email}, as: :session))
    end
  end

  def two_factor(conn, _params) do
    case OperatorAuth.pending_operator(conn) do
      nil -> restart(conn)
      operator -> render_two_factor(conn, operator)
    end
  end

  def verify(conn, %{"two_factor" => %{"code" => code}}) do
    with operator when not is_nil(operator) <- OperatorAuth.pending_operator(conn),
         {:ok, operator} <- check(operator, code) do
      conn
      |> OperatorAuth.sign_in(operator)
      |> put_flash(:info, "Signed in.")
      |> redirect(to: ~p"/")
    else
      nil ->
        restart(conn)

      {:error, :locked} ->
        conn
        |> configure_session(drop: true)
        |> put_flash(:error, message(:locked))
        |> redirect(to: ~p"/sign-in")

      {:error, :invalid} ->
        operator = OperatorAuth.pending_operator(conn)

        conn
        |> put_flash(:error, "That code is not right. Use the current one from your app.")
        |> put_status(:unauthorized)
        |> render_two_factor(operator)
    end
  end

  def delete(conn, _params) do
    conn |> OperatorAuth.sign_out() |> redirect(to: ~p"/sign-in")
  end

  defp check(operator, code) do
    if Operators.two_factor?(operator),
      do: Operators.verify_two_factor(operator, code),
      else: Operators.confirm_two_factor(operator, code)
  end

  # Setting up shows a new secret each time the page is drawn, until a code confirms it.
  defp render_two_factor(conn, operator) do
    setup =
      if Operators.two_factor?(operator),
        do: nil,
        else: elem(Operators.begin_two_factor(operator), 1)

    render(conn, :two_factor,
      setup: setup,
      form: Phoenix.Component.to_form(%{"code" => ""}, as: :two_factor)
    )
  end

  defp restart(conn) do
    conn
    |> put_flash(:error, "Start again with your email and password.")
    |> redirect(to: ~p"/sign-in")
  end

  defp message(:invalid), do: "Wrong email or password."
  defp message(:locked), do: "Too many wrong tries: this account is locked for 15 minutes."
end
