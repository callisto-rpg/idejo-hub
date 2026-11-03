# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.UpgradeWorker do
  @moduledoc """
  OP-04: upgrades one forum to another Idejo version, rolling back on failure.

  1. The host shows the maintenance page (FL-04's mark).
  2. Backup: `idejo-admin backup` in the running container, kept by the Hub as kind
     `upgrade` (never pruned). It also stays in the forum's backups volume for step 6.
  3. Pull the new image. A failure up to here changes nothing: the mark is removed.
  4. Recreate the container on the new image (`ForumContainer.recreate/1`: volumes kept),
     with `IDEJO_SOURCE_URL` for the new version (LB-03). Its command runs Idejo's
     migrations, then the server.
  5. Start it and wait for `/health` 200 within `:upgrade_health_timeout` (default 5 min).
     Success: `running` on the new version, mark removed.
  6. Otherwise, roll back: recreate on the previous image, restore the pre-upgrade backup in
     a one-off container (`idejo-admin restore FILE --yes`, which also undoes the new
     version's migrations), start and wait for health. The forum is `running` on its old
     version and the audit says the upgrade failed and was rolled back. If the rollback
     fails too, it stays stopped behind the maintenance page as `suspended`.
  """
  use Oban.Worker, queue: :lifecycle, max_attempts: 1

  alias IdejoHub.Forums
  alias IdejoHub.Forums.{Archives, Errors}
  alias IdejoHub.Hosting.{Docker, ForumContainer, Health, Maintenance}

  @admin "/app/bin/idejo-admin"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "version" => to, "actor" => actor}}) do
    forum = Forums.get_forum!(id)
    from = forum.idejo_version
    host = Forums.host(forum)
    details = %{"from" => from, "to" => to}

    case prepare(forum, host, to) do
      {:ok, backup} ->
        details = Map.put(details, "backup", backup.file_name)

        case switch(forum, to) do
          :ok ->
            Maintenance.unmark(host)
            Forums.finish_action(Forums.get_forum!(id), actor, "forum.upgrade", %{}, details)

          error ->
            rollback(Forums.get_forum!(id), from, backup, actor, details, error)
        end

      error ->
        Maintenance.unmark(host)
        Forums.fail_action(forum, actor, "forum.upgrade", error, details: details)
    end
  end

  defp prepare(forum, host, to) do
    container = ForumContainer.name(forum.subdomain)

    with :ok <- Maintenance.mark(host),
         {:ok, run} <- Docker.exec(container, [@admin, "backup"]),
         {:ok, backup} <- Archives.collect(forum, container, run, "upgrade"),
         :ok <- ForumContainer.pull_version(to) do
      {:ok, backup}
    end
  end

  # Moves the forum's container to `version`, starts it and waits for health.
  defp switch(forum, version) do
    {:ok, forum} = Forums.update_state(forum, %{idejo_version: version})

    with {:ok, params} <- Forums.container_params(forum),
         {:ok, _id} <- ForumContainer.recreate(params),
         :ok <- Docker.start_container(ForumContainer.name(forum.subdomain)) do
      Health.wait(forum.subdomain, health_options())
    end
  end

  defp rollback(forum, from, backup, actor, details, error) do
    message = Errors.describe(error)

    result =
      with {:ok, forum} <- Forums.update_state(forum, %{idejo_version: from}),
           {:ok, params} <- Forums.container_params(forum),
           {:ok, _id} <- ForumContainer.recreate(params),
           :ok <- restore(params, backup),
           :ok <- Docker.start_container(ForumContainer.name(forum.subdomain)),
           :ok <- Health.wait(forum.subdomain, health_options()) do
        Maintenance.unmark(Forums.host(forum))
      end

    case result do
      :ok ->
        Forums.fail_action(forum, actor, "forum.upgrade", error,
          details: Map.merge(details, %{"rolled_back" => true, "error" => message})
        )

      rollback_error ->
        Docker.stop_container(ForumContainer.name(forum.subdomain))
        {:ok, forum} = Forums.update_state(forum, %{status: "suspended"})

        Forums.fail_action(forum, actor, "forum.upgrade", error,
          details:
            Map.merge(details, %{
              "rolled_back" => false,
              "error" => message,
              "rollback_error" => Errors.describe(rollback_error)
            })
        )
    end
  end

  defp restore(params, backup) do
    result =
      ForumContainer.run_one_off(params, "restore", [@admin, "restore", backup.file_name, "--yes"])

    ForumContainer.remove_one_off(params.slug, "restore")

    case result do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{exit_code: code}} -> {:error, {:command_exit, "restore", code}}
      error -> error
    end
  end

  # Migrations of a new version may take a while: :upgrade_health_timeout (tests set a
  # short :health_wait timeout, which wins).
  defp health_options do
    Keyword.put_new(
      Application.get_env(:idejo_hub, :health_wait, []),
      :timeout,
      Application.fetch_env!(:idejo_hub, IdejoHub.Operations)[:upgrade_health_timeout]
    )
  end
end
