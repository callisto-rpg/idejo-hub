# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Chats.Markdown do
  @moduledoc """
  Chat messages' Markdown, rendered as Idejo renders messages (its extensions: GitHub's,
  spoilers, superscript, highlight, small text; raw HTML off; sanitised), and HTML copied
  from a forum sanitised again (a forum is not trusted with the Hub's pages).
  """

  @options [
    extension: [
      strikethrough: true,
      table: true,
      autolink: true,
      tasklist: true,
      spoiler: true,
      superscript: true,
      highlight: true,
      subtext: true
    ],
    render: [unsafe: false],
    syntax_highlight: nil,
    sanitize: MDEx.Document.default_sanitize_options()
  ]

  # Checked once, at compile time: MDEx checks options given at each call.
  @document MDEx.new(@options)

  @doc "The sanitised HTML of `markdown`."
  @spec to_html(String.t()) :: String.t()
  def to_html(markdown) when is_binary(markdown),
    do: @document |> MDEx.Document.put_markdown(markdown) |> MDEx.to_html!()

  @doc "Someone else's HTML, sanitised."
  @spec sanitize(String.t() | nil) :: String.t()
  def sanitize(nil), do: ""

  def sanitize(html) when is_binary(html),
    do: MDEx.safe_html(html, escape: [:curly_braces_in_code])
end
