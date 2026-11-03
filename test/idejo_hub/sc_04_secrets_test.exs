# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.SC04SecretsTest do
  @moduledoc "SC-04: per-forum secrets, generated fresh and stored only encrypted."
  use ExUnit.Case, async: false

  alias IdejoHub.Secrets

  @moduletag req: "SC-04"

  test "a value round-trips for its own context" do
    stored = Secrets.encrypt("s3cret", "forum:tennis:db_password")
    assert Secrets.decrypt(stored, "forum:tennis:db_password") == {:ok, "s3cret"}
    refute stored =~ "s3cret"
  end

  test "the same value encrypts differently every time" do
    a = Secrets.encrypt("s3cret", "forum:tennis:db_password")
    b = Secrets.encrypt("s3cret", "forum:tennis:db_password")
    assert a != b
  end

  test "a secret copied to another forum or field does not decrypt" do
    stored = Secrets.encrypt("s3cret", "forum:tennis:db_password")
    assert Secrets.decrypt(stored, "forum:chess:db_password") == {:error, :invalid}
    assert Secrets.decrypt(stored, "forum:tennis:secret_key_base") == {:error, :invalid}
  end

  test "altered or foreign bytes do not decrypt" do
    <<head::binary-size(30), byte, rest::binary>> = Secrets.encrypt("s3cret", "ctx")
    assert Secrets.decrypt(head <> <<Bitwise.bxor(byte, 1)>> <> rest, "ctx") == {:error, :invalid}
    assert Secrets.decrypt("plain text", "ctx") == {:error, :invalid}
    <<format, _key_id, tail::binary>> = Secrets.encrypt("s3cret", "ctx")
    assert Secrets.decrypt(<<format, 9>> <> tail, "ctx") == {:error, :invalid}
  end

  test "a different key cannot read stored values" do
    stored = Secrets.encrypt("s3cret", "ctx")
    original = Application.get_env(:idejo_hub, Secrets)

    try do
      Application.put_env(:idejo_hub, Secrets, key: Base.encode64(:crypto.strong_rand_bytes(32)))
      assert Secrets.decrypt(stored, "ctx") == {:error, :invalid}
    after
      Application.put_env(:idejo_hub, Secrets, original)
    end
  end

  test "a missing or short key stops the Hub at boot" do
    original = Application.get_env(:idejo_hub, Secrets)

    try do
      Application.put_env(:idejo_hub, Secrets, key: Base.encode64("too short"))
      assert_raise ArgumentError, ~r/HUB_SECRETS_KEY/, &Secrets.validate_key!/0
      Application.put_env(:idejo_hub, Secrets, key: nil)
      assert_raise ArgumentError, ~r/HUB_SECRETS_KEY/, &Secrets.validate_key!/0
    after
      Application.put_env(:idejo_hub, Secrets, original)
    end

    assert Secrets.validate_key!() == :ok
  end

  test "every forum gets its own fresh SECRET_KEY_BASE" do
    a = Secrets.new_secret_key_base()
    b = Secrets.new_secret_key_base()
    assert a != b
    # Phoenix requires at least 64 characters.
    assert String.length(a) >= 64
  end
end
