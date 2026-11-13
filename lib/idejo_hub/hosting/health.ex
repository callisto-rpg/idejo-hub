# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.Health do
  @moduledoc """
  Asks a forum's `GET /health` (idejo AD-15) on the forum network, over plain http (idejo
  answers it without TLS for exactly this). 200 means database reachable and migrations
  applied; anything else, including a refused connection while it starts, means not yet.
  """

  alias IdejoHub.Hosting.ForumContainer

  @doc "One check: `:ok`, or `{:error, reason}` with no detail from the forum."
  @spec check(String.t()) :: :ok | {:error, term()}
  def check(slug) do
    case Req.get(req(), url: "http://#{ForumContainer.name(slug)}:4000/health") do
      {:ok, %Req.Response{status: 200}} -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, _exception} -> {:error, :unreachable}
    end
  end

  @doc "Checks every `interval` ms until healthy or `timeout` ms have passed."
  @spec wait(String.t(), keyword()) :: :ok | {:error, :timeout}
  def wait(slug, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(3))
    interval = Keyword.get(opts, :interval, 2_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(slug, interval, deadline)
  end

  defp poll(slug, interval, deadline) do
    cond do
      check(slug) == :ok ->
        :ok

      System.monotonic_time(:millisecond) + interval > deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(interval)
        poll(slug, interval, deadline)
    end
  end

  defp req do
    Req.new(
      [retry: false, redirect: false, receive_timeout: 5_000, connect_options: [timeout: 2_000]] ++
        Application.get_env(:idejo_hub, :health_req_options, [])
    )
  end
end
