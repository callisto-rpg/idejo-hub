# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.CreateWorker do
  @moduledoc """
  FL-01: creates a forum recorded as `creating`, step by step, each step named in
  `forums.step` while it runs:

  1. `database`: its database and role (HN-05); the password is stored encrypted (SC-04).
  2. `container`: its volumes and container from the exact Idejo version (HN-04, SC-05).
  3. `starting`: starts it; the image's command runs Idejo's migrations, then the server.
  4. `health`: waits for `GET /health` to answer 200 (Idejo AD-15).
  5. `setup`: `bin/idejo-admin setup --name … --owner-email …` (Idejo AD-14). The owner gets
     an email with a link to choose a password (FL-02, `owner_invite: "emailed"`), or, when
     the forum cannot send email, the job keeps that link encrypted for the operator
     (`owner_invite: "operator"`, `Forums.take_owner_link/2`). The output is never logged.

  Then the forum is `running`. If any step fails, everything this job made is removed
  (container, volumes, database, role; never something that was there before), the forum becomes `failed` with a short error, and
  the audit entry says which step failed. One attempt only: the operator decides what next.

  Reaching the forum from outside (HN-02) is not a per-forum step: Caddy routes every
  subdomain to its container by name, and its `ask` endpoint reads the forums table.
  """

  use Oban.Worker, queue: :lifecycle, max_attempts: 1

  require Logger

  alias IdejoHub.{Audit, Forums, Repo}
  alias IdejoHub.Forums.{Errors, Export, Forum}
  alias IdejoHub.Hosting.{Docker, ForumContainer, Health, Maintenance, Postgres}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor} = args}) do
    case Forums.get_forum!(id) do
      %Forum{status: "creating"} = forum -> create(forum, actor, args["restore"])
      # Already handled (a duplicate job): nothing to do.
      _other -> :ok
    end
  end

  # OP-03, restore to a new subdomain: the forum stays behind the maintenance page, skips
  # headless setup (the archive brings its own owner and settings), then is restored.
  defp create(forum, actor, restore) do
    if restore, do: Maintenance.mark(Forums.host(forum))

    steps = [
      {"database", &database/1},
      # ID-01: the forum's client at the identity provider, before its container (its env).
      {"identity", &Forums.ensure_identity_client/1},
      {"container", &container/1},
      {"starting", fn f -> Docker.start_container(ForumContainer.name(f.subdomain)) end},
      {"health", fn f -> Health.wait(f.subdomain, health_options()) end},
      {"setup", &setup/1}
    ]

    steps = if restore, do: List.keydelete(steps, "setup", 0), else: steps

    case run(steps, forum) do
      {:ok, forum} ->
        {:ok, forum} = Forums.update_state(forum, %{status: "running", step: nil, error: nil})

        {:ok, _} =
          Audit.record(actor, "forum.create", "ok", forum, %{"owner_invite" => forum.owner_invite})

        then_restore(forum, actor, restore)

      {:error, step, reason, forum} ->
        clean_up(forum, step)
        if restore, do: Maintenance.unmark(Forums.host(forum))
        error = Errors.describe(reason)

        {:ok, forum} =
          Forums.update_state(forum, %{status: "failed", step: nil, error: "#{step}: #{error}"})

        {:ok, _} =
          Audit.record(actor, "forum.create", "failed", forum, %{"step" => step, "error" => error})

        Logger.warning("FL-01: creating forum #{forum.subdomain} failed at #{step}: #{error}")
        {:error, "#{step}: #{error}"}
    end
  end

  defp then_restore(_forum, _actor, nil), do: :ok

  defp then_restore(forum, actor, %{"export_id" => export_id} = restore) do
    {:ok, _} =
      Forums.restore_forum(forum, Repo.get!(Export, export_id), actor,
        new_forum: true,
        rotate_push_keys: restore["rotate_push_keys"] == true
      )

    :ok
  end

  defp run([], forum), do: {:ok, forum}

  defp run([{name, fun} | rest], forum) do
    {:ok, forum} = Forums.update_state(forum, %{step: name})

    case fun.(forum) do
      :ok -> run(rest, forum)
      {:ok, %Forum{} = forum} -> run(rest, forum)
      {:ok, _other} -> run(rest, forum)
      {:error, reason} -> {:error, name, reason, forum}
    end
  end

  defp database(forum) do
    with {:ok, creds} <- Postgres.provision(forum.subdomain) do
      encrypted =
        IdejoHub.Secrets.encrypt(creds.password, Forums.context(forum.subdomain, :db_password))

      Forums.update_state(forum, %{db_password_enc: encrypted})
    end
  end

  defp container(forum) do
    with {:ok, params} <- Forums.container_params(forum), do: ForumContainer.provision(params)
  end

  # The output may hold the owner's set-password link: never logged or stored.
  defp setup(forum) do
    cmd = [
      "/app/bin/idejo-admin",
      "setup",
      "--name",
      forum.display_name,
      "--owner-email",
      forum.owner_email
    ]

    case Docker.exec(ForumContainer.name(forum.subdomain), cmd) do
      {:ok, %{exit_code: 0, output: output}} -> owner_invite(forum, output)
      {:ok, %{exit_code: code}} -> {:error, {:exit, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  # FL-02. Setup prints the owner's link only when the forum could not email it; then the
  # Hub keeps it, encrypted, for the operator (Forums.take_owner_link/2). The link is matched
  # on the forum's own address only, and nothing else of the output is kept.
  defp owner_invite(forum, output) do
    link = ~r{https://#{Regex.escape(Forums.host(forum))}/users/reset-password/[A-Za-z0-9_\-]+}

    case Regex.run(link, output) do
      [url] ->
        Forums.update_state(forum, %{
          owner_invite: "operator",
          owner_link_enc:
            IdejoHub.Secrets.encrypt(url, Forums.context(forum.subdomain, :owner_link))
        })

      nil ->
        Forums.update_state(forum, %{owner_invite: "emailed"})
    end
  end

  # Removes only what this job made: a step that fails cleans up after itself (provision/1 of
  # each module), so a database that already existed is never dropped here.
  defp clean_up(_forum, "database"), do: :ok

  defp clean_up(forum, step) do
    # ID-01: a client made by this job goes too.
    if step not in ["database", "identity"],
      do: Forums.remove_identity_client(Forums.get_forum!(forum.id))

    if step != "container" do
      with {:error, reason} <- ForumContainer.remove(forum.subdomain, volumes: true) do
        Logger.error(
          "FL-01: could not remove #{forum.subdomain}'s container: #{Errors.describe(reason)}"
        )
      end
    end

    with {:error, reason} <- Postgres.drop(forum.subdomain) do
      Logger.error(
        "FL-01: could not drop #{forum.subdomain}'s database: #{Errors.describe(reason)}"
      )
    end
  end

  defp health_options, do: Application.get_env(:idejo_hub, :health_wait, [])
end
