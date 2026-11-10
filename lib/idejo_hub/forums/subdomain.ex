# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.Subdomain do
  @moduledoc """
  FL-03: a forum's subdomain is 3–32 lowercase letters, digits and hyphens, and not reserved.

  It is also the forum's slug: the container, volumes and database are named after it
  (HN-04, HN-05). So, beyond FL-03's wording:

  - it starts and ends with a letter or digit (a valid DNS label, and what docker-guard
    accepts);
  - it has no `--`, so it can never look like an internationalised (`xn--`) label.

  The reserved list holds names the Hub, mail or common services may need on the same domain.
  On top of it, when the Hub's own host or the members' sign-in host is one label under the
  forum domain (`hub.example.com` and `login.example.com` with forums on `example.com`),
  that label is refused too (`own_labels/0`), whatever the list says: such a forum would
  claim the Hub's address.
  """

  import Ecto.Changeset

  @format ~r/\A[a-z0-9](?:[a-z0-9-]{1,30})[a-z0-9]\z/

  @reserved ~w(
    hub www admin administrator mail api status
    identity auth login logout signin signup sso oauth oidc account accounts
    smtp imap pop pop3 ns1 ns2 dns ftp sftp ssh vpn
    autoconfig autodiscover postmaster hostmaster webmaster abuse security
    help support docs blog news about static assets cdn media files uploads
    app apps dashboard console panel billing
    dev test staging demo localhost root
    forum forums idejo my
  )

  @doc "The reserved names."
  @spec reserved() :: [String.t()]
  def reserved, do: @reserved

  @doc "Checks a subdomain. The reason is a short message for the operator."
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(name) when is_binary(name) do
    cond do
      String.length(name) < 3 or String.length(name) > 32 ->
        {:error, "must be 3 to 32 characters"}

      not Regex.match?(@format, name) ->
        {:error,
         "use lowercase letters, digits and hyphens, starting and ending with a letter or digit"}

      String.contains?(name, "--") ->
        {:error, "must not contain two hyphens in a row"}

      name in @reserved ->
        {:error, "is reserved"}

      name in own_labels() ->
        {:error, "is the address of the Hub or its sign-in"}

      true ->
        :ok
    end
  end

  def validate(_name), do: {:error, "must be text"}

  @doc """
  The labels of the Hub's own hosts (its address, `PHX_HOST`, and the sign-in address,
  `IDEJO_ID_DOMAIN`) that sit one label under the forum domain.
  """
  @spec own_labels() :: [String.t()]
  def own_labels do
    hosts = [
      Application.fetch_env!(:idejo_hub, IdejoHubWeb.Endpoint)[:url][:host],
      Application.get_env(:idejo_hub, IdejoHub.Identity, [])[:domain]
    ]

    labels_under(hosts, Application.fetch_env!(:idejo_hub, IdejoHub.Forums)[:domain])
  end

  @doc "The labels of `hosts` that are exactly one label under `domain`."
  @spec labels_under([String.t() | nil], String.t()) :: [String.t()]
  def labels_under(hosts, domain) do
    suffix = "." <> String.downcase(domain)

    for host when is_binary(host) <- hosts,
        host = String.downcase(host),
        String.ends_with?(host, suffix),
        label = String.replace_suffix(host, suffix, ""),
        label != "" and not String.contains?(label, "."),
        do: label
  end

  @doc "Adds FL-03's rules to a changeset field."
  @spec validate_subdomain(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_subdomain(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case validate(value) do
        :ok -> []
        {:error, message} -> [{field, message}]
      end
    end)
  end
end
