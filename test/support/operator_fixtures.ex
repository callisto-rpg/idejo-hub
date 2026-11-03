# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.OperatorFixtures do
  @moduledoc "Operators for tests (SC-08)."

  import Phoenix.ConnTest
  import Plug.Conn

  alias IdejoHub.{Operators, Secrets}

  @endpoint IdejoHubWeb.Endpoint

  @doc "A new operator and their password."
  def operator_fixture(email \\ "op#{System.unique_integer([:positive])}@hub.idejo.test") do
    {:ok, operator, password} = Operators.create_operator(email)
    {operator, password}
  end

  @doc "The TOTP code an operator's app would show at `time` (default now)."
  def totp_code(operator, time \\ System.os_time(:second)) do
    operator = Operators.get_operator!(operator.id)
    {:ok, secret} = Secrets.decrypt(operator.totp_secret_enc, "operator:#{operator.id}:totp")
    NimbleTOTP.verification_code(secret, time: time)
  end

  @doc """
  Signs a conn in through the real pages (password, two-factor setup, code). Returns the
  conn, the operator and their password.
  """
  def sign_in(conn) do
    {operator, password} = operator_fixture()

    conn =
      post(conn, "/sign-in", %{"session" => %{"email" => operator.email, "password" => password}})

    conn = conn |> recycle() |> get("/sign-in/two-factor")

    conn =
      conn
      |> recycle()
      |> post("/sign-in/two-factor", %{"two_factor" => %{"code" => totp_code(operator)}})

    {conn |> recycle() |> put_req_header("accept", "text/html"),
     Operators.get_operator!(operator.id), password}
  end
end
