# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.NF07MemberPagesTest do
  @moduledoc """
  Hub NF-07: every page a member sees meets base Idejo's standards. Accessibility: Idejo's
  own AX-01 audit (`IdejoHubWeb.Accessibility`, ported from Idejo) on each member page: a
  skip link to <main> first, one <h1>, no skipped heading level, named landmarks, a name for
  everything that can be focused, labels on every field, nothing clickable the keyboard
  cannot reach. Privacy: as Idejo's AD-02, a privacy notice written by the operator, linked
  from every member page and from sign-up, no outside scripts, and the forum's consent
  screen is Idejo's own (AC-09). Contrast and focus rings are checked by hand.
  """
  use IdejoHubWeb.ConnCase, async: false

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Forums, Identity, Settings}
  alias IdejoHub.Identity.{Fake, Members}
  alias IdejoHubWeb.Accessibility

  @moduletag req: "NF-07"
  @moduletag :capture_log

  setup %{conn: conn} do
    Fake.start()
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)
    :ok = Members.ensure_account_client()
    {:ok, {client_id, _}} = Members.account_client()

    {:ok, forum} =
      Forums.create_forum(
        %{"subdomain" => "nf07-club", "display_name" => "Club", "owner_email" => "ada@x.test"},
        "op@hub.test"
      )

    %{conn: %{conn | host: "id.idejo.test"}, client_id: client_id, forum: forum}
  end

  defp assert_accessible(html, page) do
    problems = Accessibility.audit(html)
    assert problems == [], "#{page}:\n" <> Enum.join(problems, "\n")
  end

  # Signed in through the provider, as ID-05's tests do.
  defp signed_in(conn, ctx) do
    {:ok, subject} =
      Fake.create_person(%{
        email: "ada@x.test",
        email_verified: true,
        display_name: "Ada",
        given_name: "Sennoma",
        family_name: "Ulo",
        language: "en"
      })

    conn = get(conn, ~p"/account/sign-in")
    query = conn |> redirected_to(302) |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    now = System.system_time(:second)

    Fake.put_code("code-nf07", %{
      "iss" => "https://id.idejo.test",
      "aud" => [ctx.client_id],
      "sub" => subject,
      "exp" => now + 300,
      "auth_time" => now,
      "nonce" => query["nonce"]
    })

    conn
    |> recycle()
    |> get(~p"/account/callback?#{%{"code" => "code-nf07", "state" => query["state"]}}")
    |> recycle()
  end

  test "NF-07 every member page passes Idejo's accessibility audit", %{conn: conn} = ctx do
    # Sign-up, closed (no SMTP) and open, and its confirmation.
    assert_accessible(conn |> get(~p"/account/sign-up") |> html_response(200), "sign-up, closed")

    {:ok, _} =
      Settings.update(%{"smtp_host" => "smtp.hub.test", "smtp_port" => "587"}, "op@hub.test")

    assert_accessible(conn |> get(~p"/account/sign-up") |> html_response(200), "sign-up")

    invalid =
      conn |> post(~p"/account/sign-up", %{"signup" => %{"email" => "x"}}) |> html_response(422)

    assert_accessible(invalid, "sign-up with errors")

    sent =
      conn
      |> post(~p"/account/sign-up", %{
        "signup" => %{"email" => "new@x.test", "display_name" => "New"}
      })
      |> html_response(200)

    assert_accessible(sent, "sign-up sent")

    # The member's page, signed out and signed in (owning a forum), and the owner's log.
    assert_accessible(conn |> get(~p"/account") |> html_response(200), "account, signed out")
    member = signed_in(conn, ctx)
    assert_accessible(member |> get(~p"/account") |> html_response(200), "account")

    log = member |> get(~p"/account/forums/#{ctx.forum.subdomain}/log") |> html_response(200)
    assert_accessible(log, "owner's log")

    assert_accessible(conn |> get(~p"/account/privacy") |> html_response(200), "privacy")

    access = conn |> get(~p"/account/operator-access") |> html_response(200)
    assert_accessible(access, "what the operator can access (SC-10)")
  end

  test "NF-07 every member page links the privacy notice; sign-up says what it keeps", %{
    conn: conn
  } do
    for path <- [
          ~p"/account/sign-up",
          ~p"/account",
          ~p"/account/privacy",
          ~p"/account/operator-access"
        ] do
      html = conn |> get(path) |> html_response(200)
      assert html =~ ~s(id="member-footer"), path
      assert html =~ ~s(href="https://id.idejo.test/account/privacy"), path
    end

    assert conn |> get(~p"/account/sign-up") |> html_response(200) =~ ~s(id="signup-privacy")
    # The operator's pages carry no member footer.
    refute build_conn() |> get(~p"/sign-in") |> html_response(200) =~ "member-footer"
  end

  test "NF-07 the privacy notice is the operator's, written in Settings", %{conn: conn} do
    html = conn |> get(~p"/account/privacy") |> html_response(200)
    assert html =~ "This Hub has not published a privacy notice yet."

    {operator_conn, _operator, _} = sign_in(build_conn())
    {:ok, view, _} = live(operator_conn, ~p"/settings")
    notice = "Run by Example Ltd.\n\nWe keep your email <and> names while your Idejo ID exists."
    view |> form("#settings", settings: %{privacy_notice: notice}) |> render_submit()

    html = conn |> get(~p"/account/privacy") |> html_response(200)
    refute html =~ "privacy-notice-none"
    assert html =~ "Run by Example Ltd."
    assert html =~ "your email &lt;and&gt; names"
  end

  test "NF-07 member pages load nothing from elsewhere", %{conn: conn} do
    response = get(conn, ~p"/account/sign-up")
    [csp] = get_resp_header(response, "content-security-policy")
    assert csp =~ "default-src 'self'"
    refute response.resp_body =~ ~r/<script[^>]+src="https?:/
    refute response.resp_body =~ ~r/<link[^>]+href="https?:/
  end
end
