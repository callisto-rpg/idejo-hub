# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.OutsideForums do
  @moduledoc """
  idejo servers not hosted here that sign in with this Hub's idejo ID (steward decisions
  2026-11-06; extra review: DV-06).

  Registration, from the forum's admin panel, in two calls to the sign-in host's JSON API
  (`IdejoHubWeb.RegistryController`):

    1. `start/2` (host, name): a `registration` key, kept by the forum, and a `proof`, which
       the forum serves at `https://<host>/.well-known/idejo-id-registration` for ten
       minutes. Only their hashes are stored.
    2. `verify/1` (the registration key): the Hub fetches the proof (`Proof.fetch/1`); when
       it matches, it makes the forum's OpenID Connect client (`Identity.create_client/1`,
       the forum's `https://<host>/users/oidc/callback`), or gives a known host a new secret
       (its old one stops working), and answers the issuer, client id and secret once.

  Asking again for a registered host changes nothing until it is proven, so nobody can take
  over or rename another server's registration. The forum then asks to be listed in the
  directory with its client credentials (`set_listing/3`); an operator approves or refuses
  (`/outside-forums`), and can remove a forum (its client deleted). Hosts under the forum
  domain and the Hub's own are refused: those are the Hub's.
  """
  import Ecto.Query

  alias IdejoHub.{Audit, Community, Identity, Repo}
  alias IdejoHub.Identity.{OutsideForum, Proof}

  @challenge_seconds 600
  @label "idejo ID"

  @doc "How long a forum has to serve its proof, in seconds."
  def challenge_seconds, do: @challenge_seconds

  ## Registration

  @doc "Step 1: `{:ok, %{registration:, proof:}}` for `host`, named `name`."
  @spec start(term(), term()) ::
          {:ok, %{registration: String.t(), proof: String.t()}}
          | {:error, :invalid_host | :invalid_name | :unavailable}
  def start(host, name) do
    host = host |> to_string() |> String.trim() |> String.downcase()
    name = name |> to_string() |> String.trim()

    with true <- Identity.enabled?() || {:error, :unavailable},
         :ok <- check_host(host),
         :ok <- check_name(name) do
      registration = token()
      proof = token()

      challenge = %{
        registration_hash: hash(registration),
        proof_hash: hash(proof),
        challenge_expires_at:
          DateTime.utc_now() |> DateTime.add(@challenge_seconds) |> DateTime.truncate(:second),
        pending_name: name
      }

      now = DateTime.utc_now(:second)

      Repo.insert!(
        struct(OutsideForum, Map.merge(challenge, %{host: host, display_name: name})),
        on_conflict: [set: Map.to_list(Map.put(challenge, :updated_at, now))],
        conflict_target: :host
      )

      {:ok, %{registration: registration, proof: proof}}
    end
  end

  @doc """
  Step 2: the proof checked, the client made (or its secret renewed):
  `{:ok, %{issuer:, client_id:, client_secret:, label:, sign_up_url:, directory_url:,
  chat_url:, topics_url:}}`.
  """
  @spec verify(term()) :: {:ok, map()} | {:error, term()}
  def verify(registration) when is_binary(registration) and registration != "" do
    with %OutsideForum{} = forum <-
           Repo.get_by(OutsideForum, registration_hash: hash(registration)) ||
             {:error, :unknown},
         :ok <- fresh(forum),
         {:ok, served} <- Proof.fetch(forum.host),
         true <- Plug.Crypto.secure_compare(hash(served), forum.proof_hash) || {:error, :proof},
         {:ok, client} <- credentials(forum) do
      renewed? = forum.app_id != nil

      forum
      |> Ecto.Changeset.change(%{
        status: "registered",
        app_id: client.app_id,
        client_id: client.client_id,
        secret_hash: hash(client.client_secret),
        display_name: forum.pending_name || forum.display_name,
        pending_name: nil,
        registration_hash: nil,
        proof_hash: nil,
        challenge_expires_at: nil
      })
      |> Repo.update!()

      audit(forum.host, "identity.outside_forum.register", "ok", %{"renewed" => renewed?})

      {:ok,
       %{
         issuer: Identity.issuer(),
         client_id: client.client_id,
         client_secret: client.client_secret,
         label: @label,
         sign_up_url: Identity.issuer() <> "/account/sign-up",
         directory_url: Community.directory_url(),
         # idejo's chat service (steward request 2026-11-10).
         chat_url: Community.chat_url(),
         topics_url: Community.topics_url()
       }}
    else
      {:error, :unknown} = error ->
        error

      {:error, reason} = error ->
        with %OutsideForum{host: host} <-
               Repo.get_by(OutsideForum, registration_hash: hash(registration)) do
          audit(host, "identity.outside_forum.register", "failed", %{"reason" => why(reason)})
        end

        error
    end
  end

  def verify(_registration), do: {:error, :unknown}

  defp fresh(%OutsideForum{challenge_expires_at: %DateTime{} = at}) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt, do: :ok, else: {:error, :expired}
  end

  defp fresh(_forum), do: {:error, :expired}

  defp credentials(%OutsideForum{app_id: nil, host: host}), do: Identity.create_client(host)

  defp credentials(%OutsideForum{app_id: app_id, client_id: client_id, host: host}) do
    case Identity.rotate_secret(app_id) do
      {:ok, secret} -> {:ok, %{app_id: app_id, client_id: client_id, client_secret: secret}}
      # The client is gone at the provider: a new one.
      {:error, {:status, 404, _}} -> Identity.create_client(host)
      error -> error
    end
  end

  ## The forum, by its client credentials

  @doc "The registered outside forum whose client is `client_id` with `secret`, or nil."
  @spec authenticate(term(), term()) :: OutsideForum.t() | nil
  def authenticate(client_id, secret)
      when is_binary(client_id) and client_id != "" and is_binary(secret) do
    with %OutsideForum{status: "registered", secret_hash: stored} = forum <-
           Repo.get_by(OutsideForum, client_id: client_id),
         true <- Plug.Crypto.secure_compare(hash(secret), stored) do
      forum
    else
      _ -> nil
    end
  end

  def authenticate(_client_id, _secret), do: nil

  @doc """
  The forum asks to be in the directory (`listed?` true, under `name`) or to leave it.
  Asking puts it `requested` for an operator; an approved forum stays approved unless its
  name changes (asked again); a refused one stays refused until it leaves and asks again.
  """
  @spec set_listing(OutsideForum.t(), boolean(), term()) ::
          {:ok, OutsideForum.t()} | {:error, :invalid_name}
  def set_listing(%OutsideForum{} = forum, listed?, name) do
    name = if is_binary(name), do: String.trim(name), else: forum.display_name

    with :ok <- check_name(name) do
      listing =
        cond do
          not listed? -> "none"
          forum.listing == "approved" and name == forum.display_name -> "approved"
          forum.listing == "refused" -> "refused"
          true -> "requested"
        end

      forum =
        forum
        |> Ecto.Changeset.change(listing: listing, display_name: name)
        |> Repo.update!()

      audit(forum.host, "identity.outside_forum.listing", "ok", %{"listing" => listing})
      {:ok, forum}
    end
  end

  ## Operators

  @doc "Every outside forum: listing requests first, then by host."
  @spec list() :: [OutsideForum.t()]
  def list do
    Repo.all(
      from f in OutsideForum,
        order_by: [desc: f.listing == "requested", asc: f.host]
    )
  end

  @doc ~S'An operator approves (`"approved"`) or refuses (`"refused"`) a listing request.'
  @spec decide(integer() | String.t(), String.t(), String.t()) ::
          {:ok, OutsideForum.t()} | {:error, :not_found | :not_requested}
  def decide(id, decision, actor) when decision in ["approved", "refused"] do
    case Repo.get(OutsideForum, id) do
      nil ->
        {:error, :not_found}

      %OutsideForum{listing: listing} = forum when listing in ["requested", "approved"] ->
        forum = forum |> Ecto.Changeset.change(listing: decision) |> Repo.update!()

        Audit.record(actor, "identity.outside_forum.#{verb(decision)}", "ok", nil, %{
          "host" => forum.host
        })

        {:ok, forum}

      _forum ->
        {:error, :not_requested}
    end
  end

  defp verb("approved"), do: "approve"
  defp verb("refused"), do: "refuse"

  @doc "An operator removes an outside forum: its client deleted, its sign-in stops."
  @spec remove(integer() | String.t(), String.t()) :: :ok | {:error, term()}
  def remove(id, actor) do
    with %OutsideForum{} = forum <- Repo.get(OutsideForum, id) || {:error, :not_found},
         :ok <- if(forum.app_id, do: Identity.delete_client(forum.app_id), else: :ok) do
      Repo.delete!(forum)
      Audit.record(actor, "identity.outside_forum.remove", "ok", nil, %{"host" => forum.host})
      :ok
    end
  end

  ## The directory and sign-up

  @doc "Approved, registered outside forums (the directory's query)."
  def listed_query,
    do: from(f in OutsideForum, where: f.status == "registered" and f.listing == "approved")

  @doc "The registered outside forum at `host`, or nil (sign-up's way back)."
  @spec registered(String.t()) :: OutsideForum.t() | nil
  def registered(host) when is_binary(host),
    do: Repo.get_by(OutsideForum, host: String.downcase(host), status: "registered")

  ## Checks

  @host ~r/\A[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+\z/

  @doc false
  def check_host(host) do
    labels = String.split(host, ".")

    cond do
      byte_size(host) > 253 or not (host =~ @host) -> {:error, :invalid_host}
      # A name, not an address: the last label has a letter.
      not (List.last(labels) =~ ~r/[a-z]/) -> {:error, :invalid_host}
      own?(host) -> {:error, :invalid_host}
      true -> :ok
    end
  end

  defp own?(host) do
    domain = Application.fetch_env!(:idejo_hub, IdejoHub.Forums)[:domain]

    host in [domain, Identity.config(:domain), IdejoHubWeb.Endpoint.host()] or
      String.ends_with?(host, "." <> domain)
  end

  defp check_name(name) do
    if name != "" and String.length(name) <= 100, do: :ok, else: {:error, :invalid_name}
  end

  defp token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  defp hash(value), do: :crypto.hash(:sha256, value)

  defp audit(host, action, outcome, details),
    do: Audit.record("forum:#{host}", action, outcome, nil, Map.put(details, "host", host))

  @doc false
  def why({:status, status}), do: "the proof answered #{status}"
  def why(:proof), do: "the proof did not match"
  def why(:expired), do: "the ten minutes passed"
  def why(:not_public), do: "the host is not on a public network"
  def why(:no_address), do: "the host has no address"
  def why(:unreachable), do: "the host could not be reached over https"
  def why(:too_long), do: "the proof was not the one given"
  def why({:status, _, _}), do: "the provider refused"
  def why(_other), do: "the provider could not be reached"
end
