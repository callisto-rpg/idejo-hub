# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.HA08CLITest do
  @moduledoc """
  HA-08: the Hub's command line mirrors the main actions (create, back up, upgrade, suspend,
  resume, list) for scripting and recovery: each waits for its end and says how it went.
  """
  use IdejoHub.DataCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import ExUnit.CaptureIO
  import Plug.Conn

  alias IdejoHub.{Audit, CLI, Forums}
  alias IdejoHub.Forums.Export
  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Hosting.Postgres

  @moduletag req: "HA-08"
  @moduletag :capture_log

  @admin "/app/bin/idejo-admin"
  @script Path.expand("../../rel/overlays/bin/hub-admin", __DIR__)

  setup do
    Fake.start()
    Req.Test.stub(IdejoHub.Hosting.Health, &send_resp(&1, 200, "{}"))
    File.rm_rf!(Export.dir())
    on_exit(fn -> Postgres.drop("ha08-cli") end)

    Fake.exec_result(
      [@admin, "backup"],
      {:ok,
       %{exit_code: 0, output: "Backup written to /data/backups/idejo-20261106-170000.tar\n"}}
    )

    Fake.put_file("/data/backups/idejo-20261106-170000.tar", "backup")
    :ok
  end

  # Runs a command as the running Hub would: its jobs run while it waits.
  defp run(fun) do
    task = Task.async(fn -> fun.(timeout: 20_000, poll: 20) end)
    drain_until(task)
  end

  defp drain_until(task) do
    Oban.drain_queue(queue: :lifecycle)
    Oban.drain_queue(queue: :operations)

    case Task.yield(task, 50) do
      {:ok, result} -> result
      nil -> drain_until(task)
    end
  end

  test "HA-08 create, back up, suspend, resume and upgrade a forum, each waiting for its end" do
    assert {:ok, "ha08-cli created"} =
             run(&CLI.create("ha08-cli", "Club", "owner@ha08.test", &1))

    assert Forums.get_by_subdomain("ha08-cli").status == "running"
    assert CLI.list() == ["ha08-cli\trunning\t0.1.0\t-"]

    assert {:ok, "ha08-cli backed up"} = run(&CLI.backup("ha08-cli", &1))
    assert {:ok, "ha08-cli suspended"} = run(&CLI.suspend("ha08-cli", &1))
    assert Forums.get_by_subdomain("ha08-cli").status == "suspended"
    assert {:ok, "ha08-cli resumed"} = run(&CLI.resume("ha08-cli", &1))
    assert {:ok, "ha08-cli upgraded to 0.2.0"} = run(&CLI.upgrade("ha08-cli", "0.2.0", &1))
    assert Forums.get_by_subdomain("ha08-cli").idejo_version == "0.2.0"

    # As the command line, in the audit log.
    actors = Repo.all(from e in Audit.Entry, where: e.subdomain == "ha08-cli", select: e.actor)
    assert Enum.uniq(actors) == ["command line"]
  end

  test "HA-08 refusals and failures say why, with a code a script can test" do
    assert {:error, "No forum is called nope.", 2} = CLI.backup("nope")
    assert {:error, "Not created: subdomain is reserved", 1} = CLI.create("www", "W", "o@x.test")

    {:ok, _} = run(&CLI.create("ha08-cli", "Club", "owner@ha08.test", &1))

    assert {:error, "Not started: choose a version newer than the current one", 1} =
             CLI.upgrade("ha08-cli", "0.0.1")

    assert {:error, "Not started: the forum is busy, or not in a state for this", 1} =
             CLI.resume("ha08-cli")

    # A failed action: its reason, from the audit log.
    Fake.exec_result([@admin, "backup"], {:ok, %{exit_code: 1, output: "disk full"}})
    assert {:error, "Failed: " <> _reason, 1} = run(&CLI.backup("ha08-cli", &1))

    # Nothing runs the job: the wait ends with a message, not a hang.
    {:ok, "ha08-cli suspended"} = run(&CLI.suspend("ha08-cli", &1))
    assert {:error, "Still under way" <> _, 1} = CLI.resume("ha08-cli", timeout: 50, poll: 10)
  end

  test "HA-08 Release.cli prints and exits with the code" do
    assert capture_io(fn -> IdejoHub.Release.cli("forums", []) end) == ""

    assert capture_io(:stderr, fn ->
             assert catch_exit(IdejoHub.Release.cli("backup", ["nope"])) == {:shutdown, 2}
           end) =~ "No forum is called nope."
  end

  test "HA-08 hub-admin passes arguments into the Hub as data, never as code" do
    dir = Path.join(System.tmp_dir!(), "ha08-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    File.cp!(@script, Path.join(dir, "hub-admin"))
    # A stand-in release: running, and rpc prints the code it was given.
    File.write!(Path.join(dir, "idejo_hub"), """
    #!/bin/sh
    case "$1" in pid) exit 0 ;; rpc) printf '%s' "$2" ;; esac
    """)

    File.chmod!(Path.join(dir, "idejo_hub"), 0o755)
    File.chmod!(Path.join(dir, "hub-admin"), 0o755)

    name = ~S|Club "#{System.halt()}" \ end|
    {code, 0} = System.cmd(Path.join(dir, "hub-admin"), ["create", "ha08", name, "o@x.test"])

    assert {:ok, {{:., _, [{:__aliases__, _, [:IdejoHub, :Release]}, :cli]}, _, ["create", args]}} =
             Code.string_to_quoted(code)

    decoded =
      for {{:., _, [{:__aliases__, _, [:Base]}, :decode64!]}, _, [encoded]} <- args,
          do: Base.decode64!(encoded)

    assert decoded == ["ha08", name, "o@x.test"]

    # Wrong number of arguments: usage, exit 64.
    {_out, 64} =
      System.cmd(Path.join(dir, "hub-admin"), ["upgrade", "ha08"], stderr_to_stdout: true)
  end
end
