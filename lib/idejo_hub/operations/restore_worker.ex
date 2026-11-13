# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.RestoreWorker do
  @moduledoc """
  OP-03: restores a forum from a kept backup or export.

  1. The host shows the maintenance page (FL-04's mark) and the container stops.
  2. The file goes into the forum's backups volume (`Docker.copy_to/3`).
  3. A one-off container with the forum's environment and volumes runs
     `idejo-admin restore FILE --yes` (idejo AD-09: it keeps a backup of what was there).
  4. When the forum has a new `SECRET_KEY_BASE` (restored to a new subdomain from a forum
     still alive), `idejo-admin rotate-push-keys --yes` makes push keys it can read.
  5. The container starts, `/health` must answer 200, and the mark is removed: `running`.

  If a step before the restore fails, the forum goes back as it was. If the restore or what
  follows fails, the forum stays stopped behind the maintenance page as `suspended`, with
  the error, for the operator to look at: never a half-restored forum online.
  """
  use Oban.Worker, queue: :lifecycle, max_attempts: 1

  alias IdejoHub.{Forums, Repo}
  alias IdejoHub.Forums.Export
  alias IdejoHub.Hosting.{Docker, ForumContainer, Health, Maintenance}

  @admin "/app/bin/idejo-admin"

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"forum_id" => id, "export_id" => export_id, "actor" => actor} = args
      }) do
    forum = Forums.get_forum!(id)
    export = Repo.get!(Export, export_id)
    host = Forums.host(forum)
    container = ForumContainer.name(forum.subdomain)

    with {:prepare, :ok} <- {:prepare, prepare(host, container, export)},
         {:restore, :ok} <- {:restore, restore(forum, export, args["rotate_push_keys"] == true)} do
      Forums.finish_action(forum, actor, "forum.restore", %{status: "running"}, %{
        "file" => export.file_name,
        "kind" => export.kind,
        "from" => export.subdomain,
        "rotated_push_keys" => args["rotate_push_keys"] == true
      })
    else
      {:prepare, error} ->
        if args["was"] == "running" do
          Docker.start_container(container)
          Maintenance.unmark(host)
        end

        Forums.fail_action(forum, actor, "forum.restore", error)

      {:restore, error} ->
        Docker.stop_container(container)
        Maintenance.mark(host)
        Forums.update_state(forum, %{status: "suspended"})
        Forums.fail_action(Forums.get_forum!(id), actor, "forum.restore", error)
    end
  end

  defp prepare(host, container, export) do
    with :ok <- Maintenance.mark(host),
         :ok <- Docker.stop_container(container) do
      Docker.copy_to(container, Export.path(export), "/data/backups")
    end
  end

  defp restore(forum, export, rotate?) do
    with {:ok, params} <- Forums.container_params(forum),
         :ok <- one_off(params, "restore", [@admin, "restore", export.file_name, "--yes"]),
         :ok <-
           if(rotate?,
             do: one_off(params, "keys", [@admin, "rotate-push-keys", "--yes"]),
             else: :ok
           ),
         :ok <- Docker.start_container(ForumContainer.name(forum.subdomain)),
         :ok <- Health.wait(forum.subdomain, Application.get_env(:idejo_hub, :health_wait, [])) do
      Maintenance.unmark(Forums.host(forum))
    end
  end

  # The output is not kept: only the exit code matters.
  defp one_off(params, suffix, cmd) do
    result = ForumContainer.run_one_off(params, suffix, cmd)
    ForumContainer.remove_one_off(params.slug, suffix)

    case result do
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{exit_code: code}} -> {:error, {:command_exit, Enum.at(cmd, 1), code}}
      error -> error
    end
  end
end
