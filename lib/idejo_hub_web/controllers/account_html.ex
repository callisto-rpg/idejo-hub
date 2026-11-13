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

  def forum_url(forum), do: "https://" <> forum_host(forum)
  def forum_host(forum), do: IdejoHub.Forums.host(forum)

  @doc """
  SC-07, a forum's log for its owner: who did it. A member is never named (their identity
  is theirs: `member:<subject>` reads "A member"); the Hub's own jobs say so; an operator
  shows as their address.
  """
  def who("member:" <> _subject), do: "A member"
  def who("schedule"), do: "The Hub (scheduled)"
  def who("hub"), do: "The Hub"
  def who("command line"), do: "The Hub's command line"
  def who(operator), do: "Operator " <> operator

  @actions %{
    "forum.create" => "Created",
    "forum.backup" => "Backup",
    "forum.backup.offsite" => "Off-server copy of a backup",
    "forum.export" => "Export",
    "forum.upgrade" => "Upgrade",
    "forum.restore" => "Restore",
    "forum.suspend" => "Suspended",
    "forum.resume" => "Resumed",
    "forum.recreate" => "Container made again",
    "forum.delete" => "Deletion",
    "forum.delete.cancel" => "Deletion cancelled",
    "forum.purge" => "Data purged",
    "forum.owner_link.take" => "Owner's link handed out",
    "forum.secret_key_base.reveal" => "SECRET_KEY_BASE shown to the operator",
    "forum.archive.download" => "Archive downloaded",
    "forum.import" => "Imported from a standalone backup",
    "identity.forum_leave" => "A member left through idejo ID",
    "identity.forum_delete" => "A member deleted their account through idejo ID",
    "alert.email" => "Alert emailed to the operator"
  }

  @doc "What was done, in words where the Hub has them; else the action's name."
  def what(action), do: Map.get(@actions, action, action)

  @doc """
  An entry's details for the owner: never a member's identity (identity entries keep it under
  `"subject"`; an alert's `"subject"` is its email's subject line, which stays), nor a
  storage key.
  """
  def owner_details(%{action: action, details: details}) do
    hidden = if String.starts_with?(action, "identity."), do: ["subject", "key"], else: ["key"]

    details
    |> Map.drop(hidden)
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {key, value} -> "#{key}: #{value(value)}" end)
  end

  defp value(value) when is_binary(value), do: value
  defp value(value) when is_list(value), do: Enum.map_join(value, ", ", &value/1)
  defp value(value), do: inspect(value)
end
