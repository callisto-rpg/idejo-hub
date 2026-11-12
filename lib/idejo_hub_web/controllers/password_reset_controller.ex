# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.PasswordResetController do
  @moduledoc """
  SC-08: an operator who forgot their password asks for a link by email (`new`, `create`)
  and chooses a new one with it (`edit`, `update`). The answer never says whether an email
  is an operator's; requests are limited per address and per email. Two factor is still
  asked at the next sign-in.
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

  def create(conn, %{"reset" => %{"email" => email}}) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    with :ok <- RateLimit.hit({:operator_reset, client_ip(conn)}, @per_address, @window),
         # Over the limit for one email: the same answer, no email.
         :ok <- per_email(email),
         {:error, :no_smtp} <- Operators.request_password_reset(email, &link/1) do
      conn
      |> put_flash(:error, no_smtp())
      |> redirect(to: ~p"/sign-in/reset")
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
          "If that email belongs to an operator, a link to choose a new password is on its " <>
            "way. It works for #{Operators.reset_minutes()} minutes."
        )
        |> redirect(to: ~p"/sign-in")
    end
  end

  def edit(conn, %{"token" => token}) do
    case Operators.get_operator_by_reset_token(token) do
      nil -> expired(conn)
      _operator -> render_edit(conn, token)
    end
  end

  def update(conn, %{"token" => token, "reset" => %{"password" => password} = params})
      when is_binary(password) do
    case Operators.reset_password(token, password, to_string(params["password_confirmation"])) do
      {:ok, _operator} ->
        conn
        |> put_flash(:info, "Password changed. Sign in with it and your two-factor code.")
        |> redirect(to: ~p"/sign-in")

      {:error, :expired} ->
        expired(conn)

      {:error, reason} ->
        conn
        |> put_flash(:error, message(reason))
        |> put_status(:unprocessable_entity)
        |> render_edit(token)
    end
  end

  defp render_edit(conn, token) do
    render(conn, :edit,
      token: token,
      min: Operators.min_password(),
      form: Phoenix.Component.to_form(%{}, as: :reset)
    )
  end

  defp expired(conn) do
    conn
    |> put_flash(:error, "That link has expired or was already used. Ask for a new one.")
    |> redirect(to: ~p"/sign-in/reset")
  end

  defp per_email(email) do
    case RateLimit.hit({:operator_reset_email, email}, @per_email, @window) do
      :ok -> :ok
      {:error, :rate_limited} -> :skip
    end
  end

  defp link(token), do: url(~p"/sign-in/reset/#{token}")

  defp no_smtp,
    do:
      "This Hub has no email server set up, so it cannot send the link. " <>
        "Ask an owner for a new one-time password."

  defp message(:too_short), do: "Use at least #{Operators.min_password()} characters."
  defp message(:too_long), do: "Use at most 200 characters."
  defp message(:mismatch), do: "The two passwords are not the same."

  # Behind the bundle's Caddy the peer is Caddy: the client is the last X-Forwarded-For entry
  # Caddy added (as SignupController).
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.last() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
