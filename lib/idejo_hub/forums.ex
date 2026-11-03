# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums do
  @moduledoc """
  Forums and their lifecycle (FL). Each action records the request and queues an Oban job
  (queue `lifecycle`) that does the work and records how it ended.

  FL-01, create: `create_forum/2` checks the request, stores the forum with a fresh,
  encrypted `SECRET_KEY_BASE` (SC-04) as `creating`, and queues `Forums.CreateWorker`.
  """

  import Ecto.Query

  alias IdejoHub.{Audit, Repo, Secrets}
  alias IdejoHub.Forums.{CreateWorker, Forum, Mail, Subdomain}

  @doc "Defaults for a new forum's form: the configured Idejo version and limits."
  @spec defaults() :: map()
  def defaults do
    config = Application.fetch_env!(:idejo_hub, __MODULE__)

    %{
      idejo_version: config[:default_version],
      memory_mb: config[:default_memory_mb],
      cpus: config[:default_cpus]
    }
  end

  @doc "A changeset for the create form."
  @spec change_new_forum(map()) :: Ecto.Changeset.t()
  def change_new_forum(attrs \\ %{}) do
    Forum.create_changeset(struct(Forum, defaults()), attrs)
  end

  @doc """
  FL-01: records a new forum and queues its creation. `actor` names who asked (the operator;
  operator accounts come with SC-08). Returns the forum as `creating`.
  """
  @spec create_forum(map(), String.t()) :: {:ok, Forum.t()} | {:error, Ecto.Changeset.t()}
  def create_forum(attrs, actor) do
    changeset = change_new_forum(attrs)

    changeset =
      case Ecto.Changeset.fetch_field(changeset, :subdomain) do
        {_source, subdomain} when is_binary(subdomain) ->
          changeset
          |> Ecto.Changeset.put_change(
            :secret_key_base_enc,
            Secrets.encrypt(Secrets.new_secret_key_base(), context(subdomain, :secret_key_base))
          )
          |> put_default_mail_from(subdomain)

        _missing ->
          changeset
      end

    Repo.transaction(fn ->
      with {:ok, forum} <- Repo.insert(changeset),
           {:ok, _entry} <-
             forum
             |> audit_request(actor)
             |> Repo.insert(),
           {:ok, _job} <-
             Oban.insert(CreateWorker.new(%{"forum_id" => forum.id, "actor" => actor})) do
        forum
      else
        {:error, %Ecto.Changeset{data: %Forum{}} = changeset} -> Repo.rollback(changeset)
        {:error, other} -> raise "FL-01: could not record the request: #{inspect(other)}"
      end
    end)
  end

  # HN-07: the forum's own sender address, unless the operator gave one.
  defp put_default_mail_from(changeset, subdomain) do
    if Ecto.Changeset.get_field(changeset, :mail_from),
      do: changeset,
      else:
        Ecto.Changeset.put_change(
          changeset,
          :mail_from,
          Mail.default_from(host(%Forum{subdomain: subdomain}))
        )
  end

  defp audit_request(forum, actor) do
    Audit.changeset(actor, "forum.create", "requested", forum, %{
      "display_name" => forum.display_name,
      "owner_email" => forum.owner_email,
      "idejo_version" => forum.idejo_version
    })
  end

  @doc """
  FL-02: when the forum could not email its owner the link to choose a password, the Hub
  keeps it (encrypted) for the operator to pass on. This hands it over once: it is removed
  from the Hub, and the audit log records who took it.
  """
  @spec take_owner_link(Forum.t(), String.t()) :: {:ok, String.t()} | {:error, :none}
  def take_owner_link(%Forum{owner_link_enc: nil}, _actor), do: {:error, :none}

  def take_owner_link(%Forum{} = forum, actor) do
    with {:ok, link} <-
           Secrets.decrypt(forum.owner_link_enc, context(forum.subdomain, :owner_link)),
         {:ok, forum} <- update_state(forum, %{owner_link_enc: nil}),
         {:ok, _entry} <- Audit.record(actor, "forum.owner_link.take", "ok", forum) do
      {:ok, link}
    else
      _error -> {:error, :none}
    end
  end

  @doc "A forum by id."
  @spec get_forum!(integer()) :: Forum.t()
  def get_forum!(id), do: Repo.get!(Forum, id)

  @doc "A forum by subdomain, or nil."
  @spec get_by_subdomain(String.t()) :: Forum.t() | nil
  def get_by_subdomain(subdomain), do: Repo.get_by(Forum, subdomain: subdomain)

  @doc "All forums but deleted ones, by subdomain."
  @spec list_forums() :: [Forum.t()]
  def list_forums do
    Repo.all(from f in Forum, where: f.status != "deleted", order_by: f.subdomain)
  end

  @doc "Moves a forum's lifecycle state (the Hub's own changes, from jobs)."
  @spec update_state(Forum.t(), map()) :: {:ok, Forum.t()} | {:error, Ecto.Changeset.t()}
  def update_state(forum, attrs), do: forum |> Forum.state_changeset(attrs) |> Repo.update()

  @doc "The encryption context of one of a forum's secrets (SC-04)."
  @spec context(String.t(), atom()) :: String.t()
  def context(subdomain, field), do: "forum:#{subdomain}:#{field}"

  @doc "Decrypts one of a forum's secrets."
  @spec secret(Forum.t(), :secret_key_base | :db_password) ::
          {:ok, String.t()} | {:error, :invalid}
  def secret(%Forum{secret_key_base_enc: stored} = forum, :secret_key_base),
    do: decrypt(stored, forum, :secret_key_base)

  def secret(%Forum{db_password_enc: stored} = forum, :db_password),
    do: decrypt(stored, forum, :db_password)

  defp decrypt(nil, _forum, _field), do: {:error, :invalid}

  defp decrypt(stored, forum, field),
    do: Secrets.decrypt(stored, context(forum.subdomain, field))

  @doc "The forum's public host: `<subdomain>.<forum domain>`."
  @spec host(Forum.t()) :: String.t()
  def host(%Forum{subdomain: subdomain}) do
    subdomain <> "." <> Application.fetch_env!(:idejo_hub, __MODULE__)[:domain]
  end

  @doc """
  The forum a public host belongs to (`<subdomain>.<forum domain>`, one label), deleted ones
  included, or nil.
  """
  @spec for_host(String.t()) :: Forum.t() | nil
  def for_host(host) when is_binary(host) do
    suffix = "." <> Application.fetch_env!(:idejo_hub, __MODULE__)[:domain]
    host = String.downcase(host)

    with true <- String.ends_with?(host, suffix),
         subdomain = String.replace_suffix(host, suffix, ""),
         :ok <- Subdomain.validate(subdomain) do
      get_by_subdomain(subdomain)
    else
      _not_a_forum_host -> nil
    end
  end

  @doc """
  HN-02: whether Caddy may get a certificate for `host`: the Hub's own host, or the host of
  an existing forum that is not deleted.
  """
  @spec certificate_allowed?(String.t()) :: boolean()
  def certificate_allowed?(host) when is_binary(host) do
    host = String.downcase(host)

    cond do
      host in hub_hosts() -> true
      forum = for_host(host) -> forum.status != "deleted"
      true -> false
    end
  end

  defp hub_hosts do
    # The host the Hub serves itself on (PHX_HOST), read from config, not the web layer.
    [Application.fetch_env!(:idejo_hub, IdejoHubWeb.Endpoint)[:url][:host]]
  end

  @doc "LB-03: the source of the exact Idejo release a forum runs (`IDEJO_SOURCE_URL`)."
  @spec source_url(Forum.t()) :: String.t()
  def source_url(%Forum{idejo_version: version}) do
    Application.fetch_env!(:idejo_hub, __MODULE__)[:source_url_base] <> version
  end
end
