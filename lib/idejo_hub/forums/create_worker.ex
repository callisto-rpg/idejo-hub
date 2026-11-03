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
     an email with a link to choose a password, or, when the forum cannot send email yet,
     the link is printed to the job; it is never stored or logged (FL-02 delivers it).

  Then the forum is `running`. If any step fails, everything this job made is removed
  (container, volumes, database, role; never something that was there before), the forum becomes `failed` with a short error, and
  the audit entry says which step failed. One attempt only: the operator decides what next.

  Reaching the forum from outside (HN-02) is not a per-forum step: Caddy routes every
  subdomain to its container by name, and its `ask` endpoint reads the forums table.
  """

  use Oban.Worker, queue: :lifecycle, max_attempts: 1

  require Logger

  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Hosting.{Docker, ForumContainer, Health, Postgres}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor}}) do
    case Forums.get_forum!(id) do
      %Forum{status: "creating"} = forum -> create(forum, actor)
      # Already handled (a duplicate job): nothing to do.
      _other -> :ok
    end
  end

  defp create(forum, actor) do
    steps = [
      {"database", &database/1},
      {"container", &container/1},
      {"starting", fn f -> Docker.start_container(ForumContainer.name(f.subdomain)) end},
      {"health", fn f -> Health.wait(f.subdomain, health_options()) end},
      {"setup", &setup/1}
    ]

    case run(steps, forum) do
      {:ok, forum} ->
        {:ok, forum} = Forums.update_state(forum, %{status: "running", step: nil, error: nil})
        {:ok, _} = Audit.record(actor, "forum.create", "ok", forum)
        :ok

      {:error, step, reason, forum} ->
        clean_up(forum, step)
        error = describe(reason)

        {:ok, forum} =
          Forums.update_state(forum, %{status: "failed", step: nil, error: "#{step}: #{error}"})

        {:ok, _} =
          Audit.record(actor, "forum.create", "failed", forum, %{"step" => step, "error" => error})

        Logger.warning("FL-01: creating forum #{forum.subdomain} failed at #{step}: #{error}")
        {:error, "#{step}: #{error}"}
    end
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
    with {:ok, secret_key_base} <- Forums.secret(forum, :secret_key_base),
         {:ok, db_password} <- Forums.secret(forum, :db_password) do
      creds = %{
        database: Postgres.name(forum.subdomain),
        username: Postgres.name(forum.subdomain),
        password: db_password
      }

      ForumContainer.provision(%{
        slug: forum.subdomain,
        version: forum.idejo_version,
        memory_mb: forum.memory_mb,
        cpus: forum.cpus,
        env: %{
          "PHX_HOST" => Forums.host(forum),
          "DATABASE_URL" => Postgres.database_url(creds, db_host()),
          "SECRET_KEY_BASE" => secret_key_base,
          "IDEJO_SOURCE_URL" => Forums.source_url(forum)
        }
      })
    end
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
      {:ok, %{exit_code: 0}} -> :ok
      {:ok, %{exit_code: code}} -> {:error, {:exit, code}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Removes only what this job made: a step that fails cleans up after itself (provision/1 of
  # each module), so a database that already existed is never dropped here.
  defp clean_up(_forum, "database"), do: :ok

  defp clean_up(forum, step) do
    if step != "container" do
      with {:error, reason} <- ForumContainer.remove(forum.subdomain, volumes: true) do
        Logger.error(
          "FL-01: could not remove #{forum.subdomain}'s container: #{describe(reason)}"
        )
      end
    end

    with {:error, reason} <- Postgres.drop(forum.subdomain) do
      Logger.error("FL-01: could not drop #{forum.subdomain}'s database: #{describe(reason)}")
    end
  end

  # Short, secret-free descriptions for the forum row and the audit log.
  defp describe(:timeout), do: "no healthy answer in time"
  defp describe(:not_found), do: "not found"
  defp describe({:image_unavailable, image}), do: "image #{image} could not be pulled"
  defp describe(:invalid), do: "a stored secret could not be decrypted"
  defp describe({:exit, code}), do: "idejo-admin setup exited with #{code}"
  defp describe({:denied, message}), do: "refused by docker-guard (#{message})"
  defp describe({:status, status, message}), do: "Docker answered #{status} (#{message})"
  defp describe({:unreachable, _detail}), do: "Docker is unreachable"
  defp describe({:postgres, message}), do: "PostgreSQL: #{message}"
  defp describe(other), do: inspect(other)

  defp db_host, do: Application.fetch_env!(:idejo_hub, Forums)[:db_host]
  defp health_options, do: Application.get_env(:idejo_hub, :health_wait, [])
end
