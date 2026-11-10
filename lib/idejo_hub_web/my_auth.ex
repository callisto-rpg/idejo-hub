# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.MyAuth do
  @moduledoc """
  Who is looking at the members' page (steward request 2026-11-10): an Idejo ID's subject,
  learnt from the sign-in host (`IdejoHubWeb.MyController`) and kept in this host's session
  for twelve hours. LiveViews mount with `on_mount: {IdejoHubWeb.MyAuth, :require_member}`
  (`@subject`); without one they go to `/sign-in`, which comes back.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  @member_key "my_member"
  @seconds 12 * 3600

  @doc false
  def member_key, do: @member_key

  @doc "The subject in the session, or nil once twelve hours have passed."
  @spec subject(map()) :: String.t() | nil
  def subject(%{@member_key => %{"sub" => subject, "at" => at}})
      when is_binary(subject) and is_integer(at) do
    if System.system_time(:second) - at <= @seconds, do: subject
  end

  def subject(_session), do: nil

  def on_mount(:require_member, _params, session, socket) do
    case subject(session) do
      nil -> {:halt, redirect(socket, to: "/sign-in")}
      subject -> {:cont, assign(socket, :subject, subject)}
    end
  end
end
