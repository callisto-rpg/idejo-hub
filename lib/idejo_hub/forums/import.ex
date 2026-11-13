# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.Import do
  @moduledoc """
  FL-07: a standalone idejo backup brought to the Hub to become a new forum.

  `check/1` reads the archive the way idejo's own restore does (idejo AD-09,
  `Idejo.Backup`): a tar holding only `manifest.json`, `database.dump` and `uploads/<name>`,
  whose manifest is format 1 with the database's last migration. It never extracts
  anything but the manifest, and never reads the dump. Whether that migration is one the
  chosen idejo version knows is left to `idejo-admin restore` (it refuses a newer one).

  `store/2` copies the file into the new forum's archives as kind `import`, named
  `idejo-YYYYMMDD-HHMMSS.tar` (UTC, `-N` added when taken), the only names idejo restores.
  """

  alias IdejoHub.Forums.{Archives, Export}

  @format 1

  @doc "Whether `path` is a standalone idejo backup the Hub can import."
  @spec check(Path.t()) :: {:ok, %{migration: integer()}} | {:error, :not_a_backup}
  def check(path) do
    tar = String.to_charlist(path)

    with true <- File.regular?(path),
         {:ok, names} <- :erl_tar.table(tar),
         names = Enum.map(names, &to_string/1),
         true <- Enum.all?(names, &allowed_name?/1),
         true <- "manifest.json" in names and "database.dump" in names,
         {:ok, [{_name, json}]} <- :erl_tar.extract(tar, [:memory, files: [~c"manifest.json"]]),
         {:ok, %{"format" => @format, "migration" => migration}} when is_integer(migration) <-
           Jason.decode(json) do
      {:ok, %{migration: migration}}
    else
      _not_a_backup -> {:error, :not_a_backup}
    end
  end

  defp allowed_name?(name) when name in ["manifest.json", "database.dump"], do: true

  defp allowed_name?("uploads/" <> file),
    do: file != "" and not String.contains?(file, "/") and not String.starts_with?(file, ".")

  defp allowed_name?(_name), do: false

  @doc """
  Copies a checked backup into `forum`'s archives (`<exports dir>/<subdomain>/`) and records
  it as kind `import`, with size and SHA-256.
  """
  @spec store(map(), Path.t()) :: {:ok, Export.t()} | {:error, term()}
  # The exports directory, the forum's validated subdomain and a name made by free_name/1.
  # sobelow_skip ["Traversal.FileModule"]
  def store(forum, path) do
    dir = Path.join(Export.dir(), forum.subdomain)
    dest = Path.join(dir, free_name(dir))

    with :ok <- File.mkdir_p(dir),
         :ok <- copy(path, dest) do
      case Archives.record(forum, "import", dest) do
        {:ok, export} ->
          {:ok, export}

        error ->
          File.rm(dest)
          error
      end
    end
  end

  # A deleted forum's exports stay under the same subdomain: never overwrite one.
  # `dir` is the exports directory and a validated subdomain.
  # sobelow_skip ["Traversal.FileModule"]
  defp free_name(dir) do
    base = "idejo-" <> Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base <> ".tar"
      n -> "#{base}-#{n}.tar"
    end)
    |> Enum.find(&(not File.exists?(Path.join(dir, &1))))
  end

  # `path` is the operator's upload (LiveView's temporary file); `dest` is made above.
  # sobelow_skip ["Traversal.FileModule"]
  defp copy(path, dest) do
    case File.cp(path, dest) do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(dest)
        {:error, {:import_copy, reason}}
    end
  end
end
