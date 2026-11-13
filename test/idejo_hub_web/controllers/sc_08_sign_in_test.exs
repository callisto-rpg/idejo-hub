# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.SC08SignInTest do
  @moduledoc "SC-08: operator pages need a password and a two-factor code."
  use IdejoHubWeb.ConnCase, async: true

  import IdejoHub.OperatorFixtures

  alias IdejoHub.{Operators, Repo}

  @moduletag req: "SC-08"

  defp password_step(conn, email, password),
    do: post(conn, ~p"/sign-in", %{"session" => %{"email" => email, "password" => password}})

  test "operator pages send visitors to sign in", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/sign-in"
  end

  test "first sign-in: password, then two-factor setup, then the code", %{conn: conn} do
    {operator, password} = operator_fixture()

    conn = password_step(conn, operator.email, password)
    assert redirected_to(conn) == ~p"/sign-in/two-factor"

    # The password alone opens nothing.
    assert redirected_to(conn |> recycle() |> get(~p"/")) == ~p"/sign-in"

    page = conn |> recycle() |> get(~p"/sign-in/two-factor")
    assert html_response(page, 200) =~ "two-factor-secret"

    signed_in =
      page
      |> recycle()
      |> post(~p"/sign-in/two-factor", %{"two_factor" => %{"code" => totp_code(operator)}})

    assert redirected_to(signed_in) == ~p"/"
    assert html_response(signed_in |> recycle() |> get(~p"/"), 200) =~ "idejo Hub"
  end

  test "later sign-ins ask for the code without showing a secret; sign-out ends the session",
       %{conn: conn} do
    {conn, operator, password} = sign_in(conn)
    home = html_response(get(conn, ~p"/"), 200)
    assert home =~ ~s(id="sign-out")
    assert home =~ operator.email
    signed_out = delete(conn, ~p"/sign-out")
    assert redirected_to(signed_out |> recycle() |> get(~p"/")) == ~p"/sign-in"

    # Let the current code count again (the first sign-in used it).
    Repo.update!(Ecto.Changeset.change(operator, totp_last_step: 0))

    conn = password_step(build_conn(), operator.email, password)
    page = conn |> recycle() |> get(~p"/sign-in/two-factor")
    refute html_response(page, 200) =~ "two-factor-secret"

    conn =
      page
      |> recycle()
      |> post(~p"/sign-in/two-factor", %{"two_factor" => %{"code" => totp_code(operator)}})

    assert redirected_to(conn) == ~p"/"
  end

  test "a wrong code is refused and nothing is signed in", %{conn: conn} do
    {operator, password} = operator_fixture()
    conn = password_step(conn, operator.email, password)
    _ = conn |> recycle() |> get(~p"/sign-in/two-factor")

    conn =
      conn |> recycle() |> post(~p"/sign-in/two-factor", %{"two_factor" => %{"code" => "12345"}})

    assert html_response(conn, 401) =~ "not right"
    assert redirected_to(conn |> recycle() |> get(~p"/")) == ~p"/sign-in"
  end

  test "wrong password: one message, whether the email exists or not", %{conn: conn} do
    {operator, _} = operator_fixture()
    a = password_step(conn, operator.email, "nope")
    b = password_step(build_conn(), "nobody@hub.idejo.test", "nope")
    assert html_response(a, 401) =~ "Wrong email or password."
    assert html_response(b, 401) =~ "Wrong email or password."
  end

  test "a locked account is refused at sign-in", %{conn: conn} do
    {operator, password} = operator_fixture()
    for _ <- 1..5, do: Operators.check_password(operator.email, "nope")

    assert html_response(password_step(conn, operator.email, password), 401) =~
             "locked for 15 minutes"
  end

  test "the code page needs the password first", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/sign-in/two-factor")) == ~p"/sign-in"
  end

  test "the session cookie is encrypted, HttpOnly, SameSite=Strict and host-only", %{conn: conn} do
    {operator, password} = operator_fixture()
    conn = password_step(conn, operator.email, password)
    cookie = conn.resp_cookies["_idejo_hub_key"]

    assert cookie.same_site == "Strict"
    assert cookie.http_only == true
    refute Map.has_key?(cookie, :domain)
    # Encrypted (Plug.Crypto.MessageEncryptor: two parts), not merely signed (three), so the
    # session's contents cannot be read from the cookie.
    assert length(String.split(cookie.value, ".")) == 2
  end
end
