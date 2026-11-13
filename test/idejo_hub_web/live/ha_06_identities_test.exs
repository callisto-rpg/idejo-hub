# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.HA06IdentitiesTest do
  @moduledoc """
  HA-06: identity administration: search identities, lock an identity for abuse, handle
  deletion requests.
  """
  use IdejoHubWeb.ConnCase, async: false
  use Oban.Testing, repo: IdejoHub.Repo

  import Ecto.Query
  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.Audit.Entry
  alias IdejoHub.{Identity, Repo}
  alias IdejoHub.Identity.{Deletion, Fake, MemberWorker}

  @moduletag req: "HA-06"
  @moduletag :capture_log

  setup %{conn: conn} do
    Fake.start()
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)

    {:ok, ada} = person("ada@x.test", "Ada Lovelace")
    {:ok, bob} = person("bob@x.test", "Bob Builder")
    {conn, operator, _} = sign_in(conn)
    %{conn: conn, operator: operator, ada: ada, bob: bob}
  end

  defp person(email, name),
    do:
      Fake.create_person(%{
        email: email,
        email_verified: true,
        display_name: name,
        given_name: "Sennoma",
        family_name: "Ulo",
        language: "en"
      })

  defp entries(action), do: Repo.all(from e in Entry, where: e.action == ^action)

  test "HA-06 search by email or name, kept in the address", %{conn: conn, ada: ada} do
    {:ok, view, _} = live(conn, ~p"/identities")
    view |> form("#identity-search", search: %{q: "LOVE"}) |> render_submit()
    assert_patch(view, ~p"/identities?q=LOVE")

    assert has_element?(view, ~s(#identity-#{ada} a[href="/identities/#{ada}"]), "Ada Lovelace")
    assert has_element?(view, "#identity-#{ada}", "active")
    refute has_element?(view, "#identities", "Bob")

    {:ok, view, _} = live(conn, ~p"/identities?q=nobody")
    assert has_element?(view, "#identities-none")
  end

  test "HA-06 lock for abuse with a reason, then unlock; audited without the email", %{
    conn: conn,
    operator: operator,
    ada: ada
  } do
    {:ok, view, _} = live(conn, ~p"/identities/#{ada}")
    assert has_element?(view, "#identity-state", "active")
    assert has_element?(view, "#identity-facts", "ada@x.test")

    # No reason, no lock.
    assert view |> form("#lock-form", reason: "  ") |> render_submit() =~ "Give a reason"
    assert Fake.people()[ada][:state] in [nil, "active"]

    view |> form("#lock-form", reason: "spam on three forums") |> render_submit()
    assert has_element?(view, "#identity-state", "locked")
    assert Fake.people()[ada].state == "locked"

    [lock] = entries("identity.lock")
    assert lock.actor == operator.email
    assert lock.details == %{"subject" => ada, "reason" => "spam on three forums"}

    view |> element("#unlock") |> render_click()
    assert has_element?(view, "#identity-state", "active")
    assert [%{details: %{"subject" => ^ada}}] = entries("identity.unlock")
    refute inspect(entries("identity.lock") ++ entries("identity.unlock")) =~ "ada@x.test"

    # The ID's page lists what the audit log holds about it.
    assert has_element?(view, "#identity-log", "identity.lock")
  end

  test "HA-06 a deletion asked of the operator: the email typed again, who asked and how", %{
    conn: conn,
    operator: operator,
    ada: ada
  } do
    {:ok, view, _} = live(conn, ~p"/identities/#{ada}")

    html =
      view
      |> form("#delete-form", email: "bob@x.test", reason: "email from Ada, 2026-11-06")
      |> render_submit()

    assert html =~ "not this idejo ID"
    assert Repo.get(Deletion, ada) == nil

    assert view |> form("#delete-form", email: "ADA@x.test", reason: " ") |> render_submit() =~
             "Say who asked"

    view
    |> form("#delete-form", email: "ADA@x.test", reason: "email from Ada, 2026-11-06")
    |> render_submit()

    assert has_element?(view, "#deletion-running")
    assert %Deletion{error: nil, finished_at: nil} = Repo.get(Deletion, ada)
    assert_enqueued(worker: MemberWorker, args: %{"subject" => ada, "choice" => "identity"})

    [asked] = entries("identity.delete")
    assert asked.actor == operator.email and asked.outcome == "requested"
    assert asked.details == %{"subject" => ada, "reason" => "email from Ada, 2026-11-06"}

    # The deletion runs as the member's own (ID-06): the provider forgets the person.
    assert :ok = perform_job(MemberWorker, %{"subject" => ada, "choice" => "identity"})
    assert Fake.people()[ada] == nil

    {:ok, view, _} = live(conn, ~p"/identities/#{ada}")
    assert has_element?(view, "#deletion-done")
  end

  test "HA-06 the deletion requests: a stopped one says why and is retried", %{
    conn: conn,
    ada: ada,
    bob: bob
  } do
    now = DateTime.utc_now(:second)

    Repo.insert!(%Deletion{
      subject: ada,
      requested_at: now,
      error: "tennis.idejo.test: last_owner"
    })

    Repo.insert!(%Deletion{subject: bob, requested_at: DateTime.add(now, -60)})

    {:ok, view, _} = live(conn, ~p"/identities")
    assert has_element?(view, "#deletion-#{ada}", "stopped")
    assert has_element?(view, "#deletion-#{ada}", "last_owner")
    assert has_element?(view, "#deletion-#{bob}", "under way")
    refute has_element?(view, "#deletion-#{bob} button")

    view |> element("#deletion-#{ada} button", "Retry") |> render_click()
    assert has_element?(view, "#deletion-#{ada}", "under way")
    assert %Deletion{error: nil} = Repo.get(Deletion, ada)
    assert_enqueued(worker: MemberWorker, args: %{"subject" => ada, "choice" => "identity"})
    assert [%{details: %{"retry" => true}}] = entries("identity.delete")
  end

  test "HA-06 linked in the header; without a provider, says so", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, ~s(a[href="/identities"]), "idejo IDs")

    Application.put_env(
      :idejo_hub,
      Identity,
      Keyword.put(Application.get_env(:idejo_hub, Identity), :adapter, nil)
    )

    {:ok, view, _} = live(conn, ~p"/identities")
    assert has_element?(view, "#identities-disabled")
  end
end
