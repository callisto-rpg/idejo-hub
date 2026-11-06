# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.Alerts do
  @moduledoc """
  OP-08: alerts by email to the operator's alert address (Settings, HA-05) when

  - a forum has been down for 5 minutes (`check_forums/1`, after each OP-07 health check:
    `forums.down_since`); one email when it starts, one when the forum answers again (or
    leaves `running`, silently);
  - a backup fails (`backup_failed/3`): a forum's backup, the Hub's own (OP-10), or an
    off-server copy (OP-02) after its last attempt; one email each time;
  - the disk holding the Hub's store is above 85% (`check_disk/1`, every minute); one email
    when it passes 85%, one when it is back under 80% (so a disk hovering at 85% does not
    send one a minute).

  A condition that lasts is an `alerts` row (unique `key`), so a restart neither forgets nor
  repeats it. Every email is audited as `alert.email` (`ok`, or `failed` with the reason: no
  alert address, no SMTP server, or the server's answer).
  """

  import Ecto.Query

  require Logger

  alias IdejoHub.{Audit, Forums, Mailer, Repo, Settings}
  alias IdejoHub.Forums.{Errors, Export}
  alias IdejoHub.Operations
  alias IdejoHub.Operations.Alerts.Alert

  @down_after 5 * 60
  @disk_high 85
  @disk_clear 80

  @doc "The forums down for 5 minutes or more get an alert; forums that answer again, an all clear."
  @spec check_forums(DateTime.t()) :: :ok
  def check_forums(now \\ DateTime.utc_now(:second)) do
    Enum.each(Forums.list_forums(), &check_forum(&1, now))
  end

  defp check_forum(
         %{status: "running", health: "down", down_since: %DateTime{} = since} = forum,
         now
       ) do
    if DateTime.diff(now, since) >= @down_after do
      host = Forums.host(forum)

      open(key(forum), now, "#{host} is down", forum, """
      #{host} has not answered its health check since #{time(since)}.

      Its page in the Hub: #{hub_url("/forums/#{forum.id}")}
      """)
    end

    :ok
  end

  defp check_forum(%{status: "running", health: "ok"} = forum, _now) do
    host = Forums.host(forum)

    close(key(forum), "#{host} is back up", forum, """
    #{host} answers its health check again (checked #{time(forum.health_at)}).
    """)
  end

  defp check_forum(%{status: "running"}, _now), do: :ok
  defp check_forum(forum, _now), do: drop(key(forum))

  defp key(forum), do: "forum_down:#{forum.subdomain}"

  @doc "The disk holding the Hub's store: above 85% opens an alert, under 80% closes it."
  @spec check_disk(map() | :unavailable, DateTime.t()) :: :ok
  def check_disk(reading \\ disk(), now \\ DateTime.utc_now(:second))

  def check_disk(%{used: used, available: available}, now) when used + available > 0 do
    percent = used * 100 / (used + available)
    shown = "#{round(percent)}%"

    cond do
      percent > @disk_high ->
        open("disk", now, "The server's disk is #{shown} full", nil, """
        The disk holding the Hub's backups and forums is #{shown} full (#{gb(available)} free).
        Backups stop when it is full. Free space, or move the store to a larger disk.

        The server page: #{hub_url("/server")}
        """)

      percent < @disk_clear ->
        close("disk", "The server's disk is below 80% again", nil, """
        The disk holding the Hub's backups and forums is #{shown} full (#{gb(available)} free).
        """)

      true ->
        :ok
    end
  end

  def check_disk(_unavailable, _now), do: :ok

  @doc "A backup failed: one email. `what` names it: a forum's host, or the Hub."
  @spec backup_failed(String.t(), map() | nil, String.t()) :: :ok
  def backup_failed(what, forum, error) do
    _sent_or_audited =
      notify("Backup failed: #{what}", forum, """
      The backup of #{what} failed at #{time(DateTime.utc_now(:second))}:

      #{error}

      #{if forum, do: "Its page in the Hub: #{hub_url("/forums/#{forum.id}")}", else: "The server page: #{hub_url("/server")}"}
      """)

    :ok
  end

  ## Open and closed conditions

  defp open(key, now, subject, forum, body) do
    {count, _} =
      Repo.insert_all(Alert, [%{key: key, subject: subject, opened_at: now}],
        on_conflict: :nothing,
        conflict_target: :key
      )

    if count == 1 do
      if notify(subject, forum, body) == :ok do
        Repo.update_all(from(a in Alert, where: a.key == ^key), set: [notified_at: now])
      end
    end

    :ok
  end

  defp close(key, subject, forum, body) do
    case Repo.delete_all(from a in Alert, where: a.key == ^key) do
      {1, _} -> notify(subject, forum, body)
      _none -> :ok
    end
  end

  defp drop(key) do
    Repo.delete_all(from a in Alert, where: a.key == ^key)
    :ok
  end

  @doc "The alerts open now, oldest first."
  @spec list_open() :: [Alert.t()]
  def list_open, do: Repo.all(from a in Alert, order_by: a.opened_at)

  ## Email

  defp notify(subject, forum, body) do
    result =
      case Settings.get("alert_email") do
        to when is_binary(to) and to != "" ->
          Mailer.send_text(to, "[Idejo Hub] " <> subject, body)

        _none ->
          {:error, :no_alert_email}
      end

    case result do
      {:ok, _} ->
        Audit.record("hub", "alert.email", "ok", forum, %{"subject" => subject})
        :ok

      {:error, reason} ->
        Logger.warning("OP-08: alert not sent (#{inspect(reason, limit: 3)}): #{subject}")

        Audit.record("hub", "alert.email", "failed", forum, %{
          "subject" => subject,
          "error" => error(reason)
        })

        :error
    end
  end

  defp error(:no_alert_email), do: "no alert email set (Settings)"
  defp error(:no_smtp), do: "no SMTP server (Settings, or HUB_SMTP_HOST)"
  defp error(reason), do: Errors.describe(reason)

  # Tests set a fixed reading (`config :idejo_hub, Alerts, disk:`), never the machine's own.
  defp disk do
    case Application.get_env(:idejo_hub, __MODULE__, [])[:disk] do
      nil -> Operations.Server.disk(Application.fetch_env!(:idejo_hub, Export)[:dir])
      reading -> reading
    end
  end

  defp hub_url(path), do: IdejoHubWeb.Endpoint.url() <> path
  defp time(nil), do: "—"
  defp time(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp gb(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"
end
