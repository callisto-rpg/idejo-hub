# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :idejo_hub

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  SC-08: creates an operator and prints their one-time password
  (`bin/hub-admin create-operator EMAIL [--role owner|operator]`). They set up two-factor at
  their first sign-in. HA-07: without a role, the first account is an owner, later ones
  operators.
  """
  def create_operator(email, role \\ nil) do
    role = if role in [nil, ""], do: nil, else: role

    with_repo(fn ->
      case IdejoHub.Operators.create_operator(email, role) do
        {:ok, operator, password} ->
          IO.puts("""
          Operator #{operator.email} created, role #{operator.role}. Their password, shown only now:

              #{password}

          At their first sign-in they set up two-factor sign-in with an authenticator app.\
          """)

        {:error, changeset} ->
          fail("Not created: " <> errors(changeset))
      end
    end)
  end

  @doc """
  SC-08: removes an operator's two-factor setup and ends their sessions
  (`bin/hub-admin reset-two-factor EMAIL`), for a lost phone.
  """
  def reset_two_factor(email) do
    with_repo(fn ->
      case IdejoHub.Operators.reset_two_factor(email) do
        :ok ->
          IO.puts(
            "Two-factor sign-in of #{email} removed; they set it up again at their next sign-in."
          )

        {:error, :not_found} ->
          fail("No operator has the email #{email}.")
      end
    end)
  end

  # Runs `fun` with the repo started (eval: the server may not be running) and exits
  # non-zero on failure, never halting a running node.
  defp with_repo(fun) do
    load_app()
    Application.ensure_all_started(:argon2_elixir)
    [repo] = repos()
    {:ok, result, _} = Ecto.Migrator.with_repo(repo, fn _repo -> fun.() end)
    result
  end

  defp fail(message) do
    IO.puts(:stderr, message)
    exit({:shutdown, 1})
  end

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
