# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Mailer do
  @moduledoc """
  The Hub's own email (OP-08's alerts), sent through the shared SMTP server the Hub gives
  forums (`Settings.shared_smtp/0`: Settings, else `HUB_SMTP_*`), read at each send, from
  `noreply@<the Hub's host>` as "Idejo Hub". Tests use Swoosh's test adapter.
  """
  use Swoosh.Mailer, otp_app: :idejo_hub

  import Swoosh.Email

  @doc "Sends a plain-text email to `to`. `{:error, :no_smtp}` when the Hub has no SMTP server."
  @spec send_text(String.t(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def send_text(to, subject, body) do
    with {:ok, config} <- smtp_config() do
      new()
      |> to(to)
      |> from({"Idejo Hub", from_address()})
      |> subject(subject)
      |> text_body(body)
      |> deliver(config)
    end
  end

  @doc "The sender: `noreply@` the Hub's host."
  @spec from_address() :: String.t()
  def from_address, do: "noreply@" <> IdejoHubWeb.Endpoint.host()

  defp smtp_config do
    if Application.get_env(:idejo_hub, __MODULE__)[:adapter] == Swoosh.Adapters.SMTP do
      case IdejoHub.Settings.shared_smtp() do
        nil -> {:error, :no_smtp}
        smtp -> {:ok, gen_smtp(Map.new(smtp))}
      end
    else
      {:ok, []}
    end
  end

  # Idejo's rule for the port (AD-13): `tls` on 465 by default, else `starttls` on 587.
  @doc false
  # The gen_smtp options for the shared SMTP settings (public for its test).
  def gen_smtp(%{host: host} = smtp) do
    security = blank(smtp[:security]) || if(port(smtp) == 465, do: "tls", else: "starttls")
    port = port(smtp) || if(security == "tls", do: 465, else: 587)
    username = blank(smtp[:username])

    [
      relay: host,
      port: port,
      ssl: security == "tls",
      tls: if(security == "starttls", do: :always, else: :never),
      tls_options: tls_options(host),
      sockopts: if(security == "tls", do: tls_options(host), else: []),
      auth: if(username, do: :always, else: :never),
      no_mx_lookups: true,
      retries: 1
    ] ++ credentials(username, blank(smtp[:password]))
  end

  # Swoosh refuses a username key without a value: none at all without a username.
  defp credentials(nil, _password), do: []
  defp credentials(username, password), do: [username: username, password: password || ""]

  defp tls_options(host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      depth: 99,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp port(%{port: port}) when is_integer(port), do: port

  defp port(%{port: port}) when is_binary(port) and port != "",
    do: String.to_integer(String.trim(port))

  defp port(_smtp), do: nil

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
end
