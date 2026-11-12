# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.PasswordResetHTML do
  @moduledoc "SC-08: the forgotten-password pages."
  use IdejoHubWeb, :html

  embed_templates "password_reset_html/*"
end
