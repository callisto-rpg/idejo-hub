# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.ResumeWorker do
  @moduledoc """
  FL-04, resume: starts the suspended forum's container, waits for `/health`, and only then
  removes the maintenance mark, so visitors never see an error in between. If it does not
  become healthy, the container is stopped again and the forum stays `suspended`.
  """
  use Oban.Worker, queue: :lifecycle, max_attempts: 1

  alias IdejoHub.Forums
  alias IdejoHub.Hosting.{Docker, ForumContainer, Health, Maintenance}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor}}) do
    forum = Forums.get_forum!(id)
    container = ForumContainer.name(forum.subdomain)

    with :ok <- Docker.start_container(container),
         :ok <- Health.wait(forum.subdomain, Application.get_env(:idejo_hub, :health_wait, [])),
         :ok <- Maintenance.unmark(Forums.host(forum)) do
      Forums.finish_action(forum, actor, "forum.resume", %{status: "running"})
    else
      error ->
        Docker.stop_container(container)
        Forums.fail_action(forum, actor, "forum.resume", error)
    end
  end
end
