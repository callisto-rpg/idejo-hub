# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets a strict `content-security-policy` header on browser responses, as Idejo does.

  Everything is served from the Hub itself, so only `'self'` is allowed. Inline `<script>`
  and `<style>` elements are refused unless they carry the per-request nonce stored in
  `conn.assigns.script_csp_nonce` and `conn.assigns.style_csp_nonce` (the root layout's
  theme script, and LiveDashboard in development).
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    script_nonce = nonce()
    style_nonce = nonce()

    conn
    |> assign(:script_csp_nonce, script_nonce)
    |> assign(:style_csp_nonce, style_nonce)
    # Written when the response is sent, so a page can name the image hosts it shows
    # (`:csp_img_hosts`, the forums directory's outside forums).
    |> register_before_send(fn conn ->
      put_resp_header(
        conn,
        "content-security-policy",
        policy(script_nonce, style_nonce, conn.assigns[:csp_img_hosts] || [])
      )
    end)
  end

  defp policy(script_nonce, style_nonce, img_hosts) do
    domain = Application.fetch_env!(:idejo_hub, IdejoHub.Forums)[:domain]

    img =
      ["'self'", "data:", "blob:", "https://*.#{domain}"] ++
        for host <- img_hosts,
            host =~ ~r/\A[a-z0-9.-]+\z/,
            not String.ends_with?(host, "." <> domain),
            uniq: true,
            do: "https://" <> host

    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{script_nonce}'",
        "style-src 'self' 'nonce-#{style_nonce}'",
        # The forums directory shows each forum's logo, from its own host (`/logo`).
        "img-src " <> Enum.join(img, " "),
        "font-src 'self' data:",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'"
      ],
      "; "
    )
  end

  defp nonce, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
