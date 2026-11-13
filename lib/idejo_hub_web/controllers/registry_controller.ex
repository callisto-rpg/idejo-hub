# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.RegistryController do
  @moduledoc """
  The sign-in host's JSON API for idejo servers not hosted here (steward decisions
  2026-11-06; `IdejoHub.Identity.OutsideForums`; extra review: DV-06). Under `/account/api`
  on `IDEJO_ID_DOMAIN` (Caddy already sends `/account*` there to the Hub), outside the
  browser pipeline: no session, no cookie, so no CSRF token; the registration key or the
  forum's client credentials (HTTP Basic) are the authority.

    * `POST /account/api/registrations` `{"host", "name"}` → 201 `{"registration",
      "proof", "proof_path", "expires_in"}` (ten an hour per address);
    * `POST /account/api/registrations/verify` `{"registration"}` → 200 `{"issuer",
      "client_id", "client_secret", "label", "sign_up_url", "directory_url",
      "chat_url", "topics_url"}`;
    * `GET /account/api/listing`, `PUT /account/api/listing` `{"listed", "name"}`, with the
      client id and secret → `{"listing"}`: `none`, `requested`, `approved`, `refused`.

  Errors: `{"error": code, "message"}`.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.Identity.{OutsideForum, OutsideForums, Proof}
  alias IdejoHub.RateLimit

  def create(conn, params) do
    with :ok <- RateLimit.hit({:registry, client_ip(conn)}, 10, 3600),
         {:ok, %{registration: registration, proof: proof}} <-
           OutsideForums.start(params["host"], params["name"]) do
      conn
      |> put_status(201)
      |> json(%{
        registration: registration,
        proof: proof,
        proof_path: Proof.path(),
        expires_in: OutsideForums.challenge_seconds()
      })
    else
      error -> fail(conn, error)
    end
  end

  def verify(conn, params) do
    with :ok <- RateLimit.hit({:registry_verify, client_ip(conn)}, 30, 3600),
         {:ok, credentials} <- OutsideForums.verify(params["registration"]) do
      conn |> put_resp_header("cache-control", "no-store") |> json(credentials)
    else
      error -> fail(conn, error)
    end
  end

  def show_listing(conn, _params) do
    case forum(conn) do
      nil -> fail(conn, {:error, :unauthorized})
      forum -> json(conn, %{listing: forum.listing})
    end
  end

  def update_listing(conn, %{"listed" => listed} = params) when is_boolean(listed) do
    with %OutsideForum{} = forum <- forum(conn) || {:error, :unauthorized},
         {:ok, forum} <- OutsideForums.set_listing(forum, listed, params["name"]) do
      json(conn, %{listing: forum.listing})
    else
      error -> fail(conn, error)
    end
  end

  def update_listing(conn, _params), do: fail(conn, {:error, :invalid_request})

  defp forum(conn) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {client_id, secret} -> OutsideForums.authenticate(client_id, secret)
      :error -> nil
    end
  end

  defp fail(conn, {:error, :rate_limited}),
    do: error(conn, 429, "rate_limited", "Too many requests from here: try again in an hour.")

  defp fail(conn, {:error, :invalid_host}),
    do:
      error(
        conn,
        422,
        "invalid_host",
        "Give the forum's own host name, like forum.example.org (not one of this Hub's)."
      )

  defp fail(conn, {:error, :invalid_name}),
    do: error(conn, 422, "invalid_name", "Give the forum's name (up to 100 characters).")

  defp fail(conn, {:error, :invalid_request}),
    do: error(conn, 422, "invalid_request", "The request is missing a field.")

  defp fail(conn, {:error, :unavailable}),
    do: error(conn, 503, "unavailable", "idejo ID is not set up on this Hub.")

  defp fail(conn, {:error, :unknown}),
    do: error(conn, 404, "unknown", "No registration with that key: start again.")

  defp fail(conn, {:error, :expired}),
    do: error(conn, 410, "expired", "The registration expired: start again.")

  defp fail(conn, {:error, :unauthorized}),
    do: error(conn, 401, "unauthorized", "Unknown client id or secret.")

  defp fail(conn, {:error, reason}),
    do:
      error(
        conn,
        422,
        "proof_failed",
        "Could not check the forum: " <> OutsideForums.why(reason) <> "."
      )

  defp error(conn, status, code, message),
    do: conn |> put_status(status) |> json(%{error: code, message: message})

  # Behind the bundle's Caddy the peer is Caddy: the client is the last X-Forwarded-For entry
  # Caddy added (as sign-up).
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [value | _] -> value |> String.split(",") |> List.last() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
