# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.HubBackup do
  @moduledoc """
  OP-10: backups of the Hub's own database (`hub`) and the identity provider's (`zitadel`),
  on the forums' schedule (`BackupScheduler`). Each is a `pg_dump --format=custom` of one
  database, connecting as that database's own role: the Hub's from its Repo, Zitadel's from
  `ZITADEL_DB_PASSWORD` (steward decision 2026-11-04; without it only `hub` is dumped). The
  files go to `<exports dir>/_hub/` (no subdomain has an underscore) with a `hub_backups`
  row (size, SHA-256); the newest `IDEJO_HUB_BACKUPS_KEPT` (14) of each kind are kept.

  A dump is useless without the keys in `deploy/.env` (`HUB_SECRETS_KEY` for the Hub's
  encrypted secrets, `ZITADEL_MASTERKEY` for Zitadel's): `docs/deploying.md` says to keep a
  copy of that file off the server.
  """

  import Ecto.Query

  require Logger

  alias IdejoHub.Audit.Entry
  alias IdejoHub.Forums.Export
  alias IdejoHub.Repo

  defmodule Backup do
    @moduledoc "One dump the Hub keeps (OP-10)."
    use Ecto.Schema
    import Ecto.Changeset

    @type t :: %__MODULE__{}

    schema "hub_backups" do
      field :kind, :string
      field :file_name, :string
      field :size, :integer
      field :sha256, :string
      # OP-02: the encrypted off-server copy, once uploaded.
      field :offsite_key, :string
      field :offsite_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    def changeset(attrs) do
      %__MODULE__{}
      |> cast(attrs, [:kind, :file_name, :size, :sha256])
      |> validate_required([:kind, :file_name, :size, :sha256])
      |> validate_inclusion(:kind, ~w(hub zitadel))
      |> unique_constraint(:file_name)
    end
  end

  @doc "Where the dumps are."
  @spec dir() :: String.t()
  def dir, do: Path.join(Export.dir(), "_hub")

  @doc "Where a dump's file is."
  @spec path(Backup.t()) :: String.t()
  def path(%Backup{file_name: name}), do: Path.join(dir(), name)

  @doc "The databases dumped: `hub` always, `zitadel` when its password is set."
  @spec databases() :: [{String.t(), keyword()}]
  def databases do
    zitadel = config()[:zitadel]

    hub = [
      {"hub", Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])}
    ]

    if zitadel[:password] in [nil, ""], do: hub, else: hub ++ [{"zitadel", zitadel}]
  end

  @doc """
  Dumps every database, then keeps the newest `keep` of each kind. Stops at the first
  failure: `{:error, kind, reason, done}` with the backups made before it.
  """
  # dir/0: the configured exports directory and a fixed name.
  # sobelow_skip ["Traversal.FileModule"]
  @spec run(non_neg_integer()) ::
          {:ok, [Backup.t()], [String.t()]} | {:error, String.t(), term(), [Backup.t()]}
  def run(keep) do
    File.mkdir_p!(dir())

    Enum.reduce_while(databases(), {:ok, [], []}, fn {kind, db}, {:ok, done, pruned} ->
      case dump(kind, db) do
        {:ok, backup} -> {:cont, {:ok, done ++ [backup], pruned ++ prune(kind, keep)}}
        {:error, reason} -> {:halt, {:error, kind, reason, done}}
      end
    end)
  end

  @doc "The newest dump of each kind, `%{\"hub\" => backup}`."
  @spec latest() :: %{String.t() => Backup.t()}
  def latest do
    Repo.all(
      from b in Backup,
        distinct: b.kind,
        order_by: [b.kind, desc: b.inserted_at, desc: b.id]
    )
    |> Map.new(&{&1.kind, &1})
  end

  @doc "The audit entry of the last finished Hub backup (`ok` or `failed`), or nil."
  @spec last_run() :: Entry.t() | nil
  def last_run do
    Repo.one(
      from e in Entry,
        where: e.action == "hub.backup" and e.outcome in ["ok", "failed"],
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 1
    )
  end

  @doc "Every dump kept, newest first."
  @spec list() :: [Backup.t()]
  def list, do: Repo.all(from b in Backup, order_by: [desc: b.inserted_at, desc: b.id])

  # Written as `.part`, renamed once pg_dump succeeded, so a failed dump leaves nothing.
  # The file name is made here from a fixed kind and the time; the executable comes from the
  # Hub's config and the arguments are fixed (no shell, no outside input).
  # sobelow_skip ["Traversal.FileModule", "CI.System"]
  defp dump(kind, db) do
    name = "#{kind}-#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")}.dump"
    file = Path.join(dir(), name)
    part = file <> ".part"

    args = ["--format=custom", "--file", part]

    case System.cmd(config()[:pg_dump], args, env: pg_env(db), stderr_to_stdout: true) do
      {_, 0} ->
        File.rename!(part, file)
        record(kind, name, file)

      {output, code} ->
        File.rm(part)
        # pg_dump's own message (the password is in the environment, never printed).
        Logger.warning(
          "OP-10: pg_dump of #{kind} failed (#{code}): #{String.slice(output, 0, 500)}"
        )

        {:error, {:pg_dump_exit, code}}
    end
  rescue
    e in ErlangError -> {:error, {:pg_dump_missing, e.original}}
  end

  defp pg_env(db) do
    [
      {"PGHOST", to_string(db[:hostname] || "localhost")},
      {"PGPORT", to_string(db[:port] || 5432)},
      {"PGUSER", to_string(db[:username])},
      {"PGPASSWORD", to_string(db[:password] || "")},
      {"PGDATABASE", to_string(db[:database])},
      {"PGCONNECT_TIMEOUT", "10"}
    ]
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp record(kind, name, file) do
    %{kind: kind, file_name: name, size: File.stat!(file).size, sha256: sha256(file)}
    |> Backup.changeset()
    |> Repo.insert()
  end

  defp prune(kind, keep) do
    old =
      Repo.all(
        from b in Backup,
          where: b.kind == ^kind,
          order_by: [desc: b.inserted_at, desc: b.id],
          offset: ^keep
      )

    for backup <- old do
      delete_file(backup)
      Repo.delete!(backup)
      backup.file_name
    end
  end

  # path/1: the dumps directory and a recorded name made by dump/2.
  # sobelow_skip ["Traversal.FileModule"]
  defp delete_file(backup), do: File.rm(path(backup))

  # sobelow_skip ["Traversal.FileModule"]
  defp sha256(file) do
    file
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp config, do: Application.fetch_env!(:idejo_hub, __MODULE__)
end
