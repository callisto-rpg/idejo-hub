# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.ForumContainer do
  @moduledoc """
  HN-04: each forum runs as its own container from the official Idejo image, with its own
  environment, upload volume and memory limit (and a CPU limit, SC-05).

  Names are fixed so docker-guard can check them: the container is `idejo-forum-<slug>`, its
  volumes `idejo-forum-<slug>-uploads` and `idejo-forum-<slug>-backups`, and all of them carry
  the `org.idejo.hub.forum=<slug>` label. The environment is Idejo's contract (Idejo AD-13);
  the caller supplies the per-forum values (`PHX_HOST`, `DATABASE_URL`, `SECRET_KEY_BASE`,
  `IDEJO_SOURCE_URL`, SMTP) and they are never logged.

  `provision/1` creates the volumes and the container without starting it, and removes
  whatever it created if a step fails. Migrations and headless setup belong to FL-01.
  """

  alias IdejoHub.Hosting.Docker

  @label "org.idejo.hub.forum"
  @uploads_dir "/data/uploads"
  @backups_dir "/data/backups"

  @type params :: %{
          required(:slug) => String.t(),
          required(:version) => String.t(),
          required(:env) => %{optional(String.t()) => String.t()},
          required(:memory_mb) => pos_integer(),
          required(:cpus) => number()
        }

  @doc "The container's name for a forum."
  @spec name(String.t()) :: String.t()
  def name(slug), do: "idejo-forum-" <> slug

  @doc "The forum's volumes, by role."
  @spec volumes(String.t()) :: %{uploads: String.t(), backups: String.t()}
  def volumes(slug), do: %{uploads: name(slug) <> "-uploads", backups: name(slug) <> "-backups"}

  @doc "The image reference for an Idejo version, for example `0.1.0`."
  @spec image(String.t()) :: String.t()
  def image(version), do: Docker.config(:forum_image) <> ":" <> version

  @doc """
  The Docker create body for a forum. Fixed variables (port, upload and backup directories)
  win over the caller's, so a forum always writes into its own volumes.
  """
  @spec spec(params()) :: map()
  def spec(%{slug: slug, version: version, env: env, memory_mb: memory_mb, cpus: cpus}) do
    network = Docker.config(:forum_network)
    volumes = volumes(slug)

    fixed = %{
      "PHX_SERVER" => "true",
      "PORT" => "4000",
      "IDEJO_UPLOADS_DIR" => @uploads_dir,
      "IDEJO_BACKUP_DIR" => @backups_dir
    }

    %{
      "Image" => image(version),
      "Env" => env |> Map.merge(fixed) |> Enum.sort() |> Enum.map(fn {k, v} -> "#{k}=#{v}" end),
      "Cmd" => ["sh", "-c", "/app/bin/migrate && /app/bin/server"],
      "Labels" => %{@label => slug},
      "HostConfig" => %{
        "Memory" => memory_mb * 1024 * 1024,
        "NanoCpus" => round(cpus * 1_000_000_000),
        "NetworkMode" => network,
        "RestartPolicy" => %{"Name" => "unless-stopped"},
        "Mounts" => [
          %{"Type" => "volume", "Source" => volumes.uploads, "Target" => @uploads_dir},
          %{"Type" => "volume", "Source" => volumes.backups, "Target" => @backups_dir}
        ]
      },
      # Caddy and the Hub reach the forum by its slug on the forum network.
      "NetworkingConfig" => %{"EndpointsConfig" => %{network => %{"Aliases" => [name(slug)]}}}
    }
  end

  @doc """
  A one-off container on the forum's volumes, with its environment and limits, running one
  `idejo-admin` command (FL-06 export; later restore): `idejo-forum-<slug>-<suffix>`, never
  restarted, no network alias.
  """
  @spec one_off_spec(params(), [String.t()]) :: map()
  def one_off_spec(params, ["/app/bin/idejo-admin" | _] = cmd) do
    params
    |> spec()
    |> Map.put("Cmd", cmd)
    |> put_in(["HostConfig", "RestartPolicy"], %{"Name" => "no"})
    |> Map.put("NetworkingConfig", %{
      "EndpointsConfig" => %{Docker.config(:forum_network) => %{}}
    })
  end

  @doc """
  Runs a one-off container to its end: creates it (removing a leftover of the same name),
  starts it and waits. Returns its exit code and output; the caller copies what it needs and
  then calls `remove_one_off/2`.
  """
  @spec run_one_off(params(), String.t(), [String.t()]) ::
          {:ok, %{id: Docker.id(), exit_code: integer(), output: binary()}} | {:error, term()}
  def run_one_off(%{slug: slug} = params, suffix, cmd) do
    name = name(slug) <> "-" <> suffix
    remove_one_off(slug, suffix)

    with {:ok, id} <- Docker.create_container(name, one_off_spec(params, cmd)),
         :ok <- Docker.start_container(id),
         {:ok, exit_code} <- Docker.wait_container(id),
         {:ok, output} <- Docker.logs(id) do
      {:ok, %{id: id, exit_code: exit_code, output: output}}
    else
      error ->
        remove_one_off(slug, suffix)
        error
    end
  end

  @doc "Removes a one-off container (already gone is fine)."
  @spec remove_one_off(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_one_off(slug, suffix) do
    case Docker.remove_container(name(slug) <> "-" <> suffix) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  @doc """
  Pulls the image, creates the forum's volumes and its container (not started). On failure,
  removes what this call created and returns the first error.
  """
  @spec provision(params()) :: {:ok, Docker.id()} | {:error, Docker.error()}
  def provision(%{slug: slug, version: version} = params) do
    labels = %{@label => slug}

    steps = [
      {fn -> pull(image(version)) end, fn -> :ok end},
      {fn -> Docker.create_volume(volumes(slug).uploads, labels) end,
       fn -> Docker.remove_volume(volumes(slug).uploads) end},
      {fn -> Docker.create_volume(volumes(slug).backups, labels) end,
       fn -> Docker.remove_volume(volumes(slug).backups) end},
      {fn -> Docker.create_container(name(slug), spec(params)) end,
       fn -> Docker.remove_container(name(slug)) end}
    ]

    run(steps, [])
  end

  @doc """
  OP-04: replaces the forum's container with one made from `params` (another image version),
  keeping its volumes: stops and removes the old container, creates the new one (not
  started). The volumes are never touched here, whatever fails.
  """
  @spec recreate(params()) :: {:ok, Docker.id()} | {:error, Docker.error()}
  def recreate(%{slug: slug} = params) do
    with :ok <- ok_if_missing(Docker.stop_container(name(slug))),
         :ok <- ok_if_missing(Docker.remove_container(name(slug))) do
      Docker.create_container(name(slug), spec(params))
    end
  end

  @doc "Pulls the image of an Idejo version (a missing version says so)."
  @spec pull_version(String.t()) :: :ok | {:error, term()}
  def pull_version(version), do: pull(image(version))

  defp ok_if_missing({:error, :not_found}), do: :ok
  defp ok_if_missing(result), do: result

  @doc """
  Removes the forum's container and, with `volumes: true`, its volumes (uploads and local
  backups are gone then). Missing pieces are not an error, so a half-created forum can be
  removed too.
  """
  @spec remove(String.t(), keyword()) :: :ok | {:error, Docker.error()}
  def remove(slug, opts \\ []) do
    names = if Keyword.get(opts, :volumes, false), do: Map.values(volumes(slug)), else: []

    volume_steps = Enum.map(names, fn volume -> fn -> Docker.remove_volume(volume) end end)

    [fn -> Docker.remove_container(name(slug)) end | volume_steps]
    |> Enum.reduce_while(:ok, fn step, :ok ->
      case step.() do
        result when result == :ok or result == {:error, :not_found} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # A version that does not exist (or cannot be fetched) says so.
  defp pull(image) do
    case Docker.pull_image(image) do
      :ok -> :ok
      {:error, :not_found} -> {:error, {:image_unavailable, image}}
      {:error, {:status, _status, _message}} -> {:error, {:image_unavailable, image}}
      error -> error
    end
  end

  defp run([], [{{:ok, id}, _undo} | _done]), do: {:ok, id}

  defp run([{step, undo} | rest], done) do
    case step.() do
      :ok ->
        run(rest, [{:ok, undo} | done])

      {:ok, _id} = ok ->
        run(rest, [{ok, undo} | done])

      {:error, _reason} = error ->
        Enum.each(done, fn {_result, undo} -> undo.() end)
        error
    end
  end
end
