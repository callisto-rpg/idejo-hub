# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.AddForumMailAndOwnerInvite do
  use Ecto.Migration

  def change do
    alter table(:forums) do
      # HN-07: the forum's own sender address (its name is the forum's display name).
      add :mail_from, :string
      # FL-02: how the owner's invite went out ("emailed" or "operator"), and, while the
      # operator has not taken it, the link itself, encrypted (SC-04).
      add :owner_invite, :string
      add :owner_link_enc, :binary
    end
  end
end
