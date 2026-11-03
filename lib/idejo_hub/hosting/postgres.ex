# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.Postgres do
  @moduledoc """
  HN-05: one shared PostgreSQL server; one database and one login role per forum, and a
  forum's role can reach only its own database.

  The Hub connects as its own role (`CREATEDB CREATEROLE`, never superuser). For each forum it
  creates the role `forum_<slug>` (hyphens become underscores; slugs have no underscores, so
  names cannot collide) and the database of the same name, owned by that role. `CONNECT` on
  the database is revoked from `PUBLIC`, so no other forum's role can open it. The bundle's
  init script does the same for the server's other databases, and its `pg_hba.conf` rule
  `sameuser` lets each role open only the database of its own name
  (`deploy/postgres-init/02-forum-isolation.sh`).

  The Hub never connects to a forum's database (CLAUDE.md, The one rule): Idejo creates its
  own tables (and the trusted `citext` extension) with its migrations, as the database owner.

  DDL cannot run in a transaction, so each call opens its own short connection instead of
  using the Repo's pool. Statements that carry a password are never logged.
  """

  @connection_limit 25

  @type credentials :: %{database: String.t(), username: String.t(), password: String.t()}

  @doc "The role and database name for a forum's slug."
  @spec name(String.t()) :: String.t()
  def name(slug), do: "forum_" <> String.replace(slug, "-", "_")

  @doc """
  Creates the forum's role (with a new random password) and its database. If the database
  cannot be created, the role is dropped again. Fails if either already exists.
  """
  @spec provision(String.t(), keyword()) :: {:ok, credentials()} | {:error, term()}
  def provision(slug, opts \\ []) do
    name = name(slug)
    password = IdejoHub.Secrets.random(32)

    with_conn(opts, fn conn ->
      # As the role's creator, the Hub becomes a member of it, so it can drop the forum's
      # database later (owned by that role). Session-only setting, PostgreSQL 16+.
      with {:ok, _} <- query(conn, "SET createrole_self_grant = 'set, inherit'"),
           {:ok, _} <-
             query(
               conn,
               "CREATE ROLE #{ident(name)} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE " <>
                 "CONNECTION LIMIT #{@connection_limit} PASSWORD #{literal(password)}",
               secret: true
             ),
           :ok <- create_database(conn, name) do
        {:ok, %{database: name, username: name, password: password}}
      end
    end)
  end

  defp create_database(conn, name) do
    with {:ok, _} <- query(conn, "CREATE DATABASE #{ident(name)} OWNER #{ident(name)}"),
         {:ok, _} <- query(conn, "REVOKE ALL ON DATABASE #{ident(name)} FROM PUBLIC"),
         {:ok, _} <-
           query(conn, "GRANT CONNECT, TEMPORARY ON DATABASE #{ident(name)} TO #{ident(name)}") do
      :ok
    else
      error ->
        query(conn, "DROP DATABASE IF EXISTS #{ident(name)} WITH (FORCE)")
        query(conn, "DROP ROLE IF EXISTS #{ident(name)}")
        error
    end
  end

  @doc """
  Drops the forum's database (closing its connections) and its role. What is already gone is
  not an error. The data is lost: callers make the final export first (FL-05).
  """
  @spec drop(String.t(), keyword()) :: :ok | {:error, term()}
  def drop(slug, opts \\ []) do
    name = name(slug)

    with_conn(opts, fn conn ->
      with {:ok, _} <- query(conn, "DROP DATABASE IF EXISTS #{ident(name)} WITH (FORCE)"),
           {:ok, _} <- query(conn, "DROP ROLE IF EXISTS #{ident(name)}") do
        :ok
      end
    end)
  end

  @doc "Whether the forum's database exists."
  @spec exists?(String.t(), keyword()) :: boolean()
  def exists?(slug, opts \\ []) do
    with_conn(opts, fn conn ->
      case Postgrex.query(conn, "SELECT 1 FROM pg_database WHERE datname = $1", [name(slug)]) do
        {:ok, %{num_rows: 1}} -> true
        _other -> false
      end
    end)
  end

  @doc """
  The `DATABASE_URL` a forum container gets (Idejo AD-13). `host` is the database server's
  name on the forum network.
  """
  @spec database_url(credentials(), String.t()) :: String.t()
  def database_url(%{database: db, username: user, password: password}, host) do
    "ecto://#{user}:#{URI.encode_www_form(password)}@#{host}/#{db}"
  end

  ## Connection

  # `opts` overrides the connection settings taken from IdejoHub.Repo (tests connect as a
  # non-superuser role to prove the Hub's role is enough).
  defp with_conn(opts, fun) do
    {:ok, conn} = Postgrex.start_link(Keyword.merge(repo_options(), opts) ++ [pool_size: 1])

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  defp repo_options do
    config = IdejoHub.Repo.config()

    url_options =
      case config[:url] do
        nil -> []
        url -> Ecto.Repo.Supervisor.parse_url(url)
      end

    config
    |> Keyword.merge(url_options)
    |> Keyword.take([:hostname, :port, :username, :password, :database, :ssl, :socket_options])
  end

  defp query(conn, sql, opts \\ []) do
    # Postgrex itself never logs statements (only Ecto does), so passwords stay out of logs.
    case Postgrex.query(conn, sql, []) do
      {:ok, result} ->
        {:ok, result}

      # The message never includes the statement, so a password cannot leak through it.
      {:error, %Postgrex.Error{postgres: %{message: message}}} ->
        {:error, {:postgres, message}}

      {:error, error} ->
        {:error,
         {:postgres, if(opts[:secret], do: "connection error", else: Exception.message(error))}}
    end
  end

  # Names come from validated slugs and passwords from Base64url, but both are quoted anyway.
  defp ident(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s(")
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
