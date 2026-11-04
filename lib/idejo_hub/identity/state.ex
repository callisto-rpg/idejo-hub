# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.State do
  @moduledoc "The one row of identity bookkeeping: events read up to, the members' pages' client."
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "identity_state" do
    field :events_since, :utc_datetime_usec
    field :account_app_id, :string
    field :account_client_id, :string
    field :account_client_secret_enc, :binary, redact: true
  end
end
