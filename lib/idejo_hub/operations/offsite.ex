# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.Offsite do
  @moduledoc """
  OP-02: off-server copies of backups on S3-compatible storage, encrypted before upload.

  Steward decision 2026-11-04: each file is encrypted with `age` to the operator's public key
  (`IDEJO_HUB_BACKUP_AGE_RECIPIENT`); the private key stays off the server, so the Hub cannot
  read its own off-site copies. Storage comes from `deploy/.env` (`IDEJO_HUB_S3_*`), so it
  is known even when the Hub's database is lost. Requests are signed with AWS Signature V4
  (Req's `aws_sigv4`), path-style (`<endpoint>/<bucket>/<key>`), which S3 and the
  S3-compatible services accept. Files above one part (16 MiB) go up as a multipart upload,
  read a part at a time.

  Keys: `<prefix>forums/<subdomain>/<file>.age` for forum backups (OP-01) and
  `<prefix>hub/<file>.age` for the Hub's own (OP-10). `prune/2` keeps the newest copies
  under a key prefix; file names carry their time, so the newest sort last.
  """

  @part 16 * 1024 * 1024

  @doc "Whether off-server copies are on (a bucket is set)."
  @spec configured?() :: boolean()
  def configured?, do: config()[:bucket] not in [nil, ""]

  @doc "What the Settings page shows: endpoint, bucket, prefix and public key, or nil."
  @spec summary() :: map() | nil
  def summary do
    if configured?(),
      do: Map.new(Keyword.take(config(), [:endpoint, :bucket, :prefix, :recipient]))
  end

  @doc "The key of a forum backup's copy."
  @spec forum_key(String.t(), String.t()) :: String.t()
  def forum_key(subdomain, file_name), do: "#{prefix()}forums/#{subdomain}/#{file_name}.age"

  @doc "The key of a Hub backup's copy."
  @spec hub_key(String.t()) :: String.t()
  def hub_key(file_name), do: "#{prefix()}hub/#{file_name}.age"

  @doc """
  Encrypts `file` with age and uploads it as `key`. The encrypted file is written next to
  `file` and removed afterwards; nothing unencrypted leaves the server.
  """
  @spec copy(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  # `file` is a path in the Hub's own store (Export.path/1, HubBackup.path/1).
  # sobelow_skip ["Traversal.FileModule"]
  def copy(file, key) do
    encrypted = file <> ".age.part"

    try do
      with :ok <- encrypt(file, encrypted) do
        size = File.stat!(encrypted).size
        with :ok <- upload(encrypted, key, size), do: {:ok, size}
      end
    after
      File.rm(encrypted)
    end
  end

  @doc "Keeps the newest `keep` copies whose keys start with `key_prefix`; deletes the rest."
  @spec prune(String.t(), non_neg_integer()) :: {:ok, [String.t()]} | {:error, term()}
  def prune(key_prefix, keep) do
    with {:ok, keys} <- list(key_prefix) do
      old =
        keys |> Enum.filter(&String.ends_with?(&1, ".age")) |> Enum.sort(:desc) |> Enum.drop(keep)

      delete_all(old, [])
    end
  end

  defp delete_all([], deleted), do: {:ok, Enum.reverse(deleted)}

  defp delete_all([key | rest], deleted) do
    with :ok <- delete(key), do: delete_all(rest, [key | deleted])
  end

  # The recipient is checked at boot (config/runtime.exs); the executable comes from config,
  # the paths from the Hub's own store; no shell.
  # sobelow_skip ["CI.System"]
  defp encrypt(file, out) do
    args = ["--encrypt", "--recipient", config()[:recipient], "--output", out, file]

    case System.cmd(config()[:age], args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, code} -> {:error, {:age_exit, code}}
    end
  rescue
    e in ErlangError -> {:error, {:age_missing, e.original}}
  end

  defp upload(file, key, size) do
    if size <= part(), do: put(file, key), else: multipart(file, key, size)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp put(file, key) do
    with {:ok, _} <- request(:put, key, body: File.read!(file)), do: :ok
  end

  defp multipart(file, key, size) do
    with {:ok, resp} <- request(:post, key, params: [uploads: ""]),
         {:ok, id} <- xml_value(resp.body, "UploadId") do
      file |> upload_parts(key, id, size) |> finish(key, id)
    end
  end

  defp finish({:ok, etags}, key, id) do
    with {:ok, _} <- request(:post, key, params: [uploadId: id], body: complete(etags)), do: :ok
  end

  # A part failed: abort, so the storage keeps no unfinished upload.
  defp finish(error, key, id) do
    request(:delete, key, params: [uploadId: id])
    error
  end

  # One part in memory at a time.
  # sobelow_skip ["Traversal.FileModule"]
  defp upload_parts(file, key, id, size) do
    {:ok, fd} = :file.open(file, [:read, :binary, :raw])

    try do
      part = part()

      1..div(size + part - 1, part)
      |> Enum.reduce_while({:ok, []}, fn n, {:ok, etags} ->
        {:ok, chunk} = :file.pread(fd, (n - 1) * part, part)

        case request(:put, key, params: [partNumber: n, uploadId: id], body: chunk) do
          {:ok, resp} -> {:cont, {:ok, etags ++ [{n, etag(resp)}]}}
          error -> {:halt, error}
        end
      end)
    after
      :file.close(fd)
    end
  end

  defp complete(etags) do
    parts =
      for {n, etag} <- etags,
          do: "<Part><PartNumber>#{n}</PartNumber><ETag>#{etag}</ETag></Part>"

    "<CompleteMultipartUpload>#{parts}</CompleteMultipartUpload>"
  end

  defp etag(resp), do: resp |> Req.Response.get_header("etag") |> List.first("")

  defp list(key_prefix) do
    with {:ok, resp} <- request(:get, nil, params: ["list-type": 2, prefix: key_prefix]) do
      {:ok, for([_, key] <- Regex.scan(~r"<Key>([^<]+)</Key>", resp.body), do: key)}
    end
  end

  defp delete(key) do
    with {:ok, _} <- request(:delete, key), do: :ok
  end

  defp request(method, key, opts \\ []) do
    url = if key, do: "/#{config()[:bucket]}/#{key}", else: "/#{config()[:bucket]}"

    [
      method: method,
      base_url: config()[:endpoint],
      url: url,
      retry: false,
      decode_body: false,
      aws_sigv4: [
        access_key_id: config()[:access_key_id],
        secret_access_key: config()[:secret_access_key],
        region: config()[:region] || "us-east-1",
        service: :s3
      ]
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(Application.get_env(:idejo_hub, :offsite_req_options, []))
    |> Req.request()
    |> case do
      {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, resp}
      {:ok, %{status: status}} -> {:error, {:s3_status, status}}
      {:error, exception} -> {:error, {:s3_unreachable, Exception.message(exception)}}
    end
  end

  defp xml_value(body, tag) do
    case Regex.run(~r"<#{tag}>([^<]+)</#{tag}>", body) do
      [_, value] -> {:ok, value}
      nil -> {:error, {:s3_answer, tag}}
    end
  end

  # S3 parts are at least 5 MiB; tests set a smaller size.
  defp part, do: config()[:part_size] || @part
  defp prefix, do: config()[:prefix] || ""
  defp config, do: Application.get_env(:idejo_hub, __MODULE__, [])
end
