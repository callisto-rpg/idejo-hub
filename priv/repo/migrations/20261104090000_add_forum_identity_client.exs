# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddForumIdentityClient do
  use Ecto.Migration

  def change do
    alter table(:forums) do
      # ID-01: the forum's OpenID Connect client at the identity provider (secret encrypted, SC-04).
      add :oidc_app_id, :string
      add :oidc_client_id, :string
      add :oidc_client_secret_enc, :binary
      # ID-07: whether the forum also allows local accounts (IDEJO_LOCAL_ACCOUNTS).
      add :local_accounts, :boolean, null: false, default: true
    end
  end
end
