# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.Mail do
  @moduledoc """
  HN-07: outgoing email per forum.

  - **Sender**: each forum sends as its display name (Idejo's server name, set by headless
    setup) at its own address, `forums.mail_from` (default `noreply@<forum host>`), passed as
    `IDEJO_SMTP_FROM`.
  - **Shared SMTP**: when the Hub has `HUB_SMTP_HOST` (and its port, security, username,
    password), every forum gets them as `IDEJO_SMTP_*` (Idejo AD-13).
  - **The forum's own SMTP**: its owner sets it in the forum's Admin → Email, which always
    wins over the environment (Idejo AD-08). The Hub stores nothing for it.

  The shared SMTP password reaches every forum's container environment; forum admins never
  see it (Idejo never shows environment SMTP settings).
  """

  @doc "The `IDEJO_SMTP_*` variables for a forum's container."
  @spec env(String.t()) :: %{String.t() => String.t()}
  def env(mail_from) do
    shared =
      for {key, value} <- Application.get_env(:idejo_hub, __MODULE__, [])[:shared_smtp] || [],
          value not in [nil, ""],
          into: %{},
          do: {"IDEJO_SMTP_" <> String.upcase(to_string(key)), to_string(value)}

    Map.put(shared, "IDEJO_SMTP_FROM", mail_from)
  end

  @doc "Whether the Hub gives forums a shared SMTP server."
  @spec shared?() :: boolean()
  def shared?, do: map_size(env("x@y")) > 1

  @doc "The default sender address for a forum host."
  @spec default_from(String.t()) :: String.t()
  def default_from(host), do: "noreply@" <> host
end
