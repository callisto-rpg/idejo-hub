# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.Fake do
  @moduledoc "An in-memory identity provider for tests (ID-01): clients by app id."
  @behaviour IdejoHub.Identity

  @key {__MODULE__, :clients}

  @doc "Starts empty for the calling test (and the processes it starts)."
  def start do
    {:ok, pid} =
      Agent.start_link(fn ->
        %{
          clients: %{},
          failures: %{},
          people: %{},
          invites: [],
          configured: [],
          sign_ins: [],
          deleted: [],
          tokens: %{}
        }
      end)

    Process.put(@key, pid)
    pid
  end

  @doc "The next call to `fun` fails."
  def fail(fun), do: Agent.update(server(), &put_in(&1, [:failures, fun], {:status, 500, "fake"}))

  @doc "The clients registered, by app id."
  def clients, do: Agent.get(server(), & &1.clients)

  @doc "People made, by user id; invites sent (user ids); configurations applied."
  def people, do: Agent.get(server(), & &1.people)
  def invites, do: Agent.get(server(), & &1.invites)
  def configured, do: Agent.get(server(), & &1.configured)

  @impl true
  def create_person(person) do
    call(:create_person, fn s ->
      if Enum.any?(Map.values(s.people), &(&1.email == person.email)) do
        {{:error, :exists}, s}
      else
        id = "user-#{map_size(s.people) + 1}"
        {{:ok, id}, put_in(s, [:people, id], person)}
      end
    end)
  end

  @impl true
  def send_invite(user_id),
    do: call(:send_invite, fn s -> {:ok, %{s | invites: s.invites ++ [user_id]}} end)

  @impl true
  def configure(smtp, sender),
    do: call(:configure, fn s -> {:ok, %{s | configured: s.configured ++ [{smtp, sender}]}} end)

  @impl true
  def create_client(host) do
    call(:create_client, fn s ->
      n = map_size(s.clients) + 1

      client = %{
        app_id: "app-#{n}",
        client_id: "client-#{n}",
        client_secret: "secret-#{n}-#{System.unique_integer([:positive])}"
      }

      {{:ok, client}, put_in(s, [:clients, client.app_id], Map.put(client, :host, host))}
    end)
  end

  @impl true
  def create_account_client(host), do: create_client("account:" <> host)

  @doc "Records a sign-in of `user_id` to `client_id` (as a forum's or the Hub's would)."
  def sign_in(user_id, client_id, at \\ DateTime.utc_now()),
    do:
      Agent.update(
        server(),
        &%{&1 | sign_ins: &1.sign_ins ++ [%{user_id: user_id, client_id: client_id, at: at}]}
      )

  @doc "The token endpoint will answer `code` with these ID token claims."
  def put_code(code, claims), do: Agent.update(server(), &put_in(&1, [:tokens, code], claims))

  @doc "People deleted (user ids)."
  def deleted, do: Agent.get(server(), & &1.deleted)

  @impl true
  def sign_ins_since(since) do
    call(:sign_ins_since, fn s ->
      {{:ok, Enum.filter(s.sign_ins, &(since == nil or DateTime.compare(&1.at, since) != :lt))},
       s}
    end)
  end

  @impl true
  def person(user_id) do
    call(:person, fn s ->
      case s.people[user_id] do
        nil ->
          {{:error, :not_found}, s}

        p ->
          {{:ok,
            %{
              email: p.email,
              email_verified: Map.get(p, :email_verified, false),
              display_name: p.display_name
            }}, s}
      end
    end)
  end

  @impl true
  def delete_person(user_id) do
    call(:delete_person, fn s ->
      {:ok, %{s | people: Map.delete(s.people, user_id), deleted: s.deleted ++ [user_id]}}
    end)
  end

  @impl true
  def exchange_code(code, _verifier, _redirect_uri, _client_id, _secret) do
    call(:exchange_code, fn s ->
      case Map.pop(s.tokens, code) do
        {nil, _} -> {{:error, {:status, 400, "token"}}, s}
        {claims, tokens} -> {{:ok, claims}, %{s | tokens: tokens}}
      end
    end)
  end

  @impl true
  def rotate_secret(app_id) do
    call(:rotate_secret, fn s ->
      case s.clients[app_id] do
        nil ->
          {{:error, {:status, 404, "no app"}}, s}

        _c ->
          secret = "rotated-#{System.unique_integer([:positive])}"
          {{:ok, secret}, put_in(s, [:clients, app_id, :client_secret], secret)}
      end
    end)
  end

  @impl true
  def delete_client(app_id),
    do: call(:delete_client, fn s -> {:ok, update_in(s.clients, &Map.delete(&1, app_id))} end)

  defp call(name, fun) do
    Agent.get_and_update(server(), fn s ->
      case Map.pop(s.failures, name) do
        {nil, _} -> fun.(s)
        {error, failures} -> {{:error, error}, %{s | failures: failures}}
      end
    end)
  end

  defp server do
    Enum.find_value([self() | Process.get(:"$callers", [])], &server_of/1) ||
      raise "IdejoHub.Identity.Fake.start/0 was not called by this test"
  end

  defp server_of(pid) when pid == self(), do: Process.get(@key)

  defp server_of(pid) do
    with {:dictionary, dict} <- Process.info(pid, :dictionary),
         {@key, server} <- List.keyfind(dict, @key, 0) do
      server
    else
      _missing -> nil
    end
  end
end
