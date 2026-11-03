# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SignupController do
  @moduledoc """
  ID-02: sign up for an Idejo ID on the Hub's own page, at `https://id.<hub domain>/account/sign-up`
  (steward decision 2026-11-04). Email and display name are required; a checkbox reveals first
  and last name, optional (Zitadel requires them: "Sennoma" and "Ulo" stand in). The Hub makes
  the person at the provider, which then emails a link to verify the address and choose a
  password or a passkey: the Hub never sees one. Five sign-ups per address an hour. Plain
  HTML, no JavaScript needed (the checkbox reveals the names with CSS).
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.{Identity, RateLimit, Settings}

  @fields ~w(email display_name given_name family_name)
  @limit 5
  @window 3600

  def new(conn, _params) do
    render(conn, :new, form: form(%{}), errors: %{}, open?: Settings.shared_smtp() != nil)
  end

  def create(conn, %{"signup" => params}) do
    params = Map.new(@fields, &{&1, (params[&1] || "") |> to_string() |> String.trim()})

    with true <- Settings.shared_smtp() != nil || {:error, :closed},
         {:ok, person} <- validate(params),
         :ok <- RateLimit.hit({:signup, client_ip(conn)}, @limit, @window),
         {:ok, user_id} <- Identity.create_person(person),
         :ok <- Identity.send_invite(user_id) do
      render(conn, :sent, email: person.email)
    else
      {:error, errors} when is_map(errors) ->
        conn |> put_status(422) |> render(:new, form: form(params), errors: errors, open?: true)

      {:error, :exists} ->
        errors = %{
          "email" =>
            "An Idejo ID already uses this email: sign in instead, or reset its password there."
        }

        conn |> put_status(422) |> render(:new, form: form(params), errors: errors, open?: true)

      {:error, :rate_limited} ->
        conn
        |> put_status(429)
        |> render(:new,
          form: form(params),
          errors: %{"form" => "Too many sign-ups from here: try again in an hour."},
          open?: true
        )

      {:error, :closed} ->
        conn |> put_status(503) |> render(:new, form: form(%{}), errors: %{}, open?: false)

      {:error, _provider} ->
        conn
        |> put_status(503)
        |> render(:new,
          form: form(params),
          errors: %{"form" => "Idejo ID could not be reached: try again in a moment."},
          open?: true
        )
    end
  end

  defp validate(params) do
    errors =
      %{}
      |> check(
        "email",
        params["email"] =~ ~r/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/ and
          String.length(params["email"]) <= 254,
        "Give your email address."
      )
      |> check(
        "display_name",
        params["display_name"] != "" and String.length(params["display_name"]) <= 100,
        "Give the name people see (up to 100 characters)."
      )
      |> check(
        "given_name",
        String.length(params["given_name"]) <= 200,
        "At most 200 characters."
      )
      |> check(
        "family_name",
        String.length(params["family_name"]) <= 200,
        "At most 200 characters."
      )

    if errors == %{} do
      {given, family} = Identity.placeholder_names()

      {:ok,
       %{
         email: String.downcase(params["email"]),
         display_name: params["display_name"],
         given_name: blank_to(params["given_name"], given),
         family_name: blank_to(params["family_name"], family),
         language: "en"
       }}
    else
      {:error, errors}
    end
  end

  defp check(errors, _field, true, _message), do: errors
  defp check(errors, field, false, message), do: Map.put(errors, field, message)

  defp blank_to("", placeholder), do: placeholder
  defp blank_to(value, _placeholder), do: value

  defp form(params), do: Phoenix.Component.to_form(params, as: :signup)

  # Behind the bundle's Caddy the peer is Caddy: the client is the last X-Forwarded-For entry
  # Caddy added.
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.last() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
