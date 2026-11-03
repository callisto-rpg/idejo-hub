# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums do
  @moduledoc """
  Forums and their lifecycle (FL). Each action records the request and queues an Oban job
  (queue `lifecycle`) that does the work and records how it ended.

  FL-01, create: `create_forum/2` checks the request, stores the forum with a fresh,
  encrypted `SECRET_KEY_BASE` (SC-04) as `creating`, and queues `Forums.CreateWorker`.
  """

  import Ecto.Query

  alias IdejoHub.{Audit, Repo, Secrets}
  alias IdejoHub.Hosting.Postgres
  alias IdejoHub.Operations.{BackupWorker, RestoreWorker, UpgradeWorker}

  alias IdejoHub.Forums.{
    CreateWorker,
    DeleteWorker,
    Errors,
    Export,
    ExportWorker,
    Forum,
    Mail,
    RecreateWorker,
    ResumeWorker,
    Subdomain,
    SuspendWorker
  }

  @doc "Defaults for a new forum's form: the configured Idejo version and limits."
  @spec defaults() :: map()
  def defaults do
    config = Application.fetch_env!(:idejo_hub, __MODULE__)

    %{
      idejo_version: config[:default_version],
      memory_mb: config[:default_memory_mb],
      cpus: config[:default_cpus]
    }
  end

  @doc "A changeset for the create form."
  @spec change_new_forum(map()) :: Ecto.Changeset.t()
  def change_new_forum(attrs \\ %{}) do
    Forum.create_changeset(struct(Forum, defaults()), attrs)
  end

  @doc """
  FL-01: records a new forum and queues its creation. `actor` names who asked (the operator;
  operator accounts come with SC-08). Returns the forum as `creating`.
  """
  @spec create_forum(map(), String.t(), keyword()) ::
          {:ok, Forum.t()} | {:error, Ecto.Changeset.t()}
  def create_forum(attrs, actor, opts \\ []) do
    changeset = change_new_forum(attrs)
    secret_key_base = Keyword.get_lazy(opts, :secret_key_base, &Secrets.new_secret_key_base/0)
    job_args = Keyword.get(opts, :job_args, %{})

    changeset =
      case Ecto.Changeset.fetch_field(changeset, :subdomain) do
        {_source, subdomain} when is_binary(subdomain) ->
          changeset
          |> Ecto.Changeset.put_change(
            :secret_key_base_enc,
            Secrets.encrypt(secret_key_base, context(subdomain, :secret_key_base))
          )
          |> put_default_mail_from(subdomain)

        _missing ->
          changeset
      end

    Repo.transaction(fn ->
      with {:ok, forum} <- Repo.insert(changeset),
           {:ok, _entry} <-
             forum
             |> audit_request(actor)
             |> Repo.insert(),
           {:ok, _job} <-
             Oban.insert(
               CreateWorker.new(Map.merge(%{"forum_id" => forum.id, "actor" => actor}, job_args))
             ) do
        forum
      else
        {:error, %Ecto.Changeset{data: %Forum{}} = changeset} -> Repo.rollback(changeset)
        {:error, other} -> raise "FL-01: could not record the request: #{inspect(other)}"
      end
    end)
    |> tap(fn
      {:ok, forum} -> broadcast(forum)
      _error -> :ok
    end)
  end

  # HN-07: the forum's own sender address, unless the operator gave one.
  defp put_default_mail_from(changeset, subdomain) do
    if Ecto.Changeset.get_field(changeset, :mail_from),
      do: changeset,
      else:
        Ecto.Changeset.put_change(
          changeset,
          :mail_from,
          Mail.default_from(host(%Forum{subdomain: subdomain}))
        )
  end

  defp audit_request(forum, actor) do
    Audit.changeset(actor, "forum.create", "requested", forum, %{
      "display_name" => forum.display_name,
      "owner_email" => forum.owner_email,
      "idejo_version" => forum.idejo_version
    })
  end

  @doc """
  FL-02: when the forum could not email its owner the link to choose a password, the Hub
  keeps it (encrypted) for the operator to pass on. This hands it over once: it is removed
  from the Hub, and the audit log records who took it.
  """
  @spec take_owner_link(Forum.t(), String.t()) :: {:ok, String.t()} | {:error, :none}
  def take_owner_link(%Forum{owner_link_enc: nil}, _actor), do: {:error, :none}

  def take_owner_link(%Forum{} = forum, actor) do
    with {:ok, link} <-
           Secrets.decrypt(forum.owner_link_enc, context(forum.subdomain, :owner_link)),
         {:ok, forum} <- update_state(forum, %{owner_link_enc: nil}),
         {:ok, _entry} <- Audit.record(actor, "forum.owner_link.take", "ok", forum) do
      {:ok, link}
    else
      _error -> {:error, :none}
    end
  end

  @doc """
  FL-04: suspends a running forum. Caddy shows a maintenance page while its container is
  stopped; database, volumes and backups are kept. Queues `SuspendWorker`.
  """
  @spec suspend_forum(Forum.t(), String.t()) :: {:ok, Forum.t()} | {:error, :invalid_state}
  def suspend_forum(%Forum{} = forum, actor),
    do: start_action(forum, actor, "running", "suspending", "forum.suspend", SuspendWorker)

  @doc """
  FL-06: exports a running or suspended forum as a standard Idejo backup, kept by the Hub.
  Queues `ExportWorker` (queue `operations`).
  """
  @spec export_forum(Forum.t(), String.t()) :: {:ok, Forum.t()} | {:error, :invalid_state}
  def export_forum(%Forum{} = forum, actor),
    do:
      start_action(
        forum,
        actor,
        ["running", "suspended"],
        "exporting",
        "forum.export",
        ExportWorker
      )

  @doc """
  OP-01: queues a backup of a running forum (`Operations.BackupWorker`), taking its action
  slot (`step: "backing_up"`). The schedule calls it daily for every running forum.
  """
  @spec backup_forum(Forum.t(), String.t()) :: {:ok, Forum.t()} | {:error, :invalid_state}
  def backup_forum(%Forum{} = forum, actor),
    do: start_action(forum, actor, "running", "backing_up", "forum.backup", BackupWorker)

  @doc """
  OP-03: restores a running or suspended forum from one of its own kept archives (scheduled
  backup, export or final export). Queues `Operations.RestoreWorker`.
  """
  @spec restore_forum(Forum.t(), Export.t(), String.t(), keyword()) ::
          {:ok, Forum.t()} | {:error, :invalid_state | :not_its_archive}
  def restore_forum(%Forum{} = forum, %Export{} = export, actor, opts \\ []) do
    if export.forum_id != forum.id and not Keyword.get(opts, :new_forum, false) do
      {:error, :not_its_archive}
    else
      start_action(
        forum,
        actor,
        ["running", "suspended"],
        "restoring",
        "forum.restore",
        RestoreWorker,
        %{
          "export_id" => export.id,
          "was" => forum.status,
          "rotate_push_keys" => Keyword.get(opts, :rotate_push_keys, false)
        }
      )
    end
  end

  @doc """
  OP-03: restores an archive to a new subdomain. The new forum is created (FL-01) without
  headless setup, behind the maintenance page, then restored from the archive.

  Its display name, owner email and Idejo version default to the source forum's. Idejo
  encrypts its secret settings with `SECRET_KEY_BASE`: when the source forum is deleted, its
  key moves with its data (no forum shares it); when it is still alive, the new forum gets
  its own key (SC-04) and new push keys, and an SMTP password set in the forum's own
  Admin → Email must be entered again.
  """
  @spec restore_to_new(Export.t(), map(), String.t()) ::
          {:ok, Forum.t()} | {:error, Ecto.Changeset.t() | :invalid}
  def restore_to_new(%Export{} = export, attrs, actor) do
    source = get_forum!(export.forum_id)

    attrs =
      Map.merge(
        %{
          "display_name" => source.display_name,
          "owner_email" => source.owner_email,
          "idejo_version" => source.idejo_version,
          "memory_mb" => source.memory_mb,
          "cpus" => source.cpus
        },
        attrs
      )

    move_key? = source.status == "deleted"

    with {:ok, key} <-
           if(move_key?,
             do: secret(source, :secret_key_base),
             else: {:ok, Secrets.new_secret_key_base()}
           ) do
      create_forum(attrs, actor,
        secret_key_base: key,
        job_args: %{"restore" => %{"export_id" => export.id, "rotate_push_keys" => not move_key?}}
      )
    end
  end

  @doc """
  OP-04: upgrades a running forum to a newer exact Idejo version, rolling back to its
  current version and a pre-upgrade backup if the new one is not healthy in time. Queues
  `Operations.UpgradeWorker`.
  """
  @spec upgrade_forum(Forum.t(), String.t(), String.t(), keyword()) ::
          {:ok, Forum.t()} | {:error, :invalid_state | :invalid_version | :not_newer}
  def upgrade_forum(%Forum{} = forum, version, actor, opts \\ []) do
    with {:ok, to} <- Version.parse(version),
         :gt <- Version.compare(to, Version.parse!(forum.idejo_version)) do
      args = %{"version" => version}
      args = if bulk = opts[:bulk], do: Map.put(args, "bulk", bulk), else: args
      start_action(forum, actor, "running", "upgrading", "forum.upgrade", UpgradeWorker, args)
    else
      :error -> {:error, :invalid_version}
      _not_greater -> {:error, :not_newer}
    end
  end

  @doc """
  HA-05 / HN-07: remakes a running or suspended forum's container from the current settings
  (same version, volumes and database kept). Queues `RecreateWorker`.
  """
  @spec recreate_forum(Forum.t(), String.t()) :: {:ok, Forum.t()} | {:error, :invalid_state}
  def recreate_forum(%Forum{} = forum, actor) do
    start_action(
      forum,
      actor,
      ["running", "suspended"],
      "recreating",
      "forum.recreate",
      RecreateWorker,
      %{
        "was" => forum.status
      }
    )
  end

  @doc """
  HA-05: applies the current settings to every running or suspended forum not busy with
  another action (`recreate_forum/2` each). Returns those queued and those skipped (busy).
  """
  @spec recreate_all(String.t()) :: %{queued: [String.t()], busy: [String.t()]}
  def recreate_all(actor) do
    results =
      for forum <- list_forums(), forum.status in ["running", "suspended"] do
        {forum.subdomain, recreate_forum(forum, actor)}
      end

    %{
      queued: for({s, {:ok, _}} <- results, do: s),
      busy: for({s, {:error, _}} <- results, do: s)
    }
  end

  @doc """
  FL-06: a forum's `SECRET_KEY_BASE`, for the operator restoring its export on a standalone
  Idejo: Idejo encrypts its secret settings (push keys, a panel SMTP password) with it, so
  without it they are lost. Audited each time (`forum.secret_key_base.reveal`, SC-06); kept
  by the Hub (the forum still needs it), deleted forums included (their final export).
  """
  @spec reveal_secret_key_base(Forum.t(), String.t()) :: {:ok, String.t()} | {:error, :invalid}
  def reveal_secret_key_base(%Forum{} = forum, actor) do
    with {:ok, key} <- secret(forum, :secret_key_base) do
      {:ok, _} = Audit.record(actor, "forum.secret_key_base.reveal", "ok", forum)
      {:ok, key}
    end
  end

  @doc "A forum's exports, newest first."
  @spec list_exports(Forum.t()) :: [Export.t()]
  def list_exports(%Forum{id: id}) do
    Repo.all(
      from e in Export, where: e.forum_id == ^id, order_by: [desc: e.inserted_at, desc: e.id]
    )
  end

  @doc """
  FL-05: deletes a forum in two steps. `DeleteWorker` makes a final export first (nothing
  is deleted without it), then the forum shows the maintenance page and stops; it is purged
  after the grace period (30 days), or right away with `immediate: true`, which needs the
  operator to type the forum's subdomain as `confirm:`.
  """
  @spec delete_forum(Forum.t(), String.t(), keyword()) ::
          {:ok, Forum.t()} | {:error, :invalid_state | :confirmation_required}
  def delete_forum(%Forum{} = forum, actor, opts \\ []) do
    immediate? = Keyword.get(opts, :immediate, false)

    if immediate? and Keyword.get(opts, :confirm) != forum.subdomain do
      {:error, :confirmation_required}
    else
      start_action(
        forum,
        actor,
        ["running", "suspended", "failed"],
        "deleting",
        "forum.delete",
        DeleteWorker,
        %{"immediate" => immediate?}
      )
    end
  end

  @doc """
  FL-05: cancels a deletion during its grace period. The forum becomes `suspended` (still
  showing the maintenance page; resume it with `resume_forum/2`) and its purge is cancelled.
  """
  @spec cancel_deletion(Forum.t(), String.t()) :: {:ok, Forum.t()} | {:error, :invalid_state}
  def cancel_deletion(%Forum{} = forum, actor) do
    Repo.transaction(fn ->
      locked = Repo.one!(from f in Forum, where: f.id == ^forum.id, lock: "FOR UPDATE")
      if locked.status != "deleting" or locked.step != nil, do: Repo.rollback(:invalid_state)

      Oban.cancel_all_jobs(
        from j in Oban.Job,
          where: j.worker == "IdejoHub.Forums.PurgeWorker",
          where: fragment("?->>'forum_id' = ?", j.args, ^to_string(forum.id))
      )

      {:ok, forum} = update_state(locked, %{status: "suspended", purge_at: nil})
      {:ok, _} = Audit.record(actor, "forum.delete.cancel", "ok", forum)
      forum
    end)
  end

  @doc "FL-04: resumes a suspended forum. Queues `ResumeWorker`."
  @spec resume_forum(Forum.t(), String.t()) :: {:ok, Forum.t()} | {:error, :invalid_state}
  def resume_forum(%Forum{} = forum, actor),
    do: start_action(forum, actor, "suspended", "resuming", "forum.resume", ResumeWorker)

  # One action at a time per forum: the row is locked, and a forum whose `step` is set is
  # already being worked on.
  defp start_action(forum, actor, from_status, step, action, worker, extra_args \\ %{}) do
    Repo.transaction(fn ->
      locked = Repo.one!(from f in Forum, where: f.id == ^forum.id, lock: "FOR UPDATE")

      if locked.status not in List.wrap(from_status) or locked.step != nil,
        do: Repo.rollback(:invalid_state)

      {:ok, forum} = update_state(locked, %{step: step, error: nil})
      {:ok, _} = Audit.record(actor, action, "requested", forum)

      {:ok, _} =
        Oban.insert(
          worker.new(Map.merge(%{"forum_id" => forum.id, "actor" => actor}, extra_args))
        )

      forum
    end)
  end

  @doc false
  # Ends a lifecycle job that worked: the new state, step cleared, an `ok` audit entry.
  def finish_action(forum, actor, action, attrs, details \\ %{}) do
    {:ok, forum} = update_state(forum, Map.merge(%{step: nil, error: nil}, attrs))
    {:ok, _} = Audit.record(actor, action, "ok", forum, details)
    :ok
  end

  @doc false
  # Ends a lifecycle job that failed: state unchanged, step cleared, the error kept.
  def fail_action(forum, actor, action, error, opts \\ []) do
    message = Errors.describe(error)
    {:ok, forum} = update_state(forum, %{step: nil, error: message})
    details = Map.merge(%{"error" => message}, Keyword.get(opts, :details, %{}))
    {:ok, _} = Audit.record(actor, action, "failed", forum, details)
    {:error, message}
  end

  @doc "A forum by id."
  @spec get_forum!(integer()) :: Forum.t()
  def get_forum!(id), do: Repo.get!(Forum, id)

  @doc "A forum by subdomain (not deleted), or nil."
  @spec get_by_subdomain(String.t()) :: Forum.t() | nil
  # Deleted forums keep their row, and their subdomain may be used again (FL-05).
  def get_by_subdomain(subdomain) do
    Repo.one(from f in Forum, where: f.subdomain == ^subdomain and f.status != "deleted")
  end

  @doc "All forums but deleted ones, by subdomain."
  @spec list_forums() :: [Forum.t()]
  def list_forums do
    Repo.all(from f in Forum, where: f.status != "deleted", order_by: f.subdomain)
  end

  @doc "Moves a forum's lifecycle state (the Hub's own changes, from jobs)."
  @spec update_state(Forum.t(), map()) :: {:ok, Forum.t()} | {:error, Ecto.Changeset.t()}
  def update_state(forum, attrs) do
    with {:ok, forum} <- forum |> Forum.state_changeset(attrs) |> Repo.update() do
      broadcast(forum)
      {:ok, forum}
    end
  end

  @topic "forums"

  @doc "HA-01: operator screens follow forum changes (`{:forum_changed, forum}`)."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(IdejoHub.PubSub, @topic)

  defp broadcast(forum),
    do: Phoenix.PubSub.broadcast(IdejoHub.PubSub, @topic, {:forum_changed, forum})

  @doc """
  HA-01: every forum not deleted, with its latest scheduled backup (when, and its size: the
  forum's data and uploads, as far as the Hub may know without reading its database).
  """
  @spec list_overview() :: [%{forum: Forum.t(), last_backup: Export.t() | nil}]
  def list_overview do
    latest =
      from e in Export,
        where: e.kind in ["backup", "upgrade", "export", "final"],
        distinct: e.forum_id,
        order_by: [asc: e.forum_id, desc: e.inserted_at, desc: e.id]

    backups = latest |> Repo.all() |> Map.new(&{&1.forum_id, &1})
    for forum <- list_forums(), do: %{forum: forum, last_backup: backups[forum.id]}
  end

  @doc "The encryption context of one of a forum's secrets (SC-04)."
  @spec context(String.t(), atom()) :: String.t()
  def context(subdomain, field), do: "forum:#{subdomain}:#{field}"

  @doc "Decrypts one of a forum's secrets."
  @spec secret(Forum.t(), :secret_key_base | :db_password) ::
          {:ok, String.t()} | {:error, :invalid}
  def secret(%Forum{secret_key_base_enc: stored} = forum, :secret_key_base),
    do: decrypt(stored, forum, :secret_key_base)

  def secret(%Forum{db_password_enc: stored} = forum, :db_password),
    do: decrypt(stored, forum, :db_password)

  defp decrypt(nil, _forum, _field), do: {:error, :invalid}

  defp decrypt(stored, forum, field),
    do: Secrets.decrypt(stored, context(forum.subdomain, field))

  @doc """
  What the forum's container is made from (HN-04): its image version, limits and Idejo
  environment (AD-13), secrets decrypted (SC-04), email (HN-07). Used for the forum's own
  container and for one-off containers on its volumes (exports, FL-06).
  """
  @spec container_params(Forum.t()) :: {:ok, map()} | {:error, :invalid}
  def container_params(%Forum{} = forum) do
    with {:ok, secret_key_base} <- secret(forum, :secret_key_base),
         {:ok, db_password} <- secret(forum, :db_password) do
      name = Postgres.name(forum.subdomain)
      creds = %{database: name, username: name, password: db_password}
      db_host = Application.fetch_env!(:idejo_hub, __MODULE__)[:db_host]

      {:ok,
       %{
         slug: forum.subdomain,
         version: forum.idejo_version,
         memory_mb: forum.memory_mb,
         cpus: forum.cpus,
         env:
           %{
             "PHX_HOST" => host(forum),
             "DATABASE_URL" => Postgres.database_url(creds, db_host),
             "SECRET_KEY_BASE" => secret_key_base,
             "IDEJO_SOURCE_URL" => source_url(forum)
           }
           |> Map.merge(Mail.env(forum.mail_from))
       }}
    end
  end

  @doc "The forum's public host: `<subdomain>.<forum domain>`."
  @spec host(Forum.t()) :: String.t()
  def host(%Forum{subdomain: subdomain}) do
    subdomain <> "." <> Application.fetch_env!(:idejo_hub, __MODULE__)[:domain]
  end

  @doc """
  The forum a public host belongs to (`<subdomain>.<forum domain>`, one label), or nil
  (deleted forums have none).
  """
  @spec for_host(String.t()) :: Forum.t() | nil
  def for_host(host) when is_binary(host) do
    suffix = "." <> Application.fetch_env!(:idejo_hub, __MODULE__)[:domain]
    host = String.downcase(host)

    with true <- String.ends_with?(host, suffix),
         subdomain = String.replace_suffix(host, suffix, ""),
         :ok <- Subdomain.validate(subdomain) do
      get_by_subdomain(subdomain)
    else
      _not_a_forum_host -> nil
    end
  end

  @doc """
  HN-02: whether Caddy may get a certificate for `host`: the Hub's own host, or the host of
  an existing forum that is not deleted.
  """
  @spec certificate_allowed?(String.t()) :: boolean()
  def certificate_allowed?(host) when is_binary(host) do
    host = String.downcase(host)

    cond do
      host in hub_hosts() -> true
      forum = for_host(host) -> forum.status != "deleted"
      true -> false
    end
  end

  defp hub_hosts do
    # The host the Hub serves itself on (PHX_HOST), read from config, not the web layer.
    [Application.fetch_env!(:idejo_hub, IdejoHubWeb.Endpoint)[:url][:host]]
  end

  @doc "LB-03: the source of the exact Idejo release a forum runs (`IDEJO_SOURCE_URL`)."
  @spec source_url(Forum.t()) :: String.t()
  def source_url(%Forum{idejo_version: version}) do
    Application.fetch_env!(:idejo_hub, __MODULE__)[:source_url_base] <> version
  end
end
