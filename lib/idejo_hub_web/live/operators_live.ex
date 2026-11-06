# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.OperatorsLive do
  @moduledoc """
  HA-07: operator accounts, for owners. Add one (its one-time password shown here once, as
  the command line does; two-factor set up at its first sign-in), change a role, remove an
  account. The last owner stays an owner, and nobody removes their own account.
  """
  use IdejoHubWeb, :live_view

  alias IdejoHub.Operators
  alias IdejoHub.Operators.Operator

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: "Operators", created: nil) |> load()}
  end

  @impl true
  def handle_event("add", %{"email" => email, "role" => role}, socket) do
    me = socket.assigns.current_operator

    if Operators.owner?(me) and role in Operator.roles() do
      case Operators.create_operator(email, role, me.email) do
        {:ok, operator, password} ->
          {:noreply,
           socket |> assign(created: %{email: operator.email, password: password}) |> load()}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, "Not added: #{errors(changeset)}")}
      end
    else
      {:noreply, put_flash(socket, :error, message(:forbidden))}
    end
  end

  def handle_event("role", %{"operator_id" => id, "role" => role}, socket) do
    operator = Operators.get_operator!(String.to_integer(id))

    case Operators.set_role(operator, role, socket.assigns.current_operator) do
      {:ok, changed} ->
        {:noreply,
         socket |> put_flash(:info, "#{changed.email} is now #{changed.role}.") |> load()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, message(reason)) |> load()}
    end
  end

  def handle_event("remove", %{"id" => id}, socket) do
    operator = Operators.get_operator!(String.to_integer(id))

    case Operators.remove_operator(operator, socket.assigns.current_operator) do
      :ok -> {:noreply, socket |> put_flash(:info, "#{operator.email} removed.") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, message(reason))}
    end
  end

  defp load(socket),
    do: assign(socket, operators: Operators.list_operators(), roles: Operator.roles())

  defp message(:forbidden), do: "Only owners manage operator accounts."
  defp message(:last_owner), do: "The last owner stays an owner: make another owner first."
  defp message(:self), do: "You cannot remove your own account."
  defp message(:invalid_role), do: "Choose owner or operator."
  defp message(other), do: "Not done: #{inspect(other)}"

  defp errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_operator={@current_operator}>
      <h1 class="text-2xl font-semibold">Operators</h1>
      <p class="text-sm">
        Owners manage these accounts; operators do everything else in the Hub. Everyone signs in
        with a password and two-factor sign-in, set up at the first sign-in.
      </p>

      <div :if={@created} id="operator-created" role="status" class="alert alert-success">
        <span>
          {@created.email} added. Their password, shown only now: <code>{@created.password}</code>.
          Give it to them in person or over a secure channel.
        </span>
      </div>

      <table id="operators" class="table table-sm">
        <thead>
          <tr>
            <th>Email</th>
            <th>Role</th>
            <th>Two-factor</th>
            <th><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={o <- @operators} id={"operator-#{o.id}"}>
            <td>
              {o.email}
              <span :if={o.id == @current_operator.id} class="text-sm">(you)</span>
            </td>
            <td>
              <form id={"operator-#{o.id}-role"} phx-change="role" class="inline">
                <input type="hidden" name="operator_id" value={o.id} />
                <label>
                  <span class="sr-only">Role of {o.email}</span>
                  <select name="role" class="select select-sm">
                    <option :for={r <- @roles} value={r} selected={r == o.role}>{r}</option>
                  </select>
                </label>
              </form>
            </td>
            <td>{if Operators.two_factor?(o), do: "set up", else: "at first sign-in"}</td>
            <td>
              <button
                :if={o.id != @current_operator.id}
                id={"operator-#{o.id}-remove"}
                phx-click="remove"
                phx-value-id={o.id}
                data-confirm={"Remove #{o.email}? Their sessions end now."}
                class="btn btn-sm btn-ghost"
              >
                Remove
              </button>
            </td>
          </tr>
        </tbody>
      </table>

      <form id="add-operator" phx-submit="add" class="flex flex-wrap gap-2 items-end">
        <label>
          <span class="block text-sm font-medium">Email</span>
          <input name="email" type="email" required class="input input-sm" autocomplete="off" />
        </label>
        <label>
          <span class="block text-sm font-medium">Role</span>
          <select name="role" class="select select-sm">
            <option value="operator" selected>operator</option>
            <option value="owner">owner</option>
          </select>
        </label>
        <button class="btn btn-sm btn-primary">Add operator</button>
      </form>
    </Layouts.app>
    """
  end
end
