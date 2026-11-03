# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.ExportWorker do
  @moduledoc """
  FL-06: exports a forum as a standard Idejo backup.

  A one-off container (`idejo-forum-<slug>-export`: the forum's image, environment and
  volumes) runs `idejo-admin backup` (Idejo AD-05, AD-09), which works whether the forum
  is running or suspended. The Hub reads the file name from its output (only
  `/data/backups/idejo-YYYYMMDD-HHMMSS.tar`), copies that file into its exports volume,
  records its size and SHA-256, and removes the one-off container. The file is Idejo's own
  backup format, so `idejo-admin restore` takes it on a standalone install.
  """
  use Oban.Worker, queue: :operations, max_attempts: 1

  alias IdejoHub.{Forums, Repo}
  alias IdejoHub.Forums.Export
  alias IdejoHub.Hosting.{Docker, ForumContainer}

  @backup ~r"Backup written to (/data/backups/idejo-\d{8}-\d{6}\.tar)"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"forum_id" => id, "actor" => actor} = args}) do
    forum = Forums.get_forum!(id)
    kind = Map.get(args, "kind", "export")

    case export(forum, kind) do
      {:ok, export} ->
        Forums.finish_action(forum, actor, "forum.export", %{}, %{
          "kind" => kind,
          "file" => export.file_name,
          "size" => export.size,
          "sha256" => export.sha256
        })

      error ->
        Forums.fail_action(forum, actor, "forum.export", error)
    end
  end

  @doc false
  # Also used by FL-05's deletion, inside its own job.
  def export(forum, kind) do
    dest = Path.join(Export.dir(), forum.subdomain)

    with {:ok, params} <- Forums.container_params(forum),
         {:ok, run} <-
           ForumContainer.run_one_off(params, "export", ["/app/bin/idejo-admin", "backup"]) do
      try do
        with :ok <- succeeded(run),
             {:ok, path} <- backup_path(run.output),
             {:ok, file} <- Docker.copy_from(run.id, path, dest) do
          record(forum, kind, file)
        end
      after
        ForumContainer.remove_one_off(forum.subdomain, "export")
      end
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

  # `file` is copy_from/3's result: the exports directory, a validated subdomain, and a name
  # matched by @backup.
  # sobelow_skip ["Traversal.FileModule"]
  defp record(forum, kind, file) do
    %{
      forum_id: forum.id,
      subdomain: forum.subdomain,
      kind: kind,
      file_name: Path.basename(file),
      size: File.stat!(file).size,
      sha256:
        file
        |> File.stream!(65_536)
        |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)
    }
    |> Export.changeset()
    |> Repo.insert()
  end
end
