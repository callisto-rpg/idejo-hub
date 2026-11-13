# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.PictureController do
  @moduledoc """
  An idejo ID's picture (steward decisions 2026-11-06; `IdejoHub.Identity.Profiles`):
  `GET /account/pictures/<key>.webp` on the sign-in host, public, no session. A new key at
  each change, so it is cached for good; served as WebP only, `nosniff`, in a sandbox.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.Identity.Profiles

  def show(conn, %{"key" => file}) do
    with key when key != file <- String.replace_suffix(file, ".webp", ""),
         picture when is_binary(picture) <- Profiles.picture(key) do
      conn
      |> put_resp_content_type("image/webp", nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, picture)
    else
      _ -> send_resp(conn, 404, "")
    end
  end
end
