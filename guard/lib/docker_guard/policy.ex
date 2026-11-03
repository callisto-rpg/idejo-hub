# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule DockerGuard.Policy do
  @moduledoc """
  The rules that decide which Docker Engine API calls reach the socket proxy (HN-04, steward
  decision 2026-11-03, `docs/proposals/hn-04-docker-access.md`).

  The socket proxy in front of the Docker socket only filters by method and path. This module
  also reads request bodies, which is where privileged containers, host mounts and host
  namespaces are requested. Everything is denied unless a rule below allows it, and request
  bodies are matched against allowlists of keys, so a field Docker adds later is refused
  until someone reviews it.

  `check/2` is pure apart from the `lookup` callbacks, which ask Docker (through the proxy)
  for an existing container's labels or an exec instance's container.
  """

  @forum_label "org.idejo.hub.forum"
  @name_prefix "idejo-forum-"

  # A forum's slug (Hub FL-03): lowercase letters, digits and hyphens, 3–32 characters.
  @slug ~r/\A[a-z0-9][a-z0-9-]{1,30}[a-z0-9]\z/
  @version_tag ~r/\A\d+\.\d+\.\d+\z/
  @digest ~r/\Asha256:[a-f0-9]{64}\z/

  @admin_commands ["/app/bin/idejo-admin", "bin/idejo-admin"]
  @server_commands [
    ["/app/bin/server"],
    ["sh", "-c", "/app/bin/migrate && /app/bin/server"]
  ]

  @create_keys ~w(Image Env Cmd Labels HostConfig NetworkingConfig ExposedPorts Healthcheck
                  StopTimeout Hostname)
  @host_config_keys ~w(Binds Mounts Memory MemorySwap NanoCpus PidsLimit RestartPolicy
                       NetworkMode Init ReadonlyRootfs Tmpfs AutoRemove)
  @mount_keys ~w(Type Source Target ReadOnly)
  @restart_policies ["", "no", "unless-stopped", "on-failure"]
  @exec_keys ~w(Cmd Env AttachStdout AttachStderr Tty Privileged)
  @volume_keys ~w(Name Labels Driver DriverOpts)
  @pull_params ~w(fromImage tag platform)

  @type config :: %{image: String.t(), network: String.t()}
  @type request :: %{
          method: String.t(),
          path: [String.t()],
          query: %{optional(String.t()) => String.t()},
          body: map() | nil
        }
  @type lookup :: %{
          container_labels: (String.t() -> {:ok, map()} | :error),
          exec_container: (String.t() -> {:ok, String.t()} | :error)
        }
  @type result :: :ok | {:ok, %{query: map()}} | {:deny, atom()}

  @doc "The label every forum container and volume carries; its value is the forum's slug."
  def forum_label, do: @forum_label

  @doc "Whether a request body has to be read and decoded before `check/3`."
  @spec needs_body?(String.t(), [String.t()]) :: boolean()
  def needs_body?("POST", ["containers", "create"]), do: true
  def needs_body?("POST", ["containers", _id, "exec"]), do: true
  def needs_body?("POST", ["volumes", "create"]), do: true
  def needs_body?(_method, _path), do: false

  @doc """
  Decides one request. The path has the API version prefix removed (`["containers", "create"]`).
  Returns `:ok`, `{:ok, %{query: query}}` when the query must be replaced before forwarding,
  or `{:deny, rule}`.
  """
  @spec check(request(), config(), lookup()) :: result()
  def check(%{method: method, path: path} = req, config, lookup) do
    route(method, path, req, config, lookup)
  end

  # Probes.
  defp route(m, ["_ping"], _req, _c, _l) when m in ["GET", "HEAD"], do: :ok
  defp route("GET", ["version"], _req, _c, _l), do: :ok

  # Listing shows forum containers only, whatever the caller asked for.
  defp route("GET", ["containers", "json"], %{query: query}, _c, _l) do
    filters = Jason.encode!(%{"label" => [@forum_label]})
    {:ok, %{query: query |> Map.take(["all"]) |> Map.put("filters", filters)}}
  end

  defp route("POST", ["containers", "create"], req, config, _l),
    do: check_create(req.query, req.body, config)

  defp route("POST", ["containers", id, "exec"], req, _c, lookup) do
    with :ok <- forum_container(id, lookup), do: check_exec(req.body)
  end

  defp route(method, ["containers", id, action], _req, _c, lookup)
       when {method, action} in [
              {"GET", "json"},
              {"GET", "logs"},
              {"GET", "archive"},
              {"HEAD", "archive"},
              {"PUT", "archive"},
              {"POST", "start"},
              {"POST", "stop"},
              {"POST", "restart"},
              {"POST", "wait"}
            ],
       do: forum_container(id, lookup)

  defp route("DELETE", ["containers", id], _req, _c, lookup), do: forum_container(id, lookup)

  defp route(method, ["exec", id, action], _req, _c, lookup)
       when {method, action} in [{"POST", "start"}, {"GET", "json"}] do
    case lookup.exec_container.(id) do
      {:ok, container} -> forum_container(container, lookup)
      :error -> {:deny, :unknown_exec}
    end
  end

  defp route("POST", ["volumes", "create"], %{body: body}, _c, _l), do: check_volume(body)

  defp route(method, ["volumes", name], _req, _c, _l) when method in ["GET", "DELETE"] do
    if String.starts_with?(name, @name_prefix), do: :ok, else: {:deny, :volume_not_forum}
  end

  defp route("POST", ["images", "create"], %{query: query}, config, _l),
    do: check_pull(query, config)

  defp route("GET", ["images" | rest], _req, _c, _l) when rest != [] do
    if List.last(rest) == "json", do: :ok, else: {:deny, :not_allowed}
  end

  defp route(_method, _path, _req, _c, _l), do: {:deny, :not_allowed}

  ## Existing containers

  defp forum_container(id, lookup) do
    case lookup.container_labels.(id) do
      {:ok, %{@forum_label => slug}} when is_binary(slug) and slug != "" -> :ok
      {:ok, _labels} -> {:deny, :container_not_forum}
      :error -> {:deny, :unknown_container}
    end
  end

  ## Container creation

  defp check_create(_query, body, _config) when not is_map(body), do: {:deny, :body_required}

  defp check_create(query, body, config) do
    with {:ok, slug} <- forum_slug(body["Labels"]),
         :ok <- container_name(query["name"], slug),
         :ok <- only_keys(body, @create_keys, :create_key),
         :ok <- only_keys(query, ["name", "platform"], :create_param),
         :ok <- image(body["Image"], config),
         :ok <- command(body["Cmd"]),
         :ok <- strings(body["Env"], :env),
         :ok <- host_config(body["HostConfig"], slug, config) do
      networking_config(body["NetworkingConfig"], config)
    end
  end

  defp forum_slug(%{@forum_label => slug}) when is_binary(slug) do
    if Regex.match?(@slug, slug), do: {:ok, slug}, else: {:deny, :forum_label}
  end

  defp forum_slug(_labels), do: {:deny, :forum_label}

  # `idejo-forum-<slug>` for the forum itself, `idejo-forum-<slug>-<suffix>` for a one-off
  # container such as a restore.
  defp container_name(name, slug) when is_binary(name) do
    base = @name_prefix <> slug

    if name == base or Regex.match?(~r/\A#{Regex.escape(base)}-[a-z0-9]{1,16}\z/, name),
      do: :ok,
      else: {:deny, :container_name}
  end

  defp container_name(_name, _slug), do: {:deny, :container_name}

  defp image(image, %{image: repo}) when is_binary(image) do
    case String.split(image, "@", parts: 2) do
      [^repo, digest] -> if Regex.match?(@digest, digest), do: :ok, else: {:deny, :image}
      [repo_and_tag] -> tagged_image(repo_and_tag, repo)
      _other -> {:deny, :image}
    end
  end

  defp image(_image, _config), do: {:deny, :image}

  defp tagged_image(repo_and_tag, repo) do
    with [^repo, tag] <- String.split(repo_and_tag, ":", parts: 2),
         true <- Regex.match?(@version_tag, tag) do
      :ok
    else
      _other -> {:deny, :image}
    end
  end

  # The image's own command, the server (with or without migrations first) or idejo-admin.
  defp command(nil), do: :ok
  defp command([]), do: :ok
  defp command(cmd) when cmd in @server_commands, do: :ok
  defp command([exe | args]) when exe in @admin_commands, do: strings(args, :command)
  defp command(_cmd), do: {:deny, :command}

  defp host_config(hc, slug, config) when is_map(hc) do
    with :ok <- only_keys(hc, @host_config_keys, :host_config_key),
         :ok <- positive(hc["Memory"], :memory_limit),
         :ok <- positive(hc["NanoCpus"], :cpu_limit),
         :ok <- network_mode(hc["NetworkMode"], config),
         :ok <- restart_policy(hc["RestartPolicy"]),
         :ok <- each(hc["Binds"], &bind(&1, slug)),
         :ok <- each(hc["Mounts"], &mount(&1, slug)) do
      tmpfs(hc["Tmpfs"])
    end
  end

  defp host_config(_hc, _slug, _config), do: {:deny, :host_config}

  defp positive(n, _rule) when is_integer(n) and n > 0, do: :ok
  defp positive(_n, rule), do: {:deny, rule}

  defp network_mode(mode, %{network: mode}), do: :ok
  defp network_mode(_mode, _config), do: {:deny, :network}

  defp restart_policy(nil), do: :ok

  defp restart_policy(%{"Name" => name} = policy) when name in @restart_policies do
    only_keys(policy, ["Name", "MaximumRetryCount"], :restart_policy)
  end

  defp restart_policy(_policy), do: {:deny, :restart_policy}

  # Named volumes of this forum only, never a host path: `idejo-forum-<slug>-<x>:/path[:ro]`.
  defp bind(bind, slug) when is_binary(bind) do
    case String.split(bind, ":") do
      [source, "/" <> _target] -> forum_volume(source, slug)
      [source, "/" <> _target, mode] when mode in ["ro", "rw"] -> forum_volume(source, slug)
      _other -> {:deny, :bind}
    end
  end

  defp bind(_bind, _slug), do: {:deny, :bind}

  defp mount(%{"Type" => "volume", "Source" => source, "Target" => "/" <> _} = m, slug) do
    with :ok <- only_keys(m, @mount_keys, :mount), do: forum_volume(source, slug)
  end

  defp mount(_mount, _slug), do: {:deny, :mount}

  defp forum_volume(source, slug) when is_binary(source) do
    if Regex.match?(~r/\A#{Regex.escape(@name_prefix <> slug)}-[a-z0-9]{1,16}\z/, source),
      do: :ok,
      else: {:deny, :volume_not_forum}
  end

  defp forum_volume(_source, _slug), do: {:deny, :volume_not_forum}

  defp tmpfs(nil), do: :ok

  defp tmpfs(map) when is_map(map) do
    if Enum.all?(map, fn {k, v} -> match?("/" <> _, k) and is_binary(v) end),
      do: :ok,
      else: {:deny, :tmpfs}
  end

  defp tmpfs(_tmpfs), do: {:deny, :tmpfs}

  defp networking_config(nil, _config), do: :ok

  defp networking_config(%{"EndpointsConfig" => endpoints} = nc, %{network: network})
       when is_map(endpoints) do
    with :ok <- only_keys(nc, ["EndpointsConfig"], :networking_config),
         :ok <- only_keys(endpoints, [network], :network) do
      each(Map.values(endpoints), &endpoint/1)
    end
  end

  defp networking_config(_nc, _config), do: {:deny, :networking_config}

  defp endpoint(nil), do: :ok

  defp endpoint(settings) when is_map(settings) do
    with :ok <- only_keys(settings, ["Aliases"], :endpoint),
         do: strings(settings["Aliases"], :endpoint)
  end

  defp endpoint(_settings), do: {:deny, :endpoint}

  ## Exec

  defp check_exec(body) when is_map(body) do
    with :ok <- only_keys(body, @exec_keys, :exec_key),
         :ok <- not_true(body["Privileged"], :privileged_exec),
         :ok <- strings(body["Env"], :env) do
      case body["Cmd"] do
        [exe | args] when exe in @admin_commands -> strings(args, :exec_command)
        _other -> {:deny, :exec_command}
      end
    end
  end

  defp check_exec(_body), do: {:deny, :body_required}

  ## Volumes and images

  defp check_volume(body) when is_map(body) do
    with :ok <- only_keys(body, @volume_keys, :volume_key),
         {:ok, slug} <- forum_slug(body["Labels"]),
         :ok <- forum_volume(body["Name"], slug),
         :ok <- if(body["Driver"] in [nil, "", "local"], do: :ok, else: {:deny, :volume_driver}) do
      # Driver options of the local driver can bind any host path (type=none,o=bind).
      if body["DriverOpts"] in [nil, %{}], do: :ok, else: {:deny, :volume_driver_opts}
    end
  end

  defp check_volume(_body), do: {:deny, :body_required}

  defp check_pull(query, config) do
    with :ok <- only_keys(query, @pull_params, :pull_param),
         do: pulled_image(query["fromImage"], query["tag"], config)
  end

  # `fromImage=repo&tag=X.Y.Z` (or a digest), or `fromImage=repo:X.Y.Z` with no tag.
  defp pulled_image(repo, tag, %{image: repo}) when is_binary(tag) do
    if Regex.match?(@version_tag, tag) or Regex.match?(@digest, tag),
      do: :ok,
      else: {:deny, :image}
  end

  defp pulled_image(from, nil, config) when is_binary(from), do: image(from, config)
  defp pulled_image(_from, _tag, _config), do: {:deny, :image}

  ## Helpers

  defp only_keys(map, allowed, rule) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)), do: :ok, else: {:deny, rule}
  end

  defp not_true(true, rule), do: {:deny, rule}
  defp not_true(_value, _rule), do: :ok

  defp strings(nil, _rule), do: :ok

  defp strings(list, rule) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: :ok, else: {:deny, rule}
  end

  defp strings(_value, rule), do: {:deny, rule}

  defp each(nil, _fun), do: :ok
  defp each([], _fun), do: :ok

  defp each([item | rest], fun) do
    with :ok <- fun.(item), do: each(rest, fun)
  end

  defp each(_value, _fun), do: {:deny, :malformed}
end
