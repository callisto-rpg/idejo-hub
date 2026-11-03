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
  def create_client(host) do
    body = %{
      "name" => host,
      "redirectUris" => ["https://#{host}/users/oidc/callback"],
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
