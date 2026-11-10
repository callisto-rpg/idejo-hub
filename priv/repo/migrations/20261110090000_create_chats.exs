# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Repo.Migrations.CreateChats do
  use Ecto.Migration

  # Chats (steward request 2026-11-10): private conversations between Idejo IDs, held by the
  # Hub at my.<forum domain>/chat rather than by each forum, written like an Idejo topic
  # (growing messages) without patience timers. Members are Idejo ID subjects.
  def change do
    create table(:chats) do
      # The two subjects, sorted, one per line: one chat per pair.
      add :pair_key, :string, null: false
      add :last_activity_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:chats, [:pair_key])

    create table(:chat_members, primary_key: false) do
      add :chat_id, references(:chats, on_delete: :delete_all), primary_key: true
      add :subject, :string, primary_key: true
      # Messages by others opened after this are unread.
      add :last_read_at, :utc_datetime_usec
    end

    create index(:chat_members, [:subject])

    create table(:chat_messages) do
      add :chat_id, references(:chats, on_delete: :delete_all), null: false
      add :author_subject, :string, null: false
      # "open" while its author still adds to it (Enter), "closed" after Ctrl+Enter.
      add :state, :string, null: false, default: "open"
      add :body_md, :text, null: false, default: ""
      add :body_html, :text, null: false, default: ""
      add :opened_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec
      add :edited, :boolean, null: false, default: false
      add :deleted_at, :utc_datetime_usec
      add :reply_to_id, references(:chat_messages, on_delete: :nilify_all)
      # Copied from a forum's private conversation: "<host>/<message id>", once.
      add :source, :string
    end

    create index(:chat_messages, [:chat_id, :opened_at])
    create index(:chat_messages, [:reply_to_id])
    create unique_index(:chat_messages, [:source])

    # One open message per author per chat (as Idejo's GM-09).
    create unique_index(:chat_messages, [:chat_id, :author_subject],
             where: "state = 'open'",
             name: :chat_messages_one_open_index
           )

    create table(:chat_reactions, primary_key: false) do
      add :message_id, references(:chat_messages, on_delete: :delete_all), primary_key: true
      add :subject, :string, primary_key: true
      add :emoji, :string, primary_key: true
    end

    # When a member's conversations were last copied from a forum, and how many stayed there.
    create table(:chat_imports, primary_key: false) do
      add :subject, :string, primary_key: true
      add :host, :string, primary_key: true
      add :remaining, :integer, null: false, default: 0
      add :forum_url, :string
      add :imported_at, :utc_datetime, null: false
    end

    # Tickets the Hub hands a forum to ask about one member (a forum checks it back).
    create table(:chat_tickets, primary_key: false) do
      add :token_hash, :binary, primary_key: true
      add :subject, :string, null: false
      add :scope, :string, null: false
      # Whose ticket: "forum:<id>" (hosted) or "outside:<id>".
      add :client, :string, null: false
      add :expires_at, :utc_datetime, null: false
    end
  end
end
