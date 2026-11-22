# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.PasswordNotices do
  @moduledoc """
  An idejo ID's password changed (steward request 2026-11-22): the Hub emails its owner, with
  a button to the members' inbox, in place of Zitadel's own notice (turned off by
  `Identity.configure/3`: it also went out for the first password, chosen right after
  sign-up, and its button led to Zitadel's console). The first password gets no notice.

  Read from the provider's events with the joined forums (`SyncWorker`, every five minutes),
  from where it last read (`State.password_events_since`); the first run only starts there,
  so nobody hears of a change made before. Never logs an email address.
  """
  require Logger

  alias IdejoHub.{Community, Forums, Identity, Mailer, Repo}
  alias IdejoHub.Identity.{Members, State}

  @subject "Your idejo ID password was changed"

  @doc "Emails the owners of passwords changed since the last run (not their first ones)."
  @spec run() :: :ok | {:error, term()}
  def run do
    if Identity.enabled?(), do: notify(Members.state()), else: :ok
  end

  defp notify(%State{password_events_since: nil} = state) do
    read_up_to(state, DateTime.utc_now())
  end

  defp notify(%State{password_events_since: since} = state) do
    with {:ok, changes} <- Identity.password_changes_since(since) do
      # The provider answers from `since` on, that moment included: only what is newer.
      new = Enum.filter(changes, &(DateTime.compare(&1.at, since) == :gt))
      for change <- new, !change.first, do: tell(change.user_id)

      case List.last(new) do
        nil -> :ok
        last -> read_up_to(state, last.at)
      end
    end
  end

  defp read_up_to(state, at) do
    state |> Ecto.Changeset.change(password_events_since: at) |> Repo.update!()
    :ok
  end

  defp tell(user_id) do
    button = link()

    with {:ok, %{email: email}} when is_binary(email) <- Identity.person(user_id),
         {:ok, _} <- Mailer.send_member(email, @subject, text(button), html(button)) do
      :ok
    else
      _not_sent ->
        Logger.warning("idejo ID password notice not sent (user #{user_id})")
        :ok
    end
  end

  @doc false
  # The button: to the members' inbox, else (no inbox set up) to the idejo ID's own page.
  def link do
    if Forums.inbox(),
      do: {Community.my_url(), "Go to your inbox"},
      else: {"https://#{Identity.config(:domain)}/account", "Go to your idejo ID"}
  end

  defp text({url, label}) do
    """
    The password of your idejo ID was just changed.

    If you changed it, there is nothing more to do. If you did not, choose a new password at
    once from the sign-in page ("Forgot password?").

    #{label}: #{url}
    """
  end

  defp html({url, label}) do
    href = url |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    """
    <!DOCTYPE html>
    <html>
      <body style="font-family: sans-serif; color: #000000; background: #fdfcf6; padding: 24px;">
        <p>The password of your idejo ID was just changed.</p>
        <p>
          If you changed it, there is nothing more to do. If you did not, choose a new password
          at once from the sign-in page ("Forgot password?").
        </p>
        <p style="margin: 32px 0;">
          <a href="#{href}" style="background: #daa304; color: #000000; padding: 12px 24px;
             border-radius: 8px; text-decoration: none; font-weight: bold;">#{label}</a>
        </p>
      </body>
    </html>
    """
  end
end
