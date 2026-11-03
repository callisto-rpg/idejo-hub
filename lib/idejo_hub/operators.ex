# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operators do
  @moduledoc """
  SC-08: Hub operators sign in with a password and a two-factor code.

  - Accounts are made from the command line only (`bin/hub-admin create-operator EMAIL`,
    `IdejoHub.Release`), with a random password shown once. There is no sign-up page.
  - Passwords: Argon2id (`argon2_elixir`, Idejo's pinned cost).
  - Two factor: TOTP (RFC 6238, 30 s, 6 digits, `nimble_totp`). The secret is stored
    encrypted (SC-04, context `"operator:<id>:totp"`). An operator without it must set it
    up, confirmed with a code, before reaching anything. A code's time step is remembered,
    so a code works once.
  - Five wrong passwords or codes in a row lock the account for 15 minutes.
  - Sessions: a random token in the encrypted session cookie, its SHA-256 in
    `operator_tokens`, valid 12 hours.
  - Sign-ins, failures and locks are audited (`operator.*`), never with a password or code.
  """

  import Ecto.Query

  alias IdejoHub.{Audit, Repo, Secrets}
  alias IdejoHub.Operators.{Operator, Token}

  @max_failures 5
  @lock_minutes 15
  @session_hours 12
  @issuer "Idejo Hub"

  ## Accounts

  @doc "Creates an operator with a random password, returned once."
  @spec create_operator(String.t()) ::
          {:ok, Operator.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_operator(email) do
    password = Secrets.random(18)

    with {:ok, operator} <-
           email |> Operator.create_changeset(Argon2.hash_pwd_salt(password)) |> Repo.insert() do
      {:ok, _} =
        Audit.record("command line", "operator.create", "ok", nil, %{"email" => operator.email})

      {:ok, operator, password}
    end
  end

  @doc "An operator by email, or nil."
  @spec get_by_email(String.t()) :: Operator.t() | nil
  def get_by_email(email),
    do: Repo.get_by(Operator, email: email |> String.trim() |> String.downcase())

  @doc "An operator by id."
  @spec get_operator!(integer()) :: Operator.t()
  def get_operator!(id), do: Repo.get!(Operator, id)

  @doc """
  Removes an operator's two-factor setup and ends their sessions: they set it up again at
  their next sign-in (for a lost phone; command line only).
  """
  @spec reset_two_factor(String.t()) :: :ok | {:error, :not_found}
  def reset_two_factor(email) do
    case get_by_email(email) do
      nil ->
        {:error, :not_found}

      operator ->
        Repo.transaction(fn ->
          operator
          |> Ecto.Changeset.change(
            totp_secret_enc: nil,
            totp_enabled_at: nil,
            totp_last_step: nil
          )
          |> Repo.update!()

          Repo.delete_all(from t in Token, where: t.operator_id == ^operator.id)

          {:ok, _} =
            Audit.record("command line", "operator.two_factor_reset", "ok", nil, %{
              "email" => operator.email
            })
        end)

        :ok
    end
  end

  ## Sign-in, first factor

  @doc """
  Checks an email and password. Unknown emails take as long as known ones. A locked account
  is refused before its password is checked.
  """
  @spec check_password(String.t(), String.t()) ::
          {:ok, Operator.t()} | {:error, :invalid | :locked}
  def check_password(email, password) when is_binary(email) and is_binary(password) do
    case get_by_email(email) do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid}

      operator ->
        cond do
          locked?(operator) -> {:error, :locked}
          Argon2.verify_pass(password, operator.hashed_password) -> {:ok, operator}
          true -> failed(operator, "password")
        end
    end
  end

  ## Second factor

  @doc "Whether the operator has two factor set up."
  @spec two_factor?(Operator.t()) :: boolean()
  def two_factor?(%Operator{totp_enabled_at: at}), do: at != nil

  @doc """
  Starts (or restarts) two-factor setup: a new secret, stored encrypted but not yet in use.
  Returns the secret in Base32 and the `otpauth://` URI for an authenticator app.
  """
  @spec begin_two_factor(Operator.t()) :: {:ok, %{secret: String.t(), uri: String.t()}}
  def begin_two_factor(%Operator{totp_enabled_at: nil} = operator) do
    secret = NimbleTOTP.secret()

    operator
    |> Ecto.Changeset.change(totp_secret_enc: Secrets.encrypt(secret, totp_context(operator)))
    |> Repo.update!()

    {:ok,
     %{
       secret: Base.encode32(secret, padding: false),
       uri: NimbleTOTP.otpauth_uri("#{@issuer}:#{operator.email}", secret, issuer: @issuer)
     }}
  end

  @doc "Ends two-factor setup with a first valid code; from then on it is required."
  @spec confirm_two_factor(Operator.t(), String.t()) ::
          {:ok, Operator.t()} | {:error, :invalid | :locked}
  def confirm_two_factor(%Operator{totp_enabled_at: nil} = operator, code) do
    with {:ok, operator} <- check_code(operator, code) do
      operator
      |> Ecto.Changeset.change(totp_enabled_at: DateTime.utc_now(:second))
      |> Repo.update()
    end
  end

  @doc "Checks a two-factor code of an operator who has it set up."
  @spec verify_two_factor(Operator.t(), String.t()) ::
          {:ok, Operator.t()} | {:error, :invalid | :locked}
  def verify_two_factor(%Operator{totp_enabled_at: %DateTime{}} = operator, code),
    do: check_code(operator, code)

  defp check_code(operator, code) do
    now = System.os_time(:second)
    step = div(now, 30)
    code = code |> to_string() |> String.replace(~r/\s/, "")

    with false <- locked?(operator),
         {:ok, secret} <- Secrets.decrypt(operator.totp_secret_enc || "", totp_context(operator)),
         true <- valid_code?(secret, code, now, operator.totp_last_step) do
      # The step the code belongs to (now, or the one before for a slow typist).
      used = if NimbleTOTP.valid?(secret, code, time: now), do: step, else: step - 1

      operator
      |> Ecto.Changeset.change(failed_attempts: 0, locked_until: nil, totp_last_step: used)
      |> Repo.update()
    else
      true -> {:error, :locked}
      _invalid -> failed(operator, "code")
    end
  end

  # The current 30 s step or the previous one, never one already used.
  defp valid_code?(secret, code, now, last_step) do
    Enum.any?([now, now - 30], fn time ->
      div(time, 30) > (last_step || -1) and NimbleTOTP.valid?(secret, code, time: time)
    end)
  end

  defp totp_context(%Operator{id: id}), do: "operator:#{id}:totp"

  ## Failures and lock

  defp locked?(%Operator{locked_until: nil}), do: false

  defp locked?(%Operator{locked_until: until}),
    do: DateTime.compare(until, DateTime.utc_now()) == :gt

  defp failed(operator, factor) do
    failures = operator.failed_attempts + 1
    lock? = failures >= @max_failures

    changes =
      if lock?,
        do: [
          failed_attempts: 0,
          locked_until: DateTime.add(DateTime.utc_now(:second), @lock_minutes, :minute)
        ],
        else: [failed_attempts: failures]

    operator |> Ecto.Changeset.change(changes) |> Repo.update!()

    {:ok, _} =
      Audit.record(operator.email, "operator.sign_in", "failed", nil, %{
        "factor" => factor,
        "locked" => lock?
      })

    {:error, if(lock?, do: :locked, else: :invalid)}
  end

  ## Sessions

  @doc "Starts a session after both factors: returns the token for the session cookie."
  @spec create_session(Operator.t()) :: binary()
  def create_session(%Operator{} = operator) do
    token = :crypto.strong_rand_bytes(32)
    Repo.insert!(%Token{operator_id: operator.id, token_hash: hash(token)})
    {:ok, _} = Audit.record(operator.email, "operator.sign_in", "ok", nil)
    token
  end

  @doc "The operator of a session token still valid, or nil."
  @spec get_operator_by_session(binary() | nil) :: Operator.t() | nil
  def get_operator_by_session(token) when is_binary(token) do
    since = DateTime.add(DateTime.utc_now(), -@session_hours, :hour)

    Repo.one(
      from o in Operator,
        join: t in Token,
        on: t.operator_id == o.id,
        where:
          t.token_hash == ^hash(token) and t.inserted_at > ^since and
            not is_nil(o.totp_enabled_at)
    )
  end

  def get_operator_by_session(_none), do: nil

  @doc "Ends a session."
  @spec delete_session(binary() | nil) :: :ok
  def delete_session(token) when is_binary(token) do
    Repo.delete_all(from t in Token, where: t.token_hash == ^hash(token))
    :ok
  end

  def delete_session(_none), do: :ok

  defp hash(token), do: :crypto.hash(:sha256, token)
end
