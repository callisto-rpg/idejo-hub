# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.ID02PasswordNoticesTest do
  @moduledoc """
  An idejo ID's password changed (steward request 2026-11-22): the Hub emails its owner, with
  a button to the members' inbox; never for the first password, chosen right after sign-up,
  and never for a change made before the Hub started reading.
  """
  use IdejoHub.DataCase, async: false

  import Swoosh.TestAssertions

  alias IdejoHub.{Forums, Identity, Repo, Secrets}
  alias IdejoHub.Forums.Forum
  alias IdejoHub.Identity.{Fake, Members, PasswordNotices, SyncWorker}

  @moduletag req: "ID-02"

  setup do
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    on_exit(fn -> Application.put_env(:idejo_hub, Identity, original) end)
    Fake.start()

    {:ok, id} =
      Fake.create_person(%{
        email: "ana@example.test",
        display_name: "Ana",
        given_name: "Sennoma",
        family_name: "Ulo",
        language: "en"
      })

    %{id: id}
  end

  defp inbox! do
    context = &Forums.context("inbox", &1)

    Repo.insert!(%Forum{
      subdomain: "inbox",
      kind: "inbox",
      display_name: "idejo",
      listed: false,
      owner_email: "o@x.test",
      idejo_version: "0.3.5",
      memory_mb: 384,
      cpus: 0.5,
      status: "running",
      secret_key_base_enc: Secrets.encrypt("k", context.(:secret_key_base)),
      db_password_enc: Secrets.encrypt("pw", context.(:db_password))
    })
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  test "ID-02 the first run only starts reading: nobody hears of an older change", %{id: id} do
    Fake.password_changed(id, false, ago(60))
    assert :ok = PasswordNotices.run()
    assert_no_email_sent()
    assert Members.state().password_events_since
  end

  test "ID-02 a later change is emailed, its button to the members' inbox", %{id: id} do
    inbox!()
    assert :ok = PasswordNotices.run()
    Fake.password_changed(id, false)
    assert :ok = PasswordNotices.run()

    assert_email_sent(fn email ->
      assert email.to == [{"", "ana@example.test"}]
      assert email.subject == "Your idejo ID password was changed"
      assert {"idejo ID", _sender} = email.from
      assert email.html_body =~ ~s(href="https://my.idejo.test/")
      assert email.html_body =~ "Go to your inbox"
      assert email.text_body =~ "https://my.idejo.test/"
    end)

    # Read once: the next run sends nothing more.
    assert :ok = PasswordNotices.run()
    assert_no_email_sent()
  end

  test "ID-02 the first password, chosen after sign-up, gets no notice", %{id: id} do
    assert :ok = PasswordNotices.run()
    Fake.password_changed(id, true)
    assert :ok = PasswordNotices.run()
    assert_no_email_sent()
  end

  test "ID-02 without a members' inbox, the button leads to the idejo ID's page", %{id: id} do
    assert :ok = PasswordNotices.run()
    Fake.password_changed(id, false)
    assert :ok = PasswordNotices.run()

    assert_email_sent(fn email ->
      assert email.html_body =~ ~s(href="https://id.idejo.test/account")
    end)
  end

  test "ID-02 the five-minute sync reads the password changes too", %{id: id} do
    assert :ok = PasswordNotices.run()
    Fake.password_changed(id, false)
    assert :ok = SyncWorker.perform(%Oban.Job{args: %{}})
    assert_email_sent(subject: "Your idejo ID password was changed")
  end
end
