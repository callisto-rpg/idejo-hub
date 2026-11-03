# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Secrets do
  @moduledoc """
  SC-04: each forum has its own secrets (`SECRET_KEY_BASE`, database password), generated
  here and stored only encrypted in the Hub database.

  Encryption is AES-256-GCM (Erlang `:crypto`, no extra dependency) with the key from
  `HUB_SECRETS_KEY`. Every value is bound to a *context* such as `"forum:tennis:db_password"`
  (GCM associated data): a ciphertext copied to another forum's row, or another field, fails
  to decrypt instead of handing one forum's secret to another.

  Stored format: `<<1, key_id, iv::12 bytes, tag::16 bytes, ciphertext>>`. The key id leaves
  room for key rotation later; today there is one key, id 1.

  Plain secrets never go to logs, audit entries or error messages (CLAUDE.md, Conventions).
  """

  @format 1
  @key_id 1
  @iv_bytes 12
  @tag_bytes 16

  @doc "A new `SECRET_KEY_BASE` for a forum: 64 random bytes, Base64url (86 characters)."
  @spec new_secret_key_base() :: String.t()
  def new_secret_key_base, do: random(64)

  @doc "`bytes` random bytes, Base64url without padding (safe in URLs and SQL literals)."
  @spec random(pos_integer()) :: String.t()
  def random(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  @doc "Encrypts `plaintext` for `context`, with a fresh random IV."
  @spec encrypt(binary(), String.t()) :: binary()
  def encrypt(plaintext, context) when is_binary(plaintext) and is_binary(context) do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key(@key_id),
        iv,
        plaintext,
        aad(context),
        @tag_bytes,
        true
      )

    <<@format, @key_id, iv::binary, tag::binary, ciphertext::binary>>
  end

  @doc """
  Decrypts a value stored by `encrypt/2` for the same `context`. Any mismatch (other context,
  other key, altered bytes) is `{:error, :invalid}`, with no detail.
  """
  @spec decrypt(binary(), String.t()) :: {:ok, binary()} | {:error, :invalid}
  def decrypt(
        <<@format, key_id, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>,
        context
      )
      when is_binary(context) do
    with {:ok, key} <- fetch_key(key_id),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             aad(context),
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      _error -> {:error, :invalid}
    end
  end

  def decrypt(_stored, _context), do: {:error, :invalid}

  @doc """
  Checks the configured key (32 bytes). Called at boot, so a missing or malformed
  `HUB_SECRETS_KEY` stops the Hub instead of failing at the first forum.
  """
  @spec validate_key!() :: :ok
  def validate_key! do
    case fetch_key(@key_id) do
      {:ok, _key} ->
        :ok

      :error ->
        raise ArgumentError,
              "HUB_SECRETS_KEY must be 32 bytes, Base64-encoded (openssl rand -base64 32)"
    end
  end

  # The format version is part of the associated data, so it cannot be changed either.
  defp aad(context), do: "idejo-hub/v#{@format}/" <> context

  defp key(id) do
    {:ok, key} = fetch_key(id)
    key
  end

  defp fetch_key(@key_id) do
    with encoded when is_binary(encoded) <- Application.get_env(:idejo_hub, __MODULE__)[:key],
         {:ok, <<key::binary-size(32)>>} <- Base.decode64(encoded) do
      {:ok, key}
    else
      _missing_or_invalid -> :error
    end
  end

  defp fetch_key(_unknown), do: :error
end
