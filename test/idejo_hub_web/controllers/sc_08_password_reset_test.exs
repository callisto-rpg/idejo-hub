# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SC08PasswordResetTest do
  @moduledoc """
  SC-08: an operator who forgot their password gets a single-use link by email (30 minutes)
  and chooses a new one; two factor is still asked. An owner resets another operator's two
  factor from the Operators page.
  """
  use IdejoHubWeb.ConnCase, async: false

  import Ecto.Query
  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Operators, Repo}

  @moduletag req: "SC-08"

  # RateLimit is per address: each test asks from its own.
  setup %{conn: conn} do
    address = "sc08-reset-#{System.unique_integer([:positive])}"
    {:ok, conn: put_req_header(conn, "x-forwarded-for", address)}
  end

  defp audit(action),
    do: Repo.all(from e in Audit.Entry, where: e.action == ^action, order_by: e.id)

  defp ask(conn, email), do: post(conn, ~p"/sign-in/reset", %{"reset" => %{"email" => email}})

  defp emailed_token do
    assert_received {:email, email}
    [token] =
      Regex.run(~r{/sign-in/reset/([A-Za-z0-9_-]+)}, email.text_body, capture: :all_but_first)

    {email, token}
  end

  defp choose(conn, token, password, confirmation \\ nil) do
    post(conn, ~p"/sign-in/reset/#{token}", %{
      "reset" => %{"password" => password, "password_confirmation" => confirmation || password}
    })
  end

  defp with_two_factor do
    {operator, password} = operator_fixture()
    {:ok, _} = Operators.begin_two_factor(operator)

    {:ok, operator} =
      Operators.confirm_two_factor(Operators.get_operator!(operator.id), totp_code(operator))

    {operator, password}
  end

  test "SC-08 the sign-in page links to the reset form", %{conn: conn} do
    assert html_response(get(conn, ~p"/sign-in"), 200) =~ ~s(id="forgot-password")
    assert html_response(get(conn, ~p"/sign-in/reset"), 200) =~ ~s(id="password-reset")
  end

  test "SC-08 the emailed link sets a new password once; sessions end, two factor stays",
       %{conn: conn} do
    {operator, old} = with_two_factor()
    session = Operators.create_session(operator)

    asked = ask(conn, String.upcase(operator.email))
    assert redirected_to(asked) == ~p"/sign-in"
    assert Phoenix.Flash.get(asked.assigns.flash, :info) =~ "If that email belongs"

    {email, token} = emailed_token()
    assert email.to == [{"", operator.email}]
    # Only the token's hash is kept.
    refute Operators.get_operator!(operator.id).reset_token_hash == token

    assert html_response(get(conn, ~p"/sign-in/reset/#{token}"), 200) =~
             ~s(id="password-reset-new")

    assert html_response(choose(conn, token, "short"), 422) =~ "at least 12"

    assert html_response(choose(conn, token, "a long new password", "another one"), 422) =~
             "not the same"

    done = choose(conn, token, "a long new password")
    assert redirected_to(done) == ~p"/sign-in"

    assert {:error, :invalid} = Operators.check_password(operator.email, old)
    assert {:ok, _} = Operators.check_password(operator.email, "a long new password")
    assert Operators.get_operator_by_session(session) == nil
    assert Operators.two_factor?(Operators.get_operator!(operator.id))

    # Used once.
    assert redirected_to(choose(conn, token, "yet another password")) == ~p"/sign-in/reset"
    assert redirected_to(get(conn, ~p"/sign-in/reset/#{token}")) == ~p"/sign-in/reset"

    assert Enum.map(audit("operator.password_reset"), &{&1.actor, &1.outcome}) ==
             [{operator.email, "requested"}, {operator.email, "ok"}]

    refute Enum.any?(audit("operator.password_reset"), &(inspect(&1.details) =~ token))
  end

  test "SC-08 an unknown email gets the same answer and no email", %{conn: conn} do
    asked = ask(conn, "nobody@hub.idejo.test")
    assert redirected_to(asked) == ~p"/sign-in"
    assert Phoenix.Flash.get(asked.assigns.flash, :info) =~ "If that email belongs"
    refute_received {:email, _}
  end

  test "SC-08 a link stops working after 30 minutes, and a new one replaces it", %{conn: conn} do
    {operator, _} = operator_fixture()
    ask(conn, operator.email)
    {_, first} = emailed_token()
    ask(conn, operator.email)
    {_, second} = emailed_token()
    assert Operators.get_operator_by_reset_token(first) == nil
    assert Operators.get_operator_by_reset_token(second)

    old = DateTime.add(DateTime.utc_now(:second), -31, :minute)
    Repo.update!(Ecto.Changeset.change(Operators.get_operator!(operator.id), reset_sent_at: old))
    assert redirected_to(get(conn, ~p"/sign-in/reset/#{second}")) == ~p"/sign-in/reset"
  end

  test "SC-08 requests are limited per email and per address", %{conn: conn} do
    {operator, _} = operator_fixture()
    for _ <- 1..3, do: ask(conn, operator.email)
    for _ <- 1..3, do: emailed_token()

    # A fourth for the same email: the same answer, no email.
    assert redirected_to(ask(conn, operator.email)) == ~p"/sign-in"
    refute_received {:email, _}

    # Two more from the same address reach its limit of five.
    ask(conn, "nobody@hub.idejo.test")
    assert html_response(ask(conn, "nobody@hub.idejo.test"), 429) =~ "Too many requests"
  end

  test "SC-08 an owner resets another operator's two factor on the Operators page", %{
    conn: conn
  } do
    {conn, owner, _} = sign_in(conn, "owner")
    {other, _} = with_two_factor()
    session = Operators.create_session(other)

    {:ok, view, _html} = live(conn, ~p"/operators")
    refute has_element?(view, "#operator-#{owner.id}-reset-two-factor")
    view |> element("#operator-#{other.id}-reset-two-factor") |> render_click()

    refute Operators.two_factor?(Operators.get_operator!(other.id))
    assert Operators.get_operator_by_session(session) == nil
    assert [%{actor: actor, details: %{"email" => email}}] = audit("operator.two_factor_reset")
    assert {actor, email} == {owner.email, other.email}
    # Not set up any more: no button.
    refute has_element?(view, "#operator-#{other.id}-reset-two-factor")

    # Never one's own, and only owners.
    assert {:error, :self} = Operators.reset_two_factor(owner, owner)
    {plain, _} = operator_fixture("sc08-op@hub.idejo.test", "operator")
    assert {:error, :forbidden} = Operators.reset_two_factor(owner, plain)
  end
end
