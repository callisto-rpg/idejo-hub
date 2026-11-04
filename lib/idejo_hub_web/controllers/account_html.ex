# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.AccountHTML do
  @moduledoc "ID-05, ID-06: the member's own page."
  use IdejoHubWeb, :html

  embed_templates "account_html/*"

  @doc "What a forum's line says about this identity there."
  def state_text("joined"), do: "Joined"
  def state_text("leaving"), do: "Leaving…"
  def state_text("left"), do: "Left (your account there is kept)"
  def state_text("deleting"), do: "Deleting your account there…"
  def state_text("deleted"), do: "Your account there is deleted"

  def error_text("last_owner"),
    do: "You are this forum's only owner: give another member the owner role there first."

  def error_text(nil), do: nil
  def error_text(_other), do: "That did not work. Please try again later."

  def forum_url(forum), do: "https://" <> IdejoHub.Forums.host(forum)
end
