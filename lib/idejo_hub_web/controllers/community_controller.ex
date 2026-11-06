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

  def index(conn, %{"subject" => subject}) when is_binary(subject) and subject != "" do
    with {client_id, secret} <- Plug.BasicAuth.parse_basic_auth(conn),
         {:ok, communities} <- IdejoHub.Community.joined(client_id, secret, subject) do
      conn |> put_resp_header("cache-control", "no-store") |> json(%{communities: communities})
    else
      _ -> unauthorized(conn)
    end
  end

  def index(conn, _params), do: unauthorized(conn)

  defp unauthorized(conn), do: conn |> put_status(401) |> json(%{error: "unauthorized"})
end
