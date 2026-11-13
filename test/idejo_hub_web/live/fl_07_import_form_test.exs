# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.FL07ImportFormTest do
  @moduledoc "FL-07: the operator imports a standalone idejo backup from the web interface."
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Forums}
  alias IdejoHub.Forums.{CreateWorker, Export}

  @moduletag req: "FL-07"
  @moduletag :capture_log

  setup %{conn: conn} do
    File.rm_rf!(Export.dir())
    {conn, operator, _password} = sign_in(conn)
    %{conn: conn, operator: operator}
  end

  defp tar(entries) do
    path = Path.join(System.tmp_dir!(), "fl07-form-#{System.unique_integer([:positive])}")
    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write])
    for {name, data} <- entries, do: :ok = :erl_tar.add(tar, data, String.to_charlist(name), [])
    :ok = :erl_tar.close(tar)
    content = File.read!(path)
    File.rm!(path)
    content
  end

  defp standalone_backup,
    do:
      tar([
        {"manifest.json", Jason.encode!(%{"format" => 1, "migration" => 20_261_104_120_000})},
        {"database.dump", "PGDMP"}
      ])

  defp choose(view, content) do
    file =
      file_input(view, "#import-forum", :backup, [
        %{name: "idejo-20261101-020000.tar", content: content, type: "application/x-tar"}
      ])

    render_upload(file, "idejo-20261101-020000.tar")
  end

  defp fields(subdomain),
    do: %{subdomain: subdomain, display_name: "Chess", owner_email: "owner@chess.test"}

  test "FL-07 the forum list links to the import form", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")

    assert {:ok, _form, html} =
             view |> element("#import-forum-link") |> render_click() |> follow_redirect(conn)

    assert html =~ "Import a standalone backup"
  end

  test "FL-07 imports the uploaded backup as the operator and opens the new forum", %{
    conn: conn,
    operator: operator
  } do
    {:ok, view, _} = live(conn, ~p"/forums/import")
    choose(view, standalone_backup())

    {:ok, _show, html} =
      view
      |> form("#import-forum", forum: fields("fl07-form"), secret_key_base: "")
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Importing fl07-form.idejo.test"
    forum = Forums.get_by_subdomain("fl07-form")
    assert forum.status == "creating"
    assert forum.local_accounts
    assert [%{kind: "import"}] = Forums.list_exports(forum)

    assert_enqueued(
      worker: CreateWorker,
      args: %{"forum_id" => forum.id, "actor" => operator.email}
    )

    assert Enum.any?(
             Audit.for_forum(forum.id),
             &(&1.action == "forum.import" and &1.actor == operator.email)
           )
  end

  test "FL-07 a mistake in the form keeps the chosen file", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/forums/import")
    choose(view, standalone_backup())

    html =
      view
      |> form("#import-forum",
        forum: %{fields("fl07-form") | owner_email: "not-an-email"},
        secret_key_base: ""
      )
      |> render_submit()

    assert html =~ "must be an email address"
    assert html =~ "idejo-20261101-020000.tar"

    html =
      view
      |> form("#import-forum", forum: fields("fl07-form"), secret_key_base: "too short")
      |> render_submit()

    assert html =~ "at least 64 characters"
    assert html =~ "idejo-20261101-020000.tar"
    assert Forums.get_by_subdomain("fl07-form") == nil
  end

  test "FL-07 a file that is not an idejo backup is refused", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/forums/import")
    choose(view, tar([{"notes.txt", "hello"}]))

    html =
      view
      |> form("#import-forum", forum: fields("fl07-form"), secret_key_base: "")
      |> render_submit()

    assert html =~ "not a standalone idejo backup"
    assert Forums.get_by_subdomain("fl07-form") == nil
  end

  test "FL-07 checks the subdomain while typing", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/forums/import")

    html = view |> form("#import-forum", forum: %{subdomain: "fl07-free"}) |> render_change()
    assert html =~ "Available: https://fl07-free.idejo.test"

    assert view |> form("#import-forum", forum: %{subdomain: "www"}) |> render_change() =~
             "is reserved"
  end
end
