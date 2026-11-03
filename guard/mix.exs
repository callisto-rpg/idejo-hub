# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule DockerGuard.MixProject do
  use Mix.Project

  # docker-guard (HN-04): the body-checking proxy between the Hub and the Docker socket proxy.
  # A separate release from this repository (steward decision 2026-11-03), built by
  # guard/Dockerfile, so a compromised Hub cannot change its rules.
  def project do
    [
      app: :docker_guard,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      dialyzer: [plt_local_path: "priv/plts"],
      releases: [docker_guard: [steps: [:assemble, &copy_licence/1]]]
    ]
  end

  @licence_files ~w(LICENSE NOTICE LICENSES)

  # LI-01: the licence text and the NOTICE ship with the release, at its root.
  @doc false
  def copy_licence(%Mix.Release{path: path} = release) do
    for file <- @licence_files, do: File.cp_r!(Path.join("..", file), Path.join(path, file))
    release
  end

  def application do
    [mod: {DockerGuard.Application, []}, extra_applications: [:logger]]
  end

  def cli, do: [preferred_envs: [precommit: :test]]

  defp deps do
    [
      {:bandit, "~> 1.14 and >= 1.14.1"},
      {:plug, "~> 1.18"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "deps.audit",
        "cmd mix hex.audit",
        "test --warnings-as-errors",
        "cmd env MIX_ENV=dev mix dialyzer"
      ]
    ]
  end
end
