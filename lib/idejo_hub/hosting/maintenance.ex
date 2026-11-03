# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.Maintenance do
  @moduledoc """
  FL-04: tells Caddy which forums are suspended. One empty file per suspended forum, named
  after its host, in a volume Caddy reads (`deploy/Caddyfile`, `@suspended`); Caddy then
  serves its static maintenance page, even while the Hub is down.

  The database is the truth: `sync/0` (at boot) makes the files match the forums whose
  status is `suspended`.
  """

  import Ecto.Query

  alias IdejoHub.Forums
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Repo

  # The path is dir() plus a host checked by path/1 (DNS labels only, never "/" or ".."),
  # and dir() comes from configuration.
  @doc "Marks a host as suspended."
  # sobelow_skip ["Traversal.FileModule"]
  @spec mark(String.t()) :: :ok | {:error, File.posix()}
  def mark(host) do
    with :ok <- File.mkdir_p(dir()), do: File.write(path(host), "")
  end

  @doc "Removes a host's mark (nothing to do when there is none)."
  # sobelow_skip ["Traversal.FileModule"]
  @spec unmark(String.t()) :: :ok | {:error, File.posix()}
  def unmark(host) do
    case File.rm(path(host)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  @doc "Whether a host is marked."
  @spec marked?(String.t()) :: boolean()
  def marked?(host), do: File.exists?(path(host))

  @doc "Makes the marks match the suspended forums: adds missing ones, removes stale ones."
  # sobelow_skip ["Traversal.FileModule"]
  @spec sync() :: :ok
  def sync do
    File.mkdir_p!(dir())

    wanted =
      from(f in Forum, where: f.status == "suspended")
      |> Repo.all()
      |> MapSet.new(&Forums.host/1)

    present = dir() |> File.ls!() |> MapSet.new()

    for host <- MapSet.difference(present, wanted), do: unmark(host)
    for host <- MapSet.difference(wanted, present), do: mark(host)
    :ok
  end

  # Hosts come from validated subdomains; this refuses anything else, so a mark's path never
  # leaves dir() ("/" and ".." cannot pass).
  @label "[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"
  @host ~r/\A#{@label}(?:\.#{@label})+\z/

  defp path(host) do
    if not Regex.match?(@host, host), do: raise(ArgumentError, "not a host name")
    Path.join(dir(), host)
  end

  defp dir, do: Application.fetch_env!(:idejo_hub, __MODULE__)[:dir]
end
