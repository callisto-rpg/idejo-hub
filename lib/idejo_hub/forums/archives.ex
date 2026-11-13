# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.Archives do
  @moduledoc """
  idejo backups the Hub keeps (`forum_exports` rows, files under the exports volume):
  exports (FL-06, kind `export`), final exports (FL-05, `final`), scheduled backups
  (OP-01, `backup`, the newest 14 kept per forum) and imported standalone backups (FL-07,
  `import`, from `Forums.Import`).

  Each comes from `idejo-admin backup` (idejo AD-09) run in the forum's container or a
  one-off one: only a file named `/data/backups/idejo-YYYYMMDD-HHMMSS.tar` in its output is
  copied out (`Docker.copy_from/3` checks the archive) and recorded with size and SHA-256.
  """

  import Ecto.Query

  alias IdejoHub.Forums.Export
  alias IdejoHub.Hosting.Docker
  alias IdejoHub.Repo

  @backup ~r"Backup written to (/data/backups/idejo-\d{8}-\d{6}\.tar)"

  @doc """
  After `idejo-admin backup` ran in `container` (`%{exit_code:, output:}`), copies the
  backup it wrote into the Hub's store and records it as `kind`.
  """
  @spec collect(map(), Docker.id(), map(), String.t()) :: {:ok, Export.t()} | {:error, term()}
  def collect(forum, container, run, kind) do
    with :ok <- succeeded(run),
         {:ok, path} <- backup_path(run.output),
         {:ok, file} <-
           Docker.copy_from(container, path, Path.join(Export.dir(), forum.subdomain)) do
      record(forum, kind, file)
    end
  end

  @doc """
  Keeps a forum's newest `keep` archives of `kind`; deletes the older ones (file and row).
  Returns the file names deleted.
  """
  @spec prune(map(), String.t(), non_neg_integer()) :: [String.t()]
  def prune(forum, kind, keep) do
    old =
      Repo.all(
        from e in Export,
          where: e.forum_id == ^forum.id and e.kind == ^kind,
          order_by: [desc: e.inserted_at, desc: e.id],
          offset: ^keep
      )

    for export <- old do
      delete_file(export)
      Repo.delete!(export)
      export.file_name
    end
  end

  defp succeeded(%{exit_code: 0}), do: :ok
  defp succeeded(%{exit_code: code}), do: {:error, {:backup_exit, code}}

  defp backup_path(output) do
    case Regex.run(@backup, output) do
      [_, path] -> {:ok, path}
      nil -> {:error, :backup_file_not_named}
    end
  end

  # Export.path/1: the exports directory, a validated subdomain and a recorded file name.
  # sobelow_skip ["Traversal.FileModule"]
  defp delete_file(export), do: File.rm(Export.path(export))

  @doc """
  Records `file`, already in `forum`'s directory of the Hub's store, as an archive of `kind`
  (size and SHA-256 read from the file).
  """
  # `file` is copy_from/3's result, or Import.store/2's: the exports directory, a validated
  # subdomain, and a backup's name.
  # sobelow_skip ["Traversal.FileModule"]
  @spec record(map(), String.t(), String.t()) :: {:ok, Export.t()} | {:error, Ecto.Changeset.t()}
  def record(forum, kind, file) do
    %{
      forum_id: forum.id,
      subdomain: forum.subdomain,
      kind: kind,
      file_name: Path.basename(file),
      size: File.stat!(file).size,
      sha256: sha256(file)
    }
    |> Export.changeset()
    |> Repo.insert()
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp sha256(file) do
    file
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
