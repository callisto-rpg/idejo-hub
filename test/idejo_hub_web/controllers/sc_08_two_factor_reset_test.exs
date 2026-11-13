# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SC08TwoFactorResetTest do
  @moduledoc """
  SC-08 (steward request 2026-11-13): an operator who lost their two-factor app gives their
  email and password and gets a single-use link by email (30 minutes); confirming on its
  page removes the setup, set up again at the next sign-in.
  """
  use IdejoHubWeb.ConnCase, async: false

  import Ecto.Query
  import IdejoHub.OperatorFixtures

  alias IdejoHub.{Audit, Operators, Repo}

  @moduletag req: "SC-08"

  # RateLimit is per address: each test asks from its own.
  setup %{conn: conn} do
    address = "sc08-2fa-#{System.unique_integer([:positive])}"
    {:ok, conn: put_req_header(conn, "x-forwarded-for", address)}
  end

  defp audit(action),
    do: Repo.all(from e in Audit.Entry, where: e.action == ^action, order_by: e.id)

  defp ask(conn, email, password),
    do:
      post(conn, ~p"/sign-in/two-factor-reset", %{
        "reset" => %{"email" => email, "password" => password}
      })

  defp emailed_token do
    assert_received {:email, email}

    link = ~r{/sign-in/two-factor-reset/([A-Za-z0-9_-]+)}
    [token] = Regex.run(link, email.text_body, capture: :all_but_first)

    {email, token}
  end

  defp with_two_factor do
    {operator, password} = operator_fixture()
    {:ok, _} = Operators.begin_two_factor(operator)

    {:ok, operator} =
      Operators.confirm_two_factor(Operators.get_operator!(operator.id), totp_code(operator))

    {operator, password}
  end

  test "SC-08 the sign-in page links to the lost two-factor form", %{conn: conn} do
    assert html_response(get(conn, ~p"/sign-in"), 200) =~ ~s(id="lost-two-factor")
    page = html_response(get(conn, ~p"/sign-in/two-factor-reset"), 200)
    assert page =~ ~s(id="two-factor-reset")
  end

  test "SC-08 with the password, the emailed link removes two factor once, after confirming",
       %{conn: conn} do
    {operator, password} = with_two_factor()
    session = Operators.create_session(operator)

    asked = ask(conn, String.upcase(operator.email), password)
    assert redirected_to(asked) == ~p"/sign-in"
    assert Phoenix.Flash.get(asked.assigns.flash, :info) =~ "If that email and password"

    {email, token} = emailed_token()
    assert email.to == [{"", operator.email}]
    # Only the token's hash is kept, apart from the password reset's.
    kept = Operators.get_operator!(operator.id)
    refute kept.two_factor_reset_hash == token
    assert kept.reset_token_hash == nil
    assert Operators.get_operator_by_reset_token(token) == nil

    # Opening the link changes nothing: it asks to confirm.
    page = html_response(get(conn, ~p"/sign-in/two-factor-reset/#{token}"), 200)
    assert page =~ ~s(id="two-factor-reset-confirm")
    assert page =~ operator.email
    assert Operators.two_factor?(Operators.get_operator!(operator.id))

    done = post(conn, ~p"/sign-in/two-factor-reset/#{token}")
    assert redirected_to(done) == ~p"/sign-in"
    assert Phoenix.Flash.get(done.assigns.flash, :info) =~ "Two-factor removed"

    refute Operators.two_factor?(Operators.get_operator!(operator.id))
    assert Operators.get_operator_by_session(session) == nil
    # The password is unchanged.
    assert {:ok, _} = Operators.check_password(operator.email, password)

    # Used once.
    again = post(conn, ~p"/sign-in/two-factor-reset/#{token}")
    assert redirected_to(again) == ~p"/sign-in/two-factor-reset"

    assert redirected_to(get(conn, ~p"/sign-in/two-factor-reset/#{token}")) ==
             ~p"/sign-in/two-factor-reset"

    assert Enum.map(audit("operator.two_factor_reset"), &{&1.actor, &1.outcome}) ==
             [{operator.email, "requested"}, {operator.email, "ok"}]

    refute Enum.any?(audit("operator.two_factor_reset"), &(inspect(&1.details) =~ token))
  end

  test "SC-08 a wrong password or unknown email gets the same answer and no email; it counts",
       %{conn: conn} do
    {operator, _password} = with_two_factor()

    wrong = ask(conn, operator.email, "not the password")
    assert redirected_to(wrong) == ~p"/sign-in"
    assert Phoenix.Flash.get(wrong.assigns.flash, :info) =~ "If that email and password"
    refute_received {:email, _}
    assert Operators.get_operator!(operator.id).failed_attempts == 1

    unknown = ask(conn, "nobody@hub.idejo.test", "whatever password")
    assert Phoenix.Flash.get(unknown.assigns.flash, :info) =~ "If that email and password"
    refute_received {:email, _}
    assert Operators.two_factor?(Operators.get_operator!(operator.id))
  end

  test "SC-08 a locked account gets no link, even with its password", %{conn: conn} do
    {operator, password} = with_two_factor()
    until = DateTime.add(DateTime.utc_now(:second), 10, :minute)
    Repo.update!(Ecto.Changeset.change(operator, locked_until: until))

    assert redirected_to(ask(conn, operator.email, password)) == ~p"/sign-in"
    refute_received {:email, _}
  end

  test "SC-08 a link stops working after 30 minutes; a password reset link is not one",
       %{conn: conn} do
    {operator, password} = with_two_factor()
    ask(conn, operator.email, password)
    {_, token} = emailed_token()

    # The password reset's own link never removes two factor.
    post(conn, ~p"/sign-in/reset", %{"reset" => %{"email" => operator.email}})
    assert_received {:email, reset_email}
    link = ~r{/sign-in/reset/([A-Za-z0-9_-]+)}
    [reset] = Regex.run(link, reset_email.text_body, capture: :all_but_first)
    assert {:error, :expired} = Operators.reset_two_factor_by_token(reset)
    assert Operators.two_factor?(Operators.get_operator!(operator.id))

    old = DateTime.add(DateTime.utc_now(:second), -31, :minute)

    Repo.update!(
      Ecto.Changeset.change(Operators.get_operator!(operator.id), two_factor_reset_sent_at: old)
    )

    assert redirected_to(post(conn, ~p"/sign-in/two-factor-reset/#{token}")) ==
             ~p"/sign-in/two-factor-reset"

    assert Operators.two_factor?(Operators.get_operator!(operator.id))
  end

  test "SC-08 requests are limited per email and per address", %{conn: conn} do
    {operator, password} = with_two_factor()
    for _ <- 1..3, do: ask(conn, operator.email, password)
    for _ <- 1..3, do: emailed_token()

    # A fourth for the same email: the same answer, no email.
    assert redirected_to(ask(conn, operator.email, password)) == ~p"/sign-in"
    refute_received {:email, _}

    # The fifth from the same address is its last; the sixth is refused.
    assert redirected_to(ask(conn, "nobody@hub.idejo.test", "x")) == ~p"/sign-in"
    assert html_response(ask(conn, "nobody@hub.idejo.test", "x"), 429) =~ "Too many requests"
  end
end
