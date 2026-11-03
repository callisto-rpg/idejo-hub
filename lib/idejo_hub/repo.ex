# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo do
  use Ecto.Repo,
    otp_app: :idejo_hub,
    adapter: Ecto.Adapters.Postgres
end
