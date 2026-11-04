# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.Zitadel do
  @moduledoc """
  `IdejoHub.Identity` over Zitadel's management API (v1), as the machine user `idejo-hub`
  (org owner; its token is in `:token_file`, written by Zitadel's first start). Reached
  inside the bundle at `:api_url` (`http://zitadel:8080`) with the instance's host
  (`:domain`) in `Host`, as Zitadel routes by host.

  Forums are OIDC "web" apps in one project, "Idejo forums": code flow only, client secret
  sent with HTTP Basic, the callback Idejo uses (`/users/oidc/callback`), and the user's
  email and name in the ID token (`idTokenUserinfoAssertion`), which is what Idejo reads
  (AC-09).
  """
  @behaviour IdejoHub.Identity

  alias IdejoHub.Identity

  @project "Idejo forums"

  @impl true
  def create_client(host), do: create_app(host, host, "/users/oidc/callback")

  # ID-05: the Hub's members' pages sign in like a forum, at their own callback.
  @impl true
  def create_account_client(host), do: create_app("Idejo ID account", host, "/account/callback")

  defp create_app(name, host, callback) do
    body = %{
      "name" => name,
      "redirectUris" => ["https://#{host}#{callback}"],
      "postLogoutRedirectUris" => ["https://#{host}/"],
      "responseTypes" => ["OIDC_RESPONSE_TYPE_CODE"],
      "grantTypes" => ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE"],
      "appType" => "OIDC_APP_TYPE_WEB",
      "authMethodType" => "OIDC_AUTH_METHOD_TYPE_BASIC",
      "accessTokenType" => "OIDC_TOKEN_TYPE_BEARER",
      "idTokenUserinfoAssertion" => true
    }

    with {:ok, project} <- project_id(),
         {:ok, %{"appId" => app, "clientId" => id, "clientSecret" => secret}} <-
           request(:post, "/management/v1/projects/#{project}/apps/oidc", body) do
      {:ok, %{app_id: app, client_id: id, client_secret: secret}}
    end
  end

  @impl true
  def rotate_secret(app_id) do
    with {:ok, project} <- project_id(),
         {:ok, %{"clientSecret" => secret}} <-
           request(
             :post,
             "/management/v1/projects/#{project}/apps/#{app_id}/oidc_config/_generate_client_secret",
             %{}
           ) do
      {:ok, secret}
    end
  end

  @impl true
  def delete_client(app_id) do
    with {:ok, project} <- project_id() do
      case request(:delete, "/management/v1/projects/#{project}/apps/#{app_id}", nil) do
        {:ok, _} -> :ok
        {:error, {:status, 404, _}} -> :ok
        error -> error
      end
    end
  end

  @impl true
  def create_person(person) do
    body = %{
      "username" => person.email,
      "profile" => %{
        "givenName" => person.given_name,
        "familyName" => person.family_name,
        "displayName" => person.display_name,
        "preferredLanguage" => person.language
      },
      "email" => %{"email" => person.email}
    }

    case request(:post, "/v2/users/human", body) do
      {:ok, %{"userId" => id}} ->
        {:ok, id}

      # gRPC code 6: already exists (the email or username is taken).
      {:error, {:status, 409, _}} ->
        {:error, :exists}

      {:error, {:status, _, message}} = error ->
        if message =~ ~r/already exists/i, do: {:error, :exists}, else: error

      error ->
        error
    end
  end

  # Zitadel's invite: verify the email, then choose a password or a passkey, on its login pages.
  @impl true
  def send_invite(user_id) do
    template =
      "https://#{Identity.config(:domain)}/ui/v2/login/verify" <>
        "?code={{.Code}}&userId={{.UserID}}&organization={{.OrgID}}&invite=true"

    with {:ok, _} <-
           request(:post, "/v2/users/#{user_id}/invite_code", %{
             "sendCode" => %{"urlTemplate" => template, "applicationName" => Identity.label()}
           }),
         do: :ok
  end

  @impl true
  def configure(smtp, sender) do
    with :ok <- login_policy(), do: smtp(smtp, sender)
  end

  # ID-02: only the Hub's sign-up page makes people (Zitadel's own form off); ID-08: passkeys
  # allowed, one-time codes and security keys as second factors.
  defp login_policy do
    wanted = %{"allowRegister" => false, "passwordlessType" => "PASSWORDLESS_TYPE_ALLOWED"}

    with {:ok, %{"policy" => policy}} <- request(:get, "/admin/v1/policies/login", nil),
         :ok <- put_policy_if_needed(policy, wanted) do
      factors(policy)
    end
  end

  # Zitadel's JSON leaves out false booleans: a missing field is false.
  defp put_policy_if_needed(policy, wanted) do
    current = Map.new(wanted, fn {key, _} -> {key, Map.get(policy, key, false)} end)
    if current == wanted, do: :ok, else: put_policy(policy, wanted)
  end

  @policy_fields ~w(allowUsernamePassword allowRegister allowExternalIdp forceMfa passwordlessType
                    hidePasswordReset ignoreUnknownUsernames defaultRedirectUri passwordCheckLifetime
                    externalLoginCheckLifetime mfaInitSkipLifetime secondFactorCheckLifetime
                    multiFactorCheckLifetime allowDomainDiscovery disableLoginWithEmail
                    disableLoginWithPhone forceMfaLocalOnly)

  defp put_policy(policy, wanted) do
    body = policy |> Map.take(@policy_fields) |> Map.merge(wanted)
    with {:ok, _} <- request(:put, "/admin/v1/policies/login", body), do: :ok
  end

  defp factors(policy) do
    second = policy["secondFactors"] || []

    ["SECOND_FACTOR_TYPE_OTP", "SECOND_FACTOR_TYPE_U2F"]
    |> Enum.reject(&(&1 in second))
    |> Enum.reduce_while(:ok, fn type, :ok ->
      case request(:post, "/admin/v1/policies/login/second_factors", %{"type" => type}) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @description "Idejo Hub"

  # Zitadel sends invites through the Hub's SMTP (Settings or HUB_SMTP_*): its configuration
  # named "Idejo Hub" is replaced when it differs, and removed when the Hub has none.
  defp smtp(smtp, sender) do
    with {:ok, existing} <- request(:post, "/admin/v1/smtp/_search", %{}) do
      ours = for c <- existing["result"] || [], c["description"] == @description, do: c
      wanted = smtp && smtp_body(smtp, sender)

      if up_to_date?(ours, wanted), do: :ok, else: replace_smtp(ours, wanted)
    end
  end

  defp up_to_date?([], nil), do: true
  defp up_to_date?([current], wanted) when is_map(wanted), do: same?(current, wanted)
  defp up_to_date?(_ours, _wanted), do: false

  defp smtp_body(smtp, sender) do
    port = smtp[:port] |> to_string() |> then(&if(&1 == "", do: "587", else: &1))

    %{
      "description" => @description,
      "senderAddress" => sender,
      "senderName" => Identity.label(),
      "tls" => smtp[:security] in [nil, "", "tls", "starttls"],
      "host" => "#{smtp[:host]}:#{port}",
      "user" => to_string(smtp[:username] || ""),
      "password" => to_string(smtp[:password] || "")
    }
  end

  # Zitadel never returns the password: compare the rest.
  defp same?(current, wanted) do
    Map.take(current, ~w(senderAddress senderName tls host user)) ==
      Map.take(wanted, ~w(senderAddress senderName tls host user)) and
      current["state"] == "SMTP_CONFIG_ACTIVE"
  end

  defp replace_smtp(ours, wanted) do
    for c <- ours, do: request(:delete, "/admin/v1/smtp/#{c["id"]}", nil)

    if wanted do
      with {:ok, %{"id" => id}} <- request(:post, "/admin/v1/smtp", wanted),
           {:ok, _} <- request(:post, "/admin/v1/smtp/#{id}/_activate", %{}),
           do: :ok
    else
      :ok
    end
  end

  # ID-05: each sign-in to a client is an `oidc_session.added` event naming the user and the
  # client; read from the instance's event store, oldest first, a page at a time.
  @impl true
  def sign_ins_since(since) do
    body = %{
      "limit" => 1000,
      "asc" => true,
      "eventTypes" => ["oidc_session.added"]
    }

    body =
      if since,
        do: Map.put(body, "creationDateRange", %{"since" => DateTime.to_iso8601(since)}),
        else: body

    with {:ok, result} <- request(:post, "/admin/v1/events/_search", body) do
      {:ok, Enum.flat_map(result["events"] || [], &sign_in/1)}
    end
  end

  defp sign_in(%{"payload" => %{"userID" => user, "clientID" => client}, "creationDate" => date}) do
    case DateTime.from_iso8601(date) do
      {:ok, at, _offset} -> [%{user_id: user, client_id: client, at: at}]
      _bad -> []
    end
  end

  defp sign_in(_other), do: []

  @impl true
  def person(user_id) do
    case request(:get, "/v2/users/#{user_id}", nil) do
      {:ok, %{"user" => %{"human" => human}}} ->
        {:ok,
         %{
           email: get_in(human, ["email", "email"]),
           display_name: get_in(human, ["profile", "displayName"])
         }}

      {:ok, _machine} ->
        {:error, :not_found}

      {:error, {:status, 404, _}} ->
        {:error, :not_found}

      error ->
        error
    end
  end

  @impl true
  def delete_person(user_id) do
    case request(:delete, "/v2/users/#{user_id}", nil) do
      {:ok, _} -> :ok
      {:error, {:status, 404, _}} -> :ok
      error -> error
    end
  end

  # The token endpoint, reached inside the bundle like the API: the ID token comes straight
  # from the provider over the bundle's own network, so its claims are checked by the caller
  # (issuer, audience, expiry, nonce) without fetching keys (OpenID Connect Core 3.1.3.7).
  @impl true
  def exchange_code(code, verifier, redirect_uri, client_id, secret) do
    opts =
      [
        method: :post,
        url: Identity.config(:api_url) <> "/oauth/v2/token",
        headers: [{"host", Identity.config(:domain)}],
        auth: {:basic, client_id <> ":" <> secret},
        form: [
          grant_type: "authorization_code",
          code: code,
          redirect_uri: redirect_uri,
          code_verifier: verifier
        ],
        retry: false,
        receive_timeout: 15_000
      ] ++ Application.get_env(:idejo_hub, :zitadel_req_options, [])

    case Req.request(opts) do
      {:ok, %Req.Response{status: 200, body: %{"id_token" => token}}} -> decode(token)
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status, "token"}}
      {:error, exception} -> {:error, {:unreachable, Exception.message(exception)}}
    end
  end

  defp decode(token) do
    with [_header, payload, _signature] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} when is_map(claims) <- Jason.decode(json) do
      {:ok, claims}
    else
      _bad -> {:error, :bad_token}
    end
  end

  # The forums' project, found by name, made the first time.
  defp project_id do
    query = %{
      "queries" => [
        %{"nameQuery" => %{"name" => @project, "method" => "TEXT_QUERY_METHOD_EQUALS"}}
      ]
    }

    case request(:post, "/management/v1/projects/_search", query) do
      {:ok, %{"result" => [%{"id" => id} | _]}} ->
        {:ok, id}

      {:ok, _none} ->
        with {:ok, %{"id" => id}} <-
               request(:post, "/management/v1/projects", %{"name" => @project}),
             do: {:ok, id}

      error ->
        error
    end
  end

  defp request(method, path, body) do
    with {:ok, token} <- token() do
      opts =
        [
          method: method,
          url: Identity.config(:api_url) <> path,
          headers: [{"host", Identity.config(:domain)}, {"authorization", "Bearer " <> token}],
          retry: false,
          receive_timeout: 15_000
        ] ++
          if(body, do: [json: body], else: []) ++
          Application.get_env(:idejo_hub, :zitadel_req_options, [])

      case Req.request(opts) do
        {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:status, status, message(body)}}

        {:error, exception} ->
          {:error, {:unreachable, Exception.message(exception)}}
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp token do
    case File.read(Identity.config(:token_file) || "") do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, _} -> {:error, :no_token}
    end
  end

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(_body), do: ""
end
