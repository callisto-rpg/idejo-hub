# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity do
  @moduledoc """
  ID-01: the Hub's side of the identity provider (Zitadel, steward decision 2026-11-03).
  Each forum is an OpenID Connect client of it, registered when the forum is made, with its
  secret rotated on demand and removed when the forum is purged.

  Calls go to the configured adapter: `Identity.Zitadel` (its management API, with the
  machine user's token) or `Identity.Fake` in tests. Not configured (no token file), there
  is no shared sign-in: forums are made with local accounts only.
  """

  @type client :: %{app_id: String.t(), client_id: String.t(), client_secret: String.t()}

  @callback create_client(host :: String.t()) :: {:ok, client()} | {:error, term()}
  @callback rotate_secret(app_id :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback delete_client(app_id :: String.t()) :: :ok | {:error, term()}

  @type person :: %{
          email: String.t(),
          display_name: String.t(),
          given_name: String.t(),
          family_name: String.t(),
          language: String.t()
        }

  @callback create_person(person()) :: {:ok, String.t()} | {:error, :exists | term()}
  @callback send_invite(user_id :: String.t()) :: :ok | {:error, term()}
  @callback configure(smtp :: keyword() | nil, sender :: String.t()) :: :ok | {:error, term()}

  @type sign_in :: %{user_id: String.t(), client_id: String.t(), at: DateTime.t()}

  @callback create_account_client(host :: String.t()) :: {:ok, client()} | {:error, term()}
  @callback sign_ins_since(DateTime.t() | nil) :: {:ok, [sign_in()]} | {:error, term()}
  @callback person(user_id :: String.t()) ::
              {:ok, %{email: String.t(), display_name: String.t()}}
              | {:error, :not_found | term()}
  @callback delete_person(user_id :: String.t()) :: :ok | {:error, term()}
  # HA-06: identity administration. A person as listed: the provider's id, their email (and
  # whether verified), names, and state (`active`, `locked`, `inactive`, `initial`).
  @type listed :: %{
          id: String.t(),
          email: String.t() | nil,
          email_verified: boolean(),
          display_name: String.t() | nil,
          username: String.t() | nil,
          state: String.t()
        }
  @callback search_people(text :: String.t()) :: {:ok, [listed()]} | {:error, term()}
  @callback lock_person(user_id :: String.t()) :: :ok | {:error, term()}
  @callback unlock_person(user_id :: String.t()) :: :ok | {:error, term()}
  @callback exchange_code(
              code :: String.t(),
              verifier :: String.t(),
              redirect_uri :: String.t(),
              client_id :: String.t(),
              secret :: String.t()
            ) ::
              {:ok, id_token_claims :: map()} | {:error, term()}

  @doc "Whether the Hub has an identity provider to register forums with."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:adapter) != nil

  def create_client(host), do: config(:adapter).create_client(host)
  def rotate_secret(app_id), do: config(:adapter).rotate_secret(app_id)
  def delete_client(app_id), do: config(:adapter).delete_client(app_id)

  @doc """
  ID-02: makes a person at the provider. Zitadel requires a first and a last name; the Hub's
  sign-up leaves them optional (steward decision 2026-11-04), so these stand in.
  """
  def create_person(person), do: config(:adapter).create_person(person)

  @doc "ID-02: the provider emails the person a link to verify the address and choose a password or passkey."
  def send_invite(user_id), do: config(:adapter).send_invite(user_id)

  @doc "ID-02, ID-08: the provider's settings (its own sign-up off, passkeys and 2FA on, the Hub's SMTP)."
  def configure(smtp, sender), do: config(:adapter).configure(smtp, sender)

  @doc "ID-05: the Hub's own client, for the members' pages at `https://<id host>/account`."
  def create_account_client(host), do: config(:adapter).create_account_client(host)

  @doc "ID-05: sign-ins to any client since `since` (oldest first): who, to which client, when."
  def sign_ins_since(since), do: config(:adapter).sign_ins_since(since)

  @doc "ID-05: a person's email and display name, for their page."
  def person(user_id), do: config(:adapter).person(user_id)

  @doc "HA-06: people whose email, name or username contains `text` (any case), at most 50."
  def search_people(text), do: config(:adapter).search_people(text)

  @doc "HA-06: locks a person for abuse: the provider refuses their sign-ins (already locked is fine)."
  def lock_person(user_id), do: config(:adapter).lock_person(user_id)

  @doc "HA-06: unlocks a person (not locked is fine)."
  def unlock_person(user_id), do: config(:adapter).unlock_person(user_id)

  @doc "ID-06: deletes the person at the provider (already gone is fine)."
  def delete_person(user_id), do: config(:adapter).delete_person(user_id)

  @doc "ID-05: the members' pages' code exchange: the ID token's claims, not yet checked."
  def exchange_code(code, verifier, redirect_uri, client_id, secret),
    do: config(:adapter).exchange_code(code, verifier, redirect_uri, client_id, secret)

  @placeholder_given "Sennoma"
  @placeholder_family "Ulo"

  @doc "The names Zitadel gets when a person gives none."
  def placeholder_names, do: {@placeholder_given, @placeholder_family}

  @doc "The provider's issuer, the address forums sign in through."
  @spec issuer() :: String.t()
  def issuer, do: "https://" <> config(:domain)

  @doc "The sign-in button's words on every forum."
  @spec label() :: String.t()
  def label, do: config(:label) || "idejo ID"

  @doc false
  def config(key), do: Application.fetch_env!(:idejo_hub, __MODULE__)[key]
end
