# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.Mail do
  @moduledoc """
  HN-07: outgoing email per forum.

  - **Sender**: each forum sends as its display name (Idejo's server name, set by headless
    setup) from the Hub's own sender address (`Settings.sender/0`; steward request
    2026-11-06: a new forum's email settings are the Hub's, unchanged), passed as
    `IDEJO_SMTP_FROM`; or from `forums.mail_from` when the operator gave one at creation
    (forums made before 2026-11-06 keep the `noreply@<forum host>` they were given).
  - **Shared SMTP**: when the Hub has an SMTP host, set in Settings (HA-05) or else in
    `HUB_SMTP_HOST` (with its port, security, username, password), every forum gets it as
    `IDEJO_SMTP_*` (Idejo AD-13). It reaches a forum when its container is made: created,
    upgraded or restored.
  - **The forum's own SMTP**: its owner sets it in the forum's Admin → Email, which always
    wins over the environment (Idejo AD-08). The Hub stores nothing for it.

  The shared SMTP password reaches every forum's container environment; forum admins never
  see it (Idejo never shows environment SMTP settings).
  """

  @doc "The `IDEJO_SMTP_*` variables for a forum's container."
  @spec env(String.t() | nil) :: %{String.t() => String.t()}
  def env(mail_from) do
    shared =
      for {key, value} <- IdejoHub.Settings.shared_smtp() || [],
          key != :from,
          value not in [nil, ""],
          into: %{},
          do: {"IDEJO_SMTP_" <> String.upcase(to_string(key)), to_string(value)}

    from = if mail_from in [nil, ""], do: IdejoHub.Settings.sender(), else: mail_from
    Map.put(shared, "IDEJO_SMTP_FROM", from)
  end

  @doc "Whether the Hub gives forums a shared SMTP server."
  @spec shared?() :: boolean()
  def shared?, do: map_size(env("x@y")) > 1

  @doc "The default sender address for a forum host."
  @spec default_from(String.t()) :: String.t()
  def default_from(host), do: "noreply@" <> host
end
