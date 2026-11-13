# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.TwoFactorResetController do
  @moduledoc """
  SC-08 (steward request 2026-11-13): an operator who lost their two-factor app gives their
  email and password (`new`, `create`) and gets a link by email
  (`Operators.request_two_factor_reset/3`). The link's page (`edit`) asks to confirm, so a
  mail scanner opening it changes nothing; the confirmation (`update`) removes the setup,
  set up again at the next sign-in. The answer
  never says whether the email or password was right; requests are limited per address and
  per email, as the password reset's.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.{Operators, RateLimit}

  @per_address 5
  @per_email 3
  @window 3600

  def new(conn, _params) do
    render(conn, :new,
      email_ready: IdejoHub.Mailer.configured?(),
      form: Phoenix.Component.to_form(%{"email" => ""}, as: :reset)
    )
  end

  def create(conn, %{"reset" => %{"email" => email, "password" => password}})
      when is_binary(email) and is_binary(password) do
    email = email |> String.trim() |> String.downcase()

    with :ok <- RateLimit.hit({:operator_2fa_reset, client_ip(conn)}, @per_address, @window),
         # Over the limit for one email: the same answer, no email, no password check.
         :ok <- per_email(email),
         {:error, :no_smtp} <- Operators.request_two_factor_reset(email, password, &link/1) do
      conn
      |> put_flash(:error, no_smtp())
      |> redirect(to: ~p"/sign-in/two-factor-reset")
    else
      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, "Too many requests from here. Try again in an hour.")
        |> put_status(:too_many_requests)
        |> new(%{})

      _sent_or_not ->
        conn
        |> put_flash(
          :info,
          "If that email and password are right, a link to remove your two-factor setup is " <>
            "on its way. It works for #{Operators.reset_minutes()} minutes."
        )
        |> redirect(to: ~p"/sign-in")
    end
  end

  def edit(conn, %{"token" => token}) do
    case Operators.get_operator_by_two_factor_token(token) do
      nil -> expired(conn)
      operator -> render(conn, :edit, token: token, email: operator.email)
    end
  end

  def update(conn, %{"token" => token}) do
    case Operators.reset_two_factor_by_token(token) do
      :ok ->
        conn
        |> put_flash(:info, "Two-factor removed. Sign in with your password to set it up again.")
        |> redirect(to: ~p"/sign-in")

      {:error, :expired} ->
        expired(conn)
    end
  end

  defp expired(conn) do
    conn
    |> put_flash(:error, "That link has expired or was already used. Ask for a new one.")
    |> redirect(to: ~p"/sign-in/two-factor-reset")
  end

  defp per_email(email) do
    case RateLimit.hit({:operator_2fa_reset_email, email}, @per_email, @window) do
      :ok -> :ok
      {:error, :rate_limited} -> :skip
    end
  end

  defp link(token), do: url(~p"/sign-in/two-factor-reset/#{token}")

  defp no_smtp,
    do:
      "This Hub has no email server set up, so it cannot send the link. " <>
        "Ask an owner to reset your two-factor from the Operators page."

  # Behind the bundle's Caddy the peer is Caddy: the client is the last X-Forwarded-For entry
  # Caddy added (as PasswordResetController).
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.last() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
