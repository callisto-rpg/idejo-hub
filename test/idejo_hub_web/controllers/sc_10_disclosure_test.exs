# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SC10DisclosureTest do
  @moduledoc """
  SC-10: a short disclosure page for forum owners: what the Hub operator can technically
  access (from how the Hub works) and when they would (the operator's words, from Settings).
  """
  use IdejoHubWeb.ConnCase, async: false

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Repo, Settings}

  @moduletag req: "SC-10"

  defp page(conn), do: get(%{conn | host: "id.idejo.test"}, ~p"/account/operator-access")

  # The page's text, its line breaks and indentation read as single spaces.
  defp text(html), do: String.replace(html, ~r/\s+/, " ")

  test "SC-10 the page says what the operator can reach, on the sign-in host, to anyone", %{
    conn: conn
  } do
    html = conn |> page() |> html_response(200)

    for section <- ~w(access-hub access-server access-identity access-log access-policy) do
      assert html =~ ~s(id="#{section}"), section
    end

    # The facts a forum owner most needs, from how the Hub works.
    text = text(html)
    assert text =~ "private conversations included"
    assert text =~ "The Hub cannot open your forum's database while it runs"
    assert text =~ "Whoever administers the server can read anything stored on it"

    assert text =~
             "could technically change how a person signs in, and so sign in to forums as them"

    assert text =~ "recorded in your forum's audit log"

    # Members' pages live on the sign-in host only.
    assert conn |> get(~p"/account/operator-access") |> response(404)
  end

  test "SC-10 until the operator says when they would look, the page says they have not", %{
    conn: conn
  } do
    html = conn |> page() |> html_response(200)
    assert html =~ ~s(id="access-policy-none")
    assert html =~ "The operator of this Hub has not said yet."
  end

  test "SC-10 the operator writes when they would, in Settings; owners read it as written", %{
    conn: conn
  } do
    {operator_conn, operator, _password} = sign_in(conn)
    {:ok, view, _} = live(operator_conn, ~p"/settings")

    policy = "Only for abuse reports or a court order.\n\nWrite to <ops@hub.test> first."
    view |> form("#settings", settings: %{access_policy: policy}) |> render_submit()

    assert Settings.get("access_policy") == policy

    entry = Repo.get_by(Audit.Entry, action: "settings.update", actor: operator.email)
    assert "access_policy" in entry.details["keys"]

    html = build_conn() |> page() |> html_response(200)
    refute html =~ "access-policy-none"
    assert html =~ "Only for abuse reports or a court order."
    # Escaped, two paragraphs.
    assert html =~ "Write to &lt;ops@hub.test&gt; first."
    assert length(String.split(html, ~s(class="whitespace-pre-line"))) == 3
  end

  test "SC-10 the policy is at most 4000 characters", %{conn: conn} do
    {operator_conn, _operator, _password} = sign_in(conn)
    {:ok, view, _} = live(operator_conn, ~p"/settings")

    html =
      view
      |> form("#settings", settings: %{access_policy: String.duplicate("a", 4001)})
      |> render_submit()

    assert html =~ "at most 4000 characters"
    assert Settings.get("access_policy") == nil
  end
end
