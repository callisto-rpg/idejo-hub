# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.HA07OperatorRolesTest do
  @moduledoc """
  HA-07: several operator accounts with roles, owner and operator. Owners also manage the
  accounts (add, role, remove); the last owner stays one.
  """
  use IdejoHubWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureIO
  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Operators, Repo}

  @moduletag req: "HA-07"

  defp audit(action),
    do: Repo.all(from e in Audit.Entry, where: e.action == ^action, order_by: e.id)

  test "HA-07 the first account is an owner, later ones operators, unless a role is given" do
    {first, _} = operator_fixture()
    {second, _} = operator_fixture()
    {third, _} = operator_fixture("ha07-owner@hub.idejo.test", "owner")
    assert {first.role, second.role, third.role} == {"owner", "operator", "owner"}

    assert {:error, changeset} = Operators.create_operator("bad-role@hub.idejo.test", "admin")
    assert "is invalid" in IdejoHub.DataCase.errors_on(changeset).role
    assert Enum.map(audit("operator.create"), & &1.details["role"]) == ~w(owner operator owner)
  end

  test "HA-07 the command line takes a role" do
    out =
      capture_io(fn -> IdejoHub.Release.create_operator("ha07-cli@hub.idejo.test", "owner") end)

    assert out =~ "role owner"
    assert Operators.get_by_email("ha07-cli@hub.idejo.test").role == "owner"
    # The hub-admin script accepts only the two roles.
    script = File.read!(Path.expand("../../../rel/overlays/bin/hub-admin", __DIR__))
    assert script =~ ~s([ "$4" = owner ] || [ "$4" = operator ])
  end

  test "HA-07 only owners see and open the operators page", %{conn: conn} do
    {owner_conn, _owner, _} = sign_in(conn)
    {:ok, view, _} = live(owner_conn, ~p"/")
    assert has_element?(view, ~s(nav a[href="/operators"]))

    {operator_conn, _operator, _} = sign_in(build_conn(), "operator")
    {:ok, view, _} = live(operator_conn, ~p"/")
    refute has_element?(view, ~s(nav a[href="/operators"]))

    assert {:error,
            {:redirect, %{to: "/", flash: %{"error" => "Only owners manage operator accounts."}}}} =
             live(operator_conn, ~p"/operators")
  end

  test "HA-07 an owner adds an operator, changes roles and removes accounts", %{conn: conn} do
    {conn, owner, _} = sign_in(conn)
    {:ok, view, _} = live(conn, ~p"/operators")

    view
    |> form("#add-operator", email: "ha07-new@hub.idejo.test", role: "operator")
    |> render_submit()

    assert view |> element("#operator-created") |> render() =~ "ha07-new@hub.idejo.test added."
    added = Operators.get_by_email("ha07-new@hub.idejo.test")
    assert added.role == "operator"

    assert hd(audit("operator.create") |> Enum.filter(&(&1.details["email"] == added.email))).actor ==
             owner.email

    view |> form("#operator-#{added.id}-role", role: "owner") |> render_change()
    assert Operators.get_operator!(added.id).role == "owner"
    assert [%{actor: actor, details: %{"role" => "owner"}}] = audit("operator.role")
    assert actor == owner.email

    view |> element("#operator-#{added.id}-remove") |> render_click()
    refute Operators.get_by_email("ha07-new@hub.idejo.test")
    assert [%{details: %{"email" => "ha07-new@hub.idejo.test"}}] = audit("operator.remove")
    # Not one's own account: no button, and refused.
    refute has_element?(view, "#operator-#{owner.id}-remove")
    assert {:error, :self} = Operators.remove_operator(owner, owner)
  end

  test "HA-07 the last owner stays an owner; operators manage no account" do
    {owner, _} = operator_fixture()
    {other, _} = operator_fixture()
    assert {:error, :last_owner} = Operators.set_role(owner, "operator", owner)

    {:ok, other} = Operators.set_role(other, "owner", owner)
    assert {:ok, %{role: "operator"}} = Operators.set_role(owner, "operator", other)
    owner = Operators.get_operator!(owner.id)

    # Now `other` is the only owner: it stays one, and an operator can change nothing.
    assert {:error, :last_owner} = Operators.set_role(other, "operator", other)
    assert {:error, :self} = Operators.remove_operator(other, other)
    assert {:error, :forbidden} = Operators.set_role(other, "operator", owner)
    assert {:error, :forbidden} = Operators.remove_operator(other, owner)
    assert {:error, :forbidden} = Operators.set_role(owner, "owner", owner)
  end

  test "HA-07 a removed operator's session ends", %{conn: conn} do
    {_owner_conn, owner, _} = sign_in(conn)
    {operator_conn, operator, _} = sign_in(build_conn(), "operator")
    assert {:ok, _view, _} = live(operator_conn, ~p"/")

    :ok = Operators.remove_operator(operator, owner)
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(operator_conn, ~p"/")
  end
end
