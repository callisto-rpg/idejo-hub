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

  @doc "Whether the Hub has an identity provider to register forums with."
  @spec enabled?() :: boolean()
  def enabled?, do: config(:adapter) != nil

  def create_client(host), do: config(:adapter).create_client(host)
  def rotate_secret(app_id), do: config(:adapter).rotate_secret(app_id)
  def delete_client(app_id), do: config(:adapter).delete_client(app_id)

  @doc "The provider's issuer, the address forums sign in through."
  @spec issuer() :: String.t()
  def issuer, do: "https://" <> config(:domain)

  @doc "The sign-in button's words on every forum."
  @spec label() :: String.t()
  def label, do: config(:label) || "Idejo ID"

  @doc false
  def config(key), do: Application.fetch_env!(:idejo_hub, __MODULE__)[key]
end
