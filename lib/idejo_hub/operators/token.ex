# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operators.Token do
  @moduledoc "A signed-in operator session (SC-08): only the token's SHA-256 is stored."
  use Ecto.Schema

  schema "operator_tokens" do
    belongs_to :operator, IdejoHub.Operators.Operator
    field :token_hash, :binary, redact: true

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
