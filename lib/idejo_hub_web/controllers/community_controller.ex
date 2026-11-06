# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.CommunityController do
  @moduledoc """
  Idejo's community menu (steward decision 2026-11-06): `GET /internal/community?subject=`,
  asked by a forum on the forum network (Caddy refuses `/internal/*` from outside), with
  HTTP Basic: its OpenID Connect client id and secret. Answers
  `{"communities": [{"name", "url"}]}`, the other running forums that person joined
  (`IdejoHub.Community.joined/3`); 401 for anything else.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.Identity.Profiles

  def index(conn, %{"subject" => subject}) when is_binary(subject) and subject != "" do
    with {client_id, secret} <- Plug.BasicAuth.parse_basic_auth(conn),
         {:ok, communities} <- IdejoHub.Community.joined(client_id, secret, subject) do
      conn |> put_resp_header("cache-control", "no-store") |> json(%{communities: communities})
    else
      _ -> unauthorized(conn)
    end
  end

  def index(conn, _params), do: unauthorized(conn)

  @doc """
  An Idejo ID's public profile (steward decisions 2026-11-06), for a forum the person signed
  in to: `GET …/profile?subject=` → `{"username", "picture"}` (the picture's address);
  `POST …/profile` `{"subject", "username", "picture"}` (Base64 WebP) fills what the Idejo ID
  lacks and answers the same. Hosted forums at `/internal/community/profile`, outside forums
  at `/account/api/profile`, both with their client credentials.
  """
  def profile(conn, %{"subject" => subject}) do
    if member?(conn, subject),
      do: json(conn, Profiles.public(Profiles.get(subject))),
      else: unauthorized(conn)
  end

  def profile(conn, _params), do: unauthorized(conn)

  def fill_profile(conn, %{"subject" => subject} = params) do
    if member?(conn, subject) do
      {:ok, profile} = Profiles.fill(subject, params)
      json(conn, Profiles.public(profile))
    else
      unauthorized(conn)
    end
  end

  def fill_profile(conn, _params), do: unauthorized(conn)

  defp member?(conn, subject) do
    case Plug.BasicAuth.parse_basic_auth(conn) do
      {client_id, secret} -> IdejoHub.Community.member_of_client?(client_id, secret, subject)
      :error -> false
    end
  end

  defp unauthorized(conn), do: conn |> put_status(401) |> json(%{error: "unauthorized"})
end
