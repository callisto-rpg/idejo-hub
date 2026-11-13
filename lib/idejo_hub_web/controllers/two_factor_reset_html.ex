# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.TwoFactorResetHTML do
  @moduledoc "SC-08: the lost two-factor pages (steward request 2026-11-13)."
  use IdejoHubWeb, :html

  embed_templates "two_factor_reset_html/*"
end
