# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.RecreateWorker do
  @moduledoc """
  HA-05 / HN-07: remakes a forum's container from the current settings (its environment
  is fixed when a container is made: a new shared SMTP server, for one), on the same Idejo
  version, keeping its volumes and database (`ForumContainer.recreate/1`).

  A running forum shows the maintenance page meanwhile, is started again and must answer
  `/health`; a suspended one stays stopped. If the running forum does not come back, it
  stays stopped behind the maintenance page as `suspended`, with the error.
  """
  use Oban.Worker, queue: :lifecycle, max_attempts: 1

  alias IdejoHub.Forums
  alias IdejoHub.Hosting.{Docker, ForumContainer, Health, Maintenance}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor, "was" => was} = args}) do
    forum = Forums.get_forum!(id)
    host = Forums.host(forum)
    running? = was == "running"

    with :ok <- if(running?, do: Maintenance.mark(host), else: :ok),
         # ID-01: a forum made before the identity provider joins it here; a rotation asked
         # for gets its new secret before the container is made.
         {:ok, forum} <- identity(forum, args["rotate_secret"] == true),
         {:ok, params} <- Forums.container_params(forum),
         {:ok, _id} <- ForumContainer.recreate(params),
         :ok <- if(running?, do: start(forum), else: :ok) do
      if running?, do: Maintenance.unmark(host)
      Forums.finish_action(forum, actor, "forum.recreate", %{})
    else
      error ->
        Docker.stop_container(ForumContainer.name(forum.subdomain))
        Maintenance.mark(host)
        {:ok, forum} = Forums.update_state(forum, %{status: "suspended"})
        Forums.fail_action(forum, actor, "forum.recreate", error)
    end
  end

  defp identity(forum, true), do: Forums.rotate_identity_secret(forum)
  defp identity(forum, false), do: Forums.ensure_identity_client(forum)

  defp start(forum) do
    with :ok <- Docker.start_container(ForumContainer.name(forum.subdomain)) do
      Health.wait(forum.subdomain, Application.get_env(:idejo_hub, :health_wait, []))
    end
  end
end
