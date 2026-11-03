# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.RateLimit do
  @moduledoc """
  A small fixed-window limit in ETS (no dependency), for the members' pages (ID-02 sign-up:
  each one makes a person and sends an email, so it is limited per address).
  """
  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :timer.send_interval(:timer.minutes(10), :sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{{:_, :_, :"$1"}, :_, :"$2"}, [{:<, :"$2", now}], [true]}])
    {:noreply, state}
  end

  @doc "Counts one hit for `key`: `:ok` while under `limit` per `window` seconds."
  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def hit(key, limit, window) do
    now = System.system_time(:second)
    bucket = div(now, window)
    expires = (bucket + 1) * window

    count =
      :ets.update_counter(@table, {key, bucket, nil}, {2, 1}, {{key, bucket, nil}, 0, expires})

    if count <= limit, do: :ok, else: {:error, :rate_limited}
  end
end
