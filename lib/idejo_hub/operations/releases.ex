# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.Releases do
  @moduledoc """
  OP-09: notice of new Idejo releases, with a link to the changelog.

  Once a day (`ReleaseCheckWorker`) the Hub reads Idejo's published tags (`url`, by default
  GitHub's tag list of the Idejo repository: no credentials, nothing about this Hub sent) and
  keeps the newest stable version (`vX.Y.Z`, no pre-release). When it is newer than the
  version new forums start on (`IDEJO_DEFAULT_VERSION`), the operator's forum list and
  server page show it, linking to `changelog` with `{from}` and `{to}` filled in. Idejo
  publishes no release notes yet: by default the link is GitHub's comparison of the two
  tags, which lists every change merged between them.

  An empty `IDEJO_HUB_RELEASES_URL` turns the check off; a failed check keeps what was known.
  """

  alias IdejoHub.Repo
  alias IdejoHub.Settings.Setting

  @key "idejo_latest_release"

  @doc "Reads the published versions and keeps the newest. `{:ok, version}` or `{:error, reason}`."
  @spec check() :: {:ok, String.t()} | {:error, term()}
  def check do
    case config(:url) do
      blank when blank in [nil, ""] ->
        {:error, :off}

      url ->
        with {:ok, %{status: 200, body: tags}} when is_list(tags) <- fetch(url),
             [_ | _] = versions <- versions(tags) do
          newest = versions |> Enum.max(Version) |> to_string()
          store(newest)
          {:ok, newest}
        else
          [] -> {:error, :no_versions}
          {:ok, %{status: status}} -> {:error, {:status, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The newest version found and when it was checked, or nil."
  @spec latest() :: %{version: String.t(), checked_at: String.t()} | nil
  def latest do
    case Repo.get(Setting, @key) do
      nil ->
        nil

      %{value: value} ->
        value |> Jason.decode!() |> then(&%{version: &1["version"], checked_at: &1["checked_at"]})
    end
  end

  @doc """
  What the operator sees: the newer release and its changelog link, or nil when the newest
  known release is not newer than the version new forums start on.
  """
  @spec notice() :: %{version: String.t(), current: String.t(), changelog: String.t()} | nil
  def notice do
    current = Application.fetch_env!(:idejo_hub, IdejoHub.Forums)[:default_version]

    with %{version: version} <- latest(),
         :gt <- Version.compare(version, current) do
      changelog =
        config(:changelog)
        |> String.replace("{from}", current)
        |> String.replace("{to}", version)

      %{version: version, current: current, changelog: changelog}
    else
      _ -> nil
    end
  end

  defp fetch(url) do
    Req.new(
      url: url,
      receive_timeout: 10_000,
      retry: false,
      headers: [{"accept", "application/json"}]
    )
    |> Req.merge(Application.get_env(:idejo_hub, :releases_req_options, []))
    |> Req.get()
  end

  # `vX.Y.Z` tag names only; pre-releases left out.
  defp versions(tags) do
    for %{"name" => "v" <> name} <- tags,
        {:ok, version} <- [Version.parse(name)],
        version.pre == [],
        do: version
  end

  defp store(version) do
    value = Jason.encode!(%{version: version, checked_at: DateTime.utc_now(:second)})

    Repo.insert!(%Setting{key: @key, value: value},
      on_conflict: [set: [value: value, updated_at: DateTime.utc_now(:second)]],
      conflict_target: :key
    )
  end

  defp config(key), do: Application.get_env(:idejo_hub, __MODULE__, [])[key]
end
