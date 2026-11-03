# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.CaddyHTML do
  @moduledoc "The page shown when a forum's container does not answer (HN-02). No script or style."
  use IdejoHubWeb, :html

  def forum_unavailable(assigns) do
    ~H"""
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title}</title>
      </head>
      <body>
        <main>
          <h1>{@title}</h1>
          <p>{@text}</p>
        </main>
      </body>
    </html>
    """
  end
end
