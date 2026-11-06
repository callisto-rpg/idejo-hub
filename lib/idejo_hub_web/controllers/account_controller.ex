# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.AccountController do
  @moduledoc """
  ID-05, ID-06: a member's own page, `https://<id host>/account`. Signed in through the
  provider like a forum (the Hub's own client, `Members.account_client/0`): code flow with
  PKCE, `state` and `nonce`, the request kept in the session ten minutes and used once; the
  ID token comes from the provider over the bundle's network and its issuer, audience,
  expiry and nonce are checked. The member's session (`member`: the provider's subject and
  when they signed in) lasts an hour.

  The page lists the forums joined, each with "Leave" (account and messages kept) or
  "Delete my account there" (as the forum's rules say: messages show "Deleted user";
  confirmed by a checkbox), and "Delete my Idejo ID", which needs a sign-in within five
  minutes and the email typed. Plain HTML, no JavaScript.
  """
  use IdejoHubWeb, :controller

  require Logger

  alias IdejoHub.Identity
  alias IdejoHub.Identity.Members

  @request_key "account_request"
  @member_key "member"
  @request_seconds 600
  @session_seconds 3600
  @fresh_seconds 300

  def show(conn, _params) do
    case member(conn) do
      nil ->
        render(conn, :signed_out)

      member ->
        _ = Members.sync()
        subject = member["sub"]
        person = person(subject)

        render(conn, :show,
          person: person,
          owned: owned(person),
          joins: Members.forums_of(subject),
          deletion: Members.deletion(subject),
          fresh?: fresh?(member)
        )
    end
  end

  @doc """
  SC-07: the audit log of a forum the signed-in member owns (its `owner_email` is their
  verified Idejo ID address), newest 200 entries. Anyone else: not found, whether or not the
  forum exists. Members who acted show as "a member", never by their identity.
  """
  def log(conn, %{"subdomain" => subdomain}) do
    log_page(conn, subdomain)
  end

  @doc """
  SC-10: for forum owners, what the Hub's operator can technically access, and when they
  would (`access_policy`, written by the operator in Settings). Public: an owner may read it
  before choosing this Hub.
  """
  def operator_access(conn, _params) do
    policy = IdejoHub.Settings.get("access_policy")
    paragraphs = if policy, do: String.split(policy, ~r/\R\s*\R/, trim: true), else: []
    render(conn, :operator_access, policy: paragraphs, page_title: "What the operator can access")
  end

  defp log_page(conn, subdomain) do
    with %{} = member <- member(conn),
         %{} = forum <- Enum.find(owned(person(member["sub"])), &(&1.subdomain == subdomain)) do
      render(conn, :log,
        forum: forum,
        entries: IdejoHub.Audit.recent_for_forum(forum.id)
      )
    else
      _ -> conn |> put_status(:not_found) |> put_view(IdejoHubWeb.ErrorHTML) |> render(:"404")
    end
  end

  def sign_in(conn, params) do
    case Members.account_client() do
      {:ok, {client_id, _secret}} ->
        authorize(conn, client_id, params["fresh"] == "1")

      {:error, :not_ready} ->
        conn
        |> put_flash(:error, "Idejo ID is still starting: try again in a minute.")
        |> redirect(to: ~p"/account")
    end
  end

  defp authorize(conn, client_id, fresh?) do
    request = %{
      "state" => random(),
      "nonce" => random(),
      "verifier" => random(),
      "at" => now(),
      "fresh" => fresh?
    }

    query =
      %{
        "client_id" => client_id,
        "redirect_uri" => redirect_uri(),
        "response_type" => "code",
        "scope" => "openid email profile",
        "state" => request["state"],
        "nonce" => request["nonce"],
        "code_challenge" => challenge(request["verifier"]),
        "code_challenge_method" => "S256"
      }
      |> then(&if(fresh?, do: Map.put(&1, "prompt", "login"), else: &1))

    conn
    |> put_session(@request_key, request)
    |> redirect(external: Identity.issuer() <> "/oauth/v2/authorize?" <> URI.encode_query(query))
  end

  def callback(conn, params) do
    request = get_session(conn, @request_key)
    conn = delete_session(conn, @request_key)

    returned = params["state"]

    with %{"state" => ^returned} <- request || :no_request,
         true <- now() - request["at"] <= @request_seconds || :expired,
         code when is_binary(code) <- params["code"] || :no_code,
         {:ok, {client_id, secret}} <- Members.account_client(),
         {:ok, claims} <-
           Identity.exchange_code(code, request["verifier"], redirect_uri(), client_id, secret),
         :ok <- check(claims, client_id, request["nonce"]) do
      member = %{
        "sub" => claims["sub"],
        "auth_time" => claims["auth_time"] || now(),
        "at" => now()
      }

      conn
      |> configure_session(renew: true)
      |> put_session(@member_key, member)
      |> redirect(to: ~p"/account" <> if(request["fresh"], do: "#delete", else: ""))
    else
      reason ->
        Logger.warning("ID-05: member sign-in refused: #{tag(reason)}")

        conn
        |> put_flash(:error, "Signing in did not work. Please try again.")
        |> redirect(to: ~p"/account")
    end
  end

  def sign_out(conn, _params) do
    conn |> configure_session(drop: true) |> redirect(to: ~p"/account")
  end

  def leave(conn, %{"forum_id" => forum_id} = params) do
    with %{"sub" => subject} <- member(conn) || :signed_out,
         {:ok, choice} <- choice(params),
         {id, ""} <- Integer.parse(forum_id),
         {:ok, _join} <- Members.leave(subject, id, choice) do
      message =
        if choice == :leave,
          do: "Leaving the forum. Your account there is kept for when you come back.",
          else: "Deleting your account on that forum."

      conn |> put_flash(:info, message) |> redirect(to: ~p"/account")
    else
      :signed_out -> redirect(conn, to: ~p"/account")
      {:error, :confirm} -> back(conn, "Tick the box to confirm deleting your account there.")
      {:error, :deleting} -> back(conn, "Your Idejo ID is being deleted.")
      {:error, :busy} -> back(conn, "That forum is already being left.")
      _other -> back(conn, "That forum is not one you have joined.")
    end
  end

  def delete(conn, params) do
    member = member(conn)

    cond do
      member == nil ->
        redirect(conn, to: ~p"/account")

      not fresh?(member) ->
        conn
        |> put_flash(:info, "Sign in again to confirm deleting your Idejo ID.")
        |> redirect(to: ~p"/account/sign-in?fresh=1")

      not email_matches?(member["sub"], params["email"]) ->
        back(conn, "Type your email address to confirm.")

      true ->
        case Members.delete_identity(member["sub"]) do
          {:ok, _} ->
            conn
            |> put_flash(
              :info,
              "Deleting your Idejo ID: your forum accounts first, then the ID itself."
            )
            |> redirect(to: ~p"/account")

          {:error, :deleting} ->
            back(conn, "Your Idejo ID is already being deleted.")
        end
    end
  end

  ## Helpers

  defp member(conn) do
    case get_session(conn, @member_key) do
      %{"sub" => sub, "at" => at} = member when is_binary(sub) and is_integer(at) ->
        if now() - at <= @session_seconds, do: member

      _other ->
        nil
    end
  end

  defp fresh?(%{"auth_time" => at}) when is_integer(at), do: now() - at <= @fresh_seconds
  defp fresh?(_member), do: false

  defp choice(%{"choice" => "leave"}), do: {:ok, :leave}
  defp choice(%{"choice" => "delete", "confirm" => "yes"}), do: {:ok, :delete}
  defp choice(%{"choice" => "delete"}), do: {:error, :confirm}
  defp choice(_params), do: {:error, :choice}

  defp person(subject) do
    case Identity.person(subject) do
      {:ok, person} -> person
      _unavailable -> nil
    end
  end

  # SC-07: the forums whose owner's email is this person's, once their provider has verified it.
  defp owned(%{email: email, email_verified: true}) when is_binary(email),
    do: IdejoHub.Forums.owned_by(email)

  defp owned(_person), do: []

  defp email_matches?(subject, typed) when is_binary(typed) do
    case person(subject) do
      %{email: email} when is_binary(email) ->
        String.downcase(String.trim(typed)) == String.downcase(email)

      _none ->
        false
    end
  end

  defp email_matches?(_subject, _typed), do: false

  # OpenID Connect Core 3.1.3.7: issuer, audience (and authorized party), expiry, nonce.
  defp check(claims, client_id, nonce) do
    aud = List.wrap(claims["aud"])

    [
      issuer: claims["iss"] == Identity.issuer(),
      audience: client_id in aud,
      azp: length(aud) == 1 or claims["azp"] == client_id,
      expired_token: is_integer(claims["exp"]) and claims["exp"] > now(),
      nonce: is_binary(nonce) and claims["nonce"] == nonce,
      subject: is_binary(claims["sub"]) and claims["sub"] != ""
    ]
    |> Enum.find_value(:ok, fn {failure, ok?} -> if !ok?, do: failure end)
  end

  defp back(conn, message), do: conn |> put_flash(:error, message) |> redirect(to: ~p"/account")

  defp redirect_uri, do: Identity.issuer() <> "/account/callback"

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  defp challenge(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp now, do: System.system_time(:second)

  defp tag(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp tag({:error, {tag, _}}) when is_atom(tag), do: Atom.to_string(tag)
  defp tag({:error, {tag, _, _}}) when is_atom(tag), do: Atom.to_string(tag)
  defp tag({:error, tag}) when is_atom(tag), do: Atom.to_string(tag)
  defp tag(_reason), do: "other"
end
