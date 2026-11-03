# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Settings.Setting do
  @moduledoc "One stored setting (HA-05); `value` is JSON, encrypted for secret keys."
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field :value, :binary, redact: true
    timestamps(type: :utc_datetime)
  end
end
