# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.SetupWorker do
  @moduledoc """
  ID-02, ID-08: makes the identity provider's settings match the Hub's (`Identity.configure/2`):
  its own sign-up form off (people sign up on the Hub's page), passkeys and two factor on,
  and the Hub's SMTP for its invites (the Hub's sender, `Settings.sender/0`).

  Queued at boot and after the email settings change; retried with back-off while the
  provider is starting (it may come up after the Hub). One at a time.
  """
  use Oban.Worker,
    queue: :operations,
    max_attempts: 20,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  alias IdejoHub.{Identity, Settings}
  alias IdejoHub.Identity.Members

  @impl Oban.Worker
  def perform(_job) do
    if Identity.enabled?() do
      with :ok <-
             Identity.configure(Settings.shared_smtp(), Settings.sender()),
           do: Members.ensure_account_client()
    else
      :ok
    end
  end

  @doc "Queues a run (nothing when the Hub has no identity provider)."
  @spec queue() :: :ok
  def queue do
    if Identity.enabled?(), do: {:ok, _} = Oban.insert(new(%{}))
    :ok
  end
end
