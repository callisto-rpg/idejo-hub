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
  alias IdejoHub.Forums.{CreateWorker, Forum}

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
          Ecto.Changeset.put_change(
            changeset,
            :secret_key_base_enc,
            Secrets.encrypt(Secrets.new_secret_key_base(), context(subdomain, :secret_key_base))
          )

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

  defp audit_request(forum, actor) do
    Audit.changeset(actor, "forum.create", "requested", forum, %{
      "display_name" => forum.display_name,
      "owner_email" => forum.owner_email,
      "idejo_version" => forum.idejo_version
    })
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

  @doc "LB-03: the source of the exact Idejo release a forum runs (`IDEJO_SOURCE_URL`)."
  @spec source_url(Forum.t()) :: String.t()
  def source_url(%Forum{idejo_version: version}) do
    Application.fetch_env!(:idejo_hub, __MODULE__)[:source_url_base] <> version
  end
end
