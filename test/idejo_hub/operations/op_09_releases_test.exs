# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Operations.OP09ReleasesTest do
  @moduledoc "OP-09: notice of new idejo releases, with a link to the changelog."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import ExUnit.CaptureLog
  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.Hosting.Docker.Fake
  alias IdejoHub.Operations.{ReleaseCheckWorker, Releases}

  @moduletag req: "OP-09"

  # GitHub's tag list, as the Hub reads it (test config: new forums start on 0.1.0).
  defp tags(names) do
    Req.Test.stub(Releases, fn conn ->
      Req.Test.json(conn, Enum.map(names, &%{"name" => &1, "commit" => %{"sha" => "x"}}))
    end)
  end

  test "OP-09 the newest stable version is kept; pre-releases and other tags are not" do
    tags(["v0.2.3", "v0.10.0-rc.1", "v0.9.1", "nightly", "v0.2.10"])
    assert {:ok, "0.9.1"} = Releases.check()
    assert %{version: "0.9.1", checked_at: _} = Releases.latest()
  end

  test "OP-09 a newer release than new forums start on shows, linked to what changed", %{
    conn: conn
  } do
    tags(["v0.2.3", "v0.1.0"])
    :ok = perform_job(ReleaseCheckWorker, %{})

    assert Releases.notice() == %{
             version: "0.2.3",
             current: "0.1.0",
             changelog: "https://github.com/callisto-rpg/Idejo/compare/v0.1.0...v0.2.3"
           }

    {conn, _operator, _password} = sign_in(conn)
    # The server page lists forum containers through Docker.
    Fake.start()

    for path <- [~p"/", ~p"/server"] do
      {:ok, view, _} = live(conn, path)
      notice = view |> element("#release-notice[role=status]") |> render()
      assert notice =~ "idejo 0.2.3 is out; new forums start on 0.1.0."
      assert notice =~ ~s(href="https://github.com/callisto-rpg/Idejo/compare/v0.1.0...v0.2.3")
    end
  end

  test "OP-09 nothing shows while no release is newer", %{conn: conn} do
    tags(["v0.1.0", "v0.0.9"])
    {:ok, "0.1.0"} = Releases.check()
    assert Releases.notice() == nil

    {conn, _operator, _password} = sign_in(conn)
    {:ok, view, _} = live(conn, ~p"/")
    refute has_element?(view, "#release-notice")
  end

  test "OP-09 a failed check keeps what was known; an empty address turns it off" do
    tags(["v0.2.3"])
    {:ok, _} = Releases.check()

    Req.Test.stub(Releases, &Plug.Conn.send_resp(&1, 503, "down"))

    assert capture_log(fn ->
             assert {:error, {:status, 503}} = perform_job(ReleaseCheckWorker, %{})
           end) =~ "could not read idejo's releases"

    assert Releases.latest().version == "0.2.3"

    config = Application.get_env(:idejo_hub, Releases)
    on_exit(fn -> Application.put_env(:idejo_hub, Releases, config) end)
    Application.put_env(:idejo_hub, Releases, Keyword.put(config, :url, ""))
    assert {:error, :off} = Releases.check()
    assert :ok = perform_job(ReleaseCheckWorker, %{})
  end
end
