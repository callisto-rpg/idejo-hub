# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.DirectoryHTML do
  @moduledoc "The forums directory's page."
  use IdejoHubWeb, :html

  embed_templates "directory_html/*"

  @doc """
  A forum's card: its logo, name and host link to it; **Join** (idejo's yellow) opens its
  sign-in with idejo ID, or **Open** (green) for a forum the visitor joined.
  """
  attr :forum, :map, required: true
  attr :id_prefix, :string, required: true

  attr :compact, :boolean,
    default: false,
    doc: "My Forums (steward request 2026-11-07): half height, logo left, no address, Open gold"

  def forum_card(assigns) do
    ~H"""
    <div class={["directory-card", @compact && "is-compact"]} id={"#{@id_prefix}-#{@forum.host}"}>
      <a href={@forum.url} class="directory-link">
        <img src={@forum.logo} alt="" class="directory-logo" width="56" height="56" loading="lazy" />
        <span class="directory-name">{@forum.name}</span>
        <span :if={!@compact} class="directory-host">{@forum.host}</span>
        <%!-- Steward request 2026-11-07: hosted forums' members, from their last stats. --%>
        <span :if={!@compact && @forum.members} class="directory-members">
          {members_label(@forum.members)}
        </span>
      </a>
      <a
        :if={!@forum.joined?}
        href={@forum.join}
        class="btn btn-sm btn-primary directory-join"
        aria-label={"Join #{@forum.name}"}
      >
        Join
      </a>
      <a
        :if={@forum.joined?}
        href={@forum.url}
        class={["btn btn-sm directory-open", if(@compact, do: "btn-primary", else: "btn-success")]}
        aria-label={"Open #{@forum.name}"}
      >
        Open
      </a>
    </div>
    """
  end

  @doc ~S("N Members", or "1 Member".)
  def members_label(1), do: "1 Member"
  def members_label(count), do: "#{count} Members"

  @doc "The address parameters of another page of the same search."
  def page_params(%{search: ""}, page), do: [page: page]
  def page_params(%{search: search}, page), do: [q: search, page: page]
end
