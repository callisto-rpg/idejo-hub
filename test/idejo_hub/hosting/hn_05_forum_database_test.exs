# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Hosting.HN05ForumDatabaseTest do
  @moduledoc """
  HN-05: one database and one role per forum, created by a role that is not superuser, and a
  forum's role reaches only its own database. Runs against the test PostgreSQL server, outside
  the SQL sandbox (CREATE DATABASE cannot run in a transaction).
  """
  use ExUnit.Case, async: false

  alias IdejoHub.Hosting.Postgres

  @moduletag req: "HN-05"
  @moduletag :capture_log

  # A stand-in for the bundle's `idejo_hub` role: CREATEDB CREATEROLE, never superuser.
  @hub_role "idejo_hub_hn05"
  @hub_password "hn05-test-only"
  @hub [username: @hub_role, password: @hub_password, database: "postgres"]
  @slugs ["hn05-tennis", "hn05-chess", "hn05-clash"]

  setup_all do
    superuser(fn conn ->
      Postgrex.query!(conn, "DROP ROLE IF EXISTS #{@hub_role}", [])

      Postgrex.query!(
        conn,
        "CREATE ROLE #{@hub_role} LOGIN CREATEDB CREATEROLE NOSUPERUSER PASSWORD '#{@hub_password}'",
        []
      )
    end)

    on_exit(fn ->
      superuser(fn conn ->
        for slug <- @slugs do
          Postgrex.query!(
            conn,
            ~s|DROP DATABASE IF EXISTS "#{Postgres.name(slug)}" WITH (FORCE)|,
            []
          )

          Postgrex.query!(conn, ~s|DROP ROLE IF EXISTS "#{Postgres.name(slug)}"|, [])
        end

        Postgrex.query!(conn, "DROP ROLE IF EXISTS #{@hub_role}", [])
      end)
    end)

    :ok
  end

  setup do
    on_exit(fn -> for slug <- @slugs, do: Postgres.drop(slug) end)
    :ok
  end

  test "names follow the slug" do
    assert Postgres.name("tennis-club") == "forum_tennis_club"
  end

  test "the Hub's role, not superuser, creates a database the forum can migrate" do
    assert {:ok, creds} = Postgres.provision("hn05-tennis", @hub)
    assert creds.database == "forum_hn05_tennis"
    assert creds.username == "forum_hn05_tennis"
    assert byte_size(creds.password) >= 40

    # What Idejo's first migrations need: a trusted extension and tables, as the owner.
    assert {:ok, _} =
             as(creds.username, creds.password, creds.database, [
               "CREATE EXTENSION IF NOT EXISTS citext",
               "CREATE TABLE members (email citext)"
             ])
  end

  test "a forum's role reaches only its own database" do
    {:ok, tennis} = Postgres.provision("hn05-tennis", @hub)
    {:ok, chess} = Postgres.provision("hn05-chess", @hub)

    assert {:ok, _} = as(tennis.username, tennis.password, tennis.database, ["SELECT 1"])
    assert {:error, _} = as(tennis.username, tennis.password, chess.database, ["SELECT 1"])
    assert {:error, _} = as(chess.username, chess.password, tennis.database, ["SELECT 1"])
  end

  test "a forum's role has no server-wide powers" do
    {:ok, creds} = Postgres.provision("hn05-tennis", @hub)

    superuser(fn conn ->
      %{rows: [row]} =
        Postgrex.query!(
          conn,
          "SELECT rolsuper, rolcreatedb, rolcreaterole, rolconnlimit FROM pg_roles WHERE rolname = $1",
          [creds.username]
        )

      assert row == [false, false, false, 25]
    end)
  end

  test "an existing forum is not overwritten, and a failed database leaves no role behind" do
    {:ok, _creds} = Postgres.provision("hn05-tennis", @hub)
    assert {:error, {:postgres, message}} = Postgres.provision("hn05-tennis", @hub)
    assert message =~ "already exists"

    superuser(&Postgrex.query!(&1, ~s|CREATE DATABASE "forum_hn05_clash"|, []))
    assert {:error, {:postgres, _}} = Postgres.provision("hn05-clash", @hub)
    refute role_exists?("forum_hn05_clash")
  end

  test "drop removes the database and the role, and is idempotent" do
    {:ok, creds} = Postgres.provision("hn05-tennis", @hub)
    assert Postgres.exists?("hn05-tennis", @hub)

    assert Postgres.drop("hn05-tennis", @hub) == :ok
    refute Postgres.exists?("hn05-tennis", @hub)
    refute role_exists?(creds.username)
    assert Postgres.drop("hn05-tennis", @hub) == :ok
  end

  test "the database URL escapes the password" do
    creds = %{database: "forum_x", username: "forum_x", password: "a/b+c"}
    assert Postgres.database_url(creds, "db") == "ecto://forum_x:a%2Fb%2Bc@db/forum_x"
  end

  ## Helpers

  defp server, do: Keyword.take(IdejoHub.Repo.config(), [:hostname, :port])

  defp superuser(fun) do
    config = Keyword.take(IdejoHub.Repo.config(), [:hostname, :port, :username, :password])
    {:ok, conn} = Postgrex.start_link(config ++ [database: "postgres", pool_size: 1])

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  defp role_exists?(name) do
    superuser(fn conn ->
      Postgrex.query!(conn, "SELECT 1 FROM pg_roles WHERE rolname = $1", [name]).num_rows == 1
    end)
  end

  # Connects as a forum role; a refused connection is an error, not a crash.
  defp as(user, password, database, statements) do
    Process.flag(:trap_exit, true)

    {:ok, conn} =
      Postgrex.start_link(
        server() ++
          [
            username: user,
            password: password,
            database: database,
            pool_size: 1,
            backoff_type: :stop,
            queue_target: 2_000
          ]
      )

    result =
      try do
        Enum.reduce_while(statements, {:ok, nil}, fn sql, _acc ->
          case Postgrex.query(conn, sql, []) do
            {:ok, result} -> {:cont, {:ok, result}}
            error -> {:halt, error}
          end
        end)
      catch
        # The connection was refused (and its process stopped, backoff_type: :stop).
        :exit, reason -> {:error, {:refused, reason}}
      end

    if Process.alive?(conn), do: GenServer.stop(conn)
    result
  end
end
