# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.SC03CustomCSSTest do
  @moduledoc """
  SC-03: custom CSS (Idejo AD-11) is sanitised, and third-party scripts stay forbidden. A
  forum's stylesheet is its own setting, never read or written by the Hub; Idejo checks it
  from 0.2.2 on. The Hub's part: new forums start on 0.2.2 or later, wherever the default is
  set.
  """
  use ExUnit.Case, async: true

  @moduletag req: "SC-03"

  @first "0.2.2"

  test "SC-03 new forums start on an Idejo that checks its stylesheet" do
    config = Config.Reader.read!("config/config.exs", env: :prod)
    defaults = [config[:idejo_hub][IdejoHub.Forums][:default_version]]

    defaults =
      defaults ++
        for {file, pattern} <- [
              {"config/runtime.exs", ~r/"IDEJO_DEFAULT_VERSION", "([0-9.]+)"/},
              {"deploy/docker-compose.yml", ~r/IDEJO_DEFAULT_VERSION:-([0-9.]+)/},
              {"deploy/.env.example", ~r/\(default ([0-9.]+)\)/}
            ] do
          [_, version] = Regex.run(pattern, File.read!(file))
          version
        end

    for version <- defaults do
      assert Version.compare(version, @first) != :lt, "#{version} is before #{@first}"
    end

    # The same default everywhere.
    assert length(Enum.uniq(defaults)) == 1
  end
end
