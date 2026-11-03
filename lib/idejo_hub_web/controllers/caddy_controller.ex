# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.CaddyController do
  @moduledoc """
  Endpoints only Caddy calls, on the internal network (HN-02). The bundle's Caddyfile answers
  404 to `/internal/*` from outside.

  - `GET /internal/caddy/ask?domain=HOST`: Caddy's on-demand TLS check. 200 lets Caddy get
    a certificate for HOST; anything else refuses (`Forums.certificate_allowed?/1`).
  - `GET /internal/forum-unavailable`: what a forum's visitors see when Caddy cannot reach
    its container (`X-Idejo-Forum-Host` names the host): being set up, paused (FL-04), or
    temporarily unavailable. Plain HTML, no script or style, nothing about the forum beyond
    its name.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.Forums

  def ask(conn, %{"domain" => domain}) when is_binary(domain) do
    if Forums.certificate_allowed?(domain),
      do: send_resp(conn, 200, "ok"),
      else: send_resp(conn, 404, "unknown host")
  end

  def ask(conn, _params), do: send_resp(conn, 400, "domain is required")

  def forum_unavailable(conn, _params) do
    host = conn |> get_req_header("x-idejo-forum-host") |> List.first("")

    {status, title, text} =
      case Forums.for_host(host) do
        %{status: "creating"} = forum ->
          {503, forum.display_name, "This forum is being set up. Try again in a minute."}

        %{status: "suspended"} = forum ->
          {503, forum.display_name, "This forum is paused for maintenance. Its posts are safe."}

        %{status: status} = forum when status in ["running", "failed"] ->
          {503, forum.display_name, "This forum is temporarily unavailable. Try again shortly."}

        _deleted_or_unknown ->
          {404, "Not found", "There is no forum at this address."}
      end

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("retry-after", "60")
    |> put_status(status)
    |> put_view(html: IdejoHubWeb.CaddyHTML)
    |> put_format("html")
    |> render(:forum_unavailable, layout: false, title: title, text: text)
  end
end
