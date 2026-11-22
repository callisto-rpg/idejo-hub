# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.SetupWorker do
  @moduledoc """
  ID-02, ID-08: makes the identity provider's settings match the Hub's (`Identity.configure/3`):
  its own sign-up form off (people sign up on the Hub's page), passkeys and two factor on,
  and the Hub's SMTP for its emails (the Hub's sender, `Settings.sender/0`), its own password
  notice off, and its login going to the members' inbox once that exists (steward request
  2026-11-22).

  Queued at boot, after the email settings change and once the inbox is set up; retried with
  back-off while the provider is starting (it may come up after the Hub). One at a time.
  """
  use Oban.Worker,
    queue: :operations,
    max_attempts: 20,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  alias IdejoHub.{Community, Forums, Identity, Settings}
  alias IdejoHub.Identity.Members

  @impl Oban.Worker
  def perform(_job) do
    if Identity.enabled?() do
      redirect = if Forums.inbox(), do: Community.my_url()

      with :ok <- Identity.configure(Settings.shared_smtp(), Settings.sender(), redirect),
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
