# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.Alerts.Alert do
  @moduledoc "OP-08: a condition an alert is open for, until it ends (`IdejoHub.Operations.Alerts`)."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "alerts" do
    field :key, :string
    field :subject, :string
    field :opened_at, :utc_datetime
    field :notified_at, :utc_datetime
  end
end
