# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.SC08OperatorsTest do
  @moduledoc "SC-08: operator accounts, password, two-factor codes, lock, sessions."
  use IdejoHub.DataCase, async: true

  import IdejoHub.OperatorFixtures

  alias IdejoHub.{Audit, Operators}

  @moduletag req: "SC-08"

  test "an operator is made with a random password, stored only as an Argon2id hash" do
    {operator, password} = operator_fixture("Ops@Hub.Idejo.Test ")
    assert operator.email == "ops@hub.idejo.test"
    assert String.length(password) >= 20
    assert operator.hashed_password =~ "$argon2id$"
    refute operator.hashed_password =~ password
    assert {:error, %Ecto.Changeset{}} = Operators.create_operator("ops@hub.idejo.test")
  end

  test "the password is checked, and unknown emails get the same answer" do
    {operator, password} = operator_fixture()
    assert {:ok, _} = Operators.check_password(operator.email, password)
    assert Operators.check_password(operator.email, "wrong") == {:error, :invalid}
    assert Operators.check_password("nobody@hub.idejo.test", password) == {:error, :invalid}
  end

  test "five failures lock the account for 15 minutes, even for the right password" do
    {operator, password} = operator_fixture()

    for _ <- 1..4,
        do: assert(Operators.check_password(operator.email, "wrong") == {:error, :invalid})

    assert Operators.check_password(operator.email, "wrong") == {:error, :locked}
    assert Operators.check_password(operator.email, password) == {:error, :locked}

    locked = Operators.get_operator!(operator.id)
    assert_in_delta DateTime.diff(locked.locked_until, DateTime.utc_now(), :minute), 15, 1

    entries = Enum.filter(IdejoHub.Repo.all(Audit.Entry), &(&1.action == "operator.sign_in"))
    assert Enum.any?(entries, &(&1.details["locked"] == true))
    refute Enum.any?(entries, &(inspect(&1.details) =~ "wrong"))
  end

  test "two factor: a secret stored encrypted, confirmed by a first code" do
    {operator, _} = operator_fixture()
    refute Operators.two_factor?(operator)

    {:ok, %{secret: secret, uri: uri}} = Operators.begin_two_factor(operator)
    assert uri =~ "otpauth://totp/"
    assert uri =~ "issuer=idejo"
    stored = Operators.get_operator!(operator.id)
    refute stored.totp_secret_enc =~ Base.decode32!(secret, padding: false)

    assert Operators.confirm_two_factor(stored, "abcdef") == {:error, :invalid}

    assert {:ok, enabled} =
             Operators.confirm_two_factor(
               Operators.get_operator!(operator.id),
               totp_code(operator)
             )

    assert Operators.two_factor?(enabled)
  end

  test "a code works once, and the previous 30 s step is still accepted" do
    {operator, _} = operator_fixture()
    {:ok, _} = Operators.begin_two_factor(operator)
    now = System.os_time(:second)

    {:ok, operator} =
      Operators.confirm_two_factor(
        Operators.get_operator!(operator.id),
        totp_code(operator, now - 30)
      )

    code = totp_code(operator, now)
    assert {:ok, operator} = Operators.verify_two_factor(operator, code)
    assert Operators.verify_two_factor(operator, code) == {:error, :invalid}
  end

  test "sessions: valid until signed out; only a hash is stored" do
    {operator, _} = operator_fixture()
    {:ok, _} = Operators.begin_two_factor(operator)

    {:ok, operator} =
      Operators.confirm_two_factor(Operators.get_operator!(operator.id), totp_code(operator))

    token = Operators.create_session(operator)
    assert Operators.get_operator_by_session(token).id == operator.id
    refute IdejoHub.Repo.one!(IdejoHub.Operators.Token).token_hash == token

    :ok = Operators.delete_session(token)
    assert Operators.get_operator_by_session(token) == nil
  end

  test "resetting two factor ends the sessions; setup is needed again" do
    {operator, _} = operator_fixture()
    {:ok, _} = Operators.begin_two_factor(operator)

    {:ok, operator} =
      Operators.confirm_two_factor(Operators.get_operator!(operator.id), totp_code(operator))

    token = Operators.create_session(operator)

    assert Operators.reset_two_factor(operator.email) == :ok
    assert Operators.get_operator_by_session(token) == nil
    refute Operators.two_factor?(Operators.get_operator!(operator.id))
    assert Operators.reset_two_factor("nobody@hub.idejo.test") == {:error, :not_found}
  end
end
