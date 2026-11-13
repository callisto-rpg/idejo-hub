# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.RequirementsTest do
  @moduledoc """
  Hub milestone 4's exit check (Implementation Prompt, Part B): every Must in the Hub spec
  has a passing test named after its ID: a test tagged `req: "XX-NN"` (in this repository's
  tests or docker-guard's), or a check script named after it in `deploy/test/` or
  `guard/test/`. The exceptions are listed here with their reason:

    * `@elsewhere`: the base-Idejo rows (BI), built and tested in the `idejo` repository
      under idejo's own IDs (the spec's last column);
    * `@by_review`: Musts met by a process, not code;
    * `@pending`: Musts whose test is still to come (an open pull request or a steward
      decision). Remove an ID from it when its test lands, or this test fails.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  @elsewhere %{
    "BI-01" => "idejo AD-13",
    "BI-02" => "idejo AD-14",
    "BI-03" => "idejo AD-15",
    "BI-04" => "idejo AD-09",
    "BI-05" => "idejo AD-16",
    "BI-06" => "idejo AC-09",
    "BI-07" => "idejo SP-10"
  }

  # LB-02: the licence is the steward's choice after legal review (AGPL-3.0-only for now).
  @by_review ~w(LB-02)

  # LB-04: idejo's trademark policy (LI-07) is not written yet (steward decision 2026-11-06:
  # wait for it).
  @pending ~w(LB-04)

  defp musts do
    spec = File.read!(Path.join(@root, "Idejo Hub — Spec Sheet.md"))

    for [_, id] <- Regex.scan(~r/^\| ([A-Z]{2}-\d{2}) \|.*\| (?:Must)[^|]*\|/m, spec),
        uniq: true,
        do: id
  end

  defp tested do
    tags =
      for dir <- ["test", "guard/test"],
          path <- Path.wildcard(Path.join([@root, dir, "**/*.exs"])),
          [_, id] <- Regex.scan(~r/req: "([A-Z]{2}-\d{2})"/, File.read!(path)),
          do: id

    scripts =
      for dir <- ["deploy/test", "guard/test"],
          path <- Path.wildcard(Path.join([@root, dir, "*.sh"])),
          [_, prefix, n] <- [Regex.run(~r/^([a-z]{2})_(\d{2})_/, Path.basename(path))],
          do: String.upcase(prefix) <> "-" <> n

    MapSet.new(tags ++ scripts)
  end

  test "every Must in the Hub spec has a test named after its ID" do
    musts = musts()
    # The spec's tables are read: sanity on what they hold.
    assert "FL-01" in musts and "NF-07" in musts and "BI-07" in musts
    refute "OP-06" in musts

    tested = tested()
    excused = Map.keys(@elsewhere) ++ @by_review ++ @pending
    missing = Enum.reject(musts, &(&1 in tested or &1 in excused))
    assert missing == [], "Musts without a test named after them: #{Enum.join(missing, ", ")}"
  end

  test "the exceptions are Musts, and none has a test already" do
    musts = musts()
    tested = tested()

    for id <- Map.keys(@elsewhere) ++ @by_review ++ @pending do
      assert id in musts, "#{id} is not a Must of the spec"
    end

    landed = Enum.filter(@pending ++ @by_review, &(&1 in tested))
    assert landed == [], "remove from @pending: #{Enum.join(landed, ", ")} now have tests"
  end
end
