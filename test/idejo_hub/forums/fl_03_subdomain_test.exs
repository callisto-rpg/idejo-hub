# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.FL03SubdomainTest do
  @moduledoc "FL-03: subdomain rules."
  use ExUnit.Case, async: true

  alias IdejoHub.Forums.Subdomain

  @moduletag req: "FL-03"

  test "lowercase letters, digits and hyphens, 3 to 32 characters" do
    for ok <- ["abc", "tennis-club", "club42", "a1b", String.duplicate("a", 32)] do
      assert Subdomain.validate(ok) == :ok, ok
    end
  end

  test "length" do
    assert {:error, _} = Subdomain.validate("ab")
    assert {:error, _} = Subdomain.validate(String.duplicate("a", 33))
  end

  test "characters and shape" do
    for bad <- [
          "Tennis",
          "tennis_club",
          "tennis.club",
          "tennis club",
          "-tennis",
          "tennis-",
          "été",
          "xn--ls8h",
          "a--b"
        ] do
      assert {:error, _} = Subdomain.validate(bad), bad
    end

    assert {:error, _} = Subdomain.validate(nil)
  end

  test "reserved names" do
    for name <- ["hub", "www", "admin", "mail", "api", "status", "identity", "autodiscover"] do
      assert Subdomain.validate(name) == {:error, "is reserved"}, name
    end
  end

  test "every valid subdomain is a name docker-guard accepts" do
    # DockerGuard.Policy's slug rule (HN-04).
    guard = ~r/\A[a-z0-9][a-z0-9-]{1,30}[a-z0-9]\z/

    for ok <- ["abc", "tennis-club", String.duplicate("z", 32)],
        do: assert(Regex.match?(guard, ok))
  end

  test "as a changeset rule" do
    types = %{subdomain: :string}

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(%{subdomain: "www"}, [:subdomain])
      |> Subdomain.validate_subdomain(:subdomain)

    assert changeset.errors == [subdomain: {"is reserved", []}]
  end
end
