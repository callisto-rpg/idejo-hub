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
  - A forgotten password: a single-use link by email, 30 minutes (`request_password_reset/2`,
    `reset_password/3`). It changes the password only; two factor is still asked. A lost
    phone: an owner, or the command line, resets two factor (`reset_two_factor/1,2`).
  """

  import Ecto.Query

  alias IdejoHub.{Audit, Repo, Secrets}
  alias IdejoHub.Operators.{Operator, Token}

  @max_failures 5
  @lock_minutes 15
  @session_hours 12
  @issuer "Idejo Hub"

  ## Accounts

  @doc """
  Creates an operator with a random password, returned once. HA-07: `role` is `"owner"` or
  `"operator"`; nil makes an owner while there is none (the first account), else an
  operator. `actor` is who made it: the command line, or an owner's email.
  """
  @spec create_operator(String.t(), String.t() | nil, String.t()) ::
          {:ok, Operator.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_operator(email, role \\ nil, actor \\ "command line") do
    password = Secrets.random(18)
    role = role || if(owner_count() == 0, do: "owner", else: "operator")

    with {:ok, operator} <-
           email
           |> Operator.create_changeset(Argon2.hash_pwd_salt(password), role)
           |> Repo.insert() do
      {:ok, _} =
        Audit.record(actor, "operator.create", "ok", nil, %{
          "email" => operator.email,
          "role" => operator.role
        })

      {:ok, operator, password}
    end
  end

  @doc "HA-07: every operator account, owners first, then by email."
  @spec list_operators() :: [Operator.t()]
  def list_operators do
    Repo.all(from o in Operator, order_by: [desc: o.role == "owner", asc: o.email])
  end

  @doc "HA-07: whether the operator may manage operator accounts."
  @spec owner?(Operator.t() | nil) :: boolean()
  def owner?(%Operator{role: "owner"}), do: true
  def owner?(_operator), do: false

  @doc """
  HA-07: an owner changes an account's role. The last owner stays an owner, so someone can
  always manage accounts. Audited `operator.role`.
  """
  @spec set_role(Operator.t(), String.t(), Operator.t()) ::
          {:ok, Operator.t()}
          | {:error, :forbidden | :invalid_role | :last_owner | Ecto.Changeset.t()}
  def set_role(%Operator{} = operator, role, %Operator{} = by) do
    cond do
      not owner?(by) ->
        {:error, :forbidden}

      role not in Operator.roles() ->
        {:error, :invalid_role}

      operator.role == "owner" and role != "owner" and owner_count() == 1 ->
        {:error, :last_owner}

      true ->
        with {:ok, changed} <- operator |> Ecto.Changeset.change(role: role) |> Repo.update() do
          {:ok, _} =
            Audit.record(by.email, "operator.role", "ok", nil, %{
              "email" => changed.email,
              "role" => role
            })

          {:ok, changed}
        end
    end
  end

  @doc """
  HA-07: an owner removes an operator account, ending its sessions. Never the last owner,
  nor their own account. Audited `operator.remove`.
  """
  @spec remove_operator(Operator.t(), Operator.t()) ::
          :ok | {:error, :forbidden | :last_owner | :self}
  def remove_operator(%Operator{} = operator, %Operator{} = by) do
    cond do
      not owner?(by) ->
        {:error, :forbidden}

      operator.id == by.id ->
        {:error, :self}

      operator.role == "owner" and owner_count() == 1 ->
        {:error, :last_owner}

      true ->
        # Its session tokens go with it (on delete cascade).
        Repo.delete!(operator)

        {:ok, _} =
          Audit.record(by.email, "operator.remove", "ok", nil, %{"email" => operator.email})

        :ok
    end
  end

  defp owner_count, do: Repo.aggregate(from(o in Operator, where: o.role == "owner"), :count)

  @doc "An operator by email, or nil."
  @spec get_by_email(String.t()) :: Operator.t() | nil
  def get_by_email(email),
    do: Repo.get_by(Operator, email: email |> String.trim() |> String.downcase())

  @doc "An operator by id."
  @spec get_operator!(integer()) :: Operator.t()
  def get_operator!(id), do: Repo.get!(Operator, id)

  @doc """
  Removes an operator's two-factor setup and ends their sessions: they set it up again at
  their next sign-in (for a lost phone). From the command line by email, or by an owner on
  the Operators page (`reset_two_factor(operator, by)`), never on their own account.
  """
  @spec reset_two_factor(String.t()) :: :ok | {:error, :not_found}
  def reset_two_factor(email) when is_binary(email) do
    case get_by_email(email) do
      nil -> {:error, :not_found}
      operator -> do_reset_two_factor(operator, "command line")
    end
  end

  @spec reset_two_factor(Operator.t(), Operator.t()) :: :ok | {:error, :forbidden | :self}
  def reset_two_factor(%Operator{} = operator, %Operator{} = by) do
    cond do
      not owner?(by) -> {:error, :forbidden}
      operator.id == by.id -> {:error, :self}
      true -> do_reset_two_factor(operator, by.email)
    end
  end

  defp do_reset_two_factor(operator, actor) do
    Repo.transaction(fn ->
      operator
      |> Ecto.Changeset.change(totp_secret_enc: nil, totp_enabled_at: nil, totp_last_step: nil)
      |> Repo.update!()

      end_sessions(operator)

      {:ok, _} =
        Audit.record(actor, "operator.two_factor_reset", "ok", nil, %{"email" => operator.email})
    end)

    :ok
  end

  defp end_sessions(operator),
    do: Repo.delete_all(from t in Token, where: t.operator_id == ^operator.id)

  ## Password reset by email

  @reset_minutes 30
  @min_password 12
  @max_password 200

  @doc "SC-08: how long a password-reset link works, in minutes."
  def reset_minutes, do: @reset_minutes

  @doc "SC-08: the shortest password an operator may choose."
  def min_password, do: @min_password

  @doc """
  SC-08: emails a password-reset link to the operator with `email`, if there is one. The
  link is `link.(token)`; only the token's SHA-256 is stored, and a new request replaces the
  previous link. Answers `:ok` whether the email exists or not, so the page says the same
  thing either way; `{:error, :no_smtp}` only when the Hub has no email server at all.
  Audited `operator.password_reset` `requested` (never the token).
  """
  @spec request_password_reset(String.t(), (String.t() -> String.t())) ::
          :ok | {:error, :no_smtp}
  def request_password_reset(email, link) when is_binary(email) and is_function(link, 1) do
    if IdejoHub.Mailer.configured?() do
      case get_by_email(email) do
        nil -> :ok
        operator -> send_reset(operator, link)
      end
    else
      {:error, :no_smtp}
    end
  end

  defp send_reset(operator, link) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    operator
    |> Ecto.Changeset.change(reset_token_hash: hash(token), reset_sent_at: now())
    |> Repo.update!()

    body = """
    Someone asked to reset the password of the Idejo Hub operator account #{operator.email}.

    To choose a new password, open this link within #{@reset_minutes} minutes:

    #{link.(token)}

    The link works once. Your two-factor code is still asked at sign-in.

    If you did not ask for this, ignore this email: your password stays as it is.
    """

    outcome =
      case IdejoHub.Mailer.send_text(operator.email, "[Idejo Hub] Reset your password", body) do
        {:ok, _} -> "requested"
        {:error, _} -> "failed"
      end

    {:ok, _} = Audit.record(operator.email, "operator.password_reset", outcome, nil)
    :ok
  end

  @doc "SC-08: the operator a password-reset token belongs to, while it still works, or nil."
  @spec get_operator_by_reset_token(String.t()) :: Operator.t() | nil
  def get_operator_by_reset_token(token) when is_binary(token) and token != "",
    do: Repo.one(reset_query(token))

  def get_operator_by_reset_token(_token), do: nil

  defp reset_query(token) do
    since = DateTime.add(DateTime.utc_now(), -@reset_minutes, :minute)
    from o in Operator, where: o.reset_token_hash == ^hash(token) and o.reset_sent_at > ^since
  end

  @doc """
  SC-08: sets a new password with a password-reset token. The token is used up, every
  session ends, and two-factor stays as it was (still asked at sign-in); a lock is not
  lifted. Audited `operator.password_reset` `ok`.
  """
  @spec reset_password(String.t(), String.t(), String.t()) ::
          {:ok, Operator.t()} | {:error, :expired | :too_short | :too_long | :mismatch}
  def reset_password(token, password, confirmation)
      when is_binary(password) and is_binary(confirmation) do
    cond do
      String.length(password) < @min_password -> {:error, :too_short}
      String.length(password) > @max_password -> {:error, :too_long}
      password != confirmation -> {:error, :mismatch}
      true -> do_reset_password(token, password)
    end
  end

  defp do_reset_password(token, password) do
    Repo.transaction(fn ->
      # Locked: a second use of the same link waits, then finds the token gone.
      case Repo.one(token |> reset_query() |> lock("FOR UPDATE")) do
        nil ->
          Repo.rollback(:expired)

        operator ->
          changed =
            operator
            |> Ecto.Changeset.change(
              hashed_password: Argon2.hash_pwd_salt(password),
              reset_token_hash: nil,
              reset_sent_at: nil
            )
            |> Repo.update!()

          end_sessions(changed)
          {:ok, _} = Audit.record(changed.email, "operator.password_reset", "ok", nil)
          changed
      end
    end)
  end

  defp now, do: DateTime.utc_now(:second)

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
