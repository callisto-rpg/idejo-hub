# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.OP02OffsiteSettingsTest do
  @moduledoc "OP-02: Settings shows the off-server storage, set in deploy/.env, never its keys."
  use IdejoHubWeb.ConnCase, async: false

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.Operations.Offsite

  @moduletag req: "OP-02"

  setup %{conn: conn} do
    original = Application.fetch_env!(:idejo_hub, Offsite)
    on_exit(fn -> Application.put_env(:idejo_hub, Offsite, original) end)
    {conn, _operator, _} = sign_in(conn)
    %{conn: conn, original: original}
  end

  test "off until a bucket is set", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/settings")
    assert view |> element("#offsite-storage") |> render() =~ "off"
  end

  test "shows endpoint, bucket and public key, not the access keys", %{
    conn: conn,
    original: original
  } do
    Application.put_env(
      :idejo_hub,
      Offsite,
      Keyword.merge(original,
        endpoint: "https://s3.example.test",
        bucket: "backups",
        prefix: "hub1/",
        access_key_id: "AKIDEXAMPLE",
        secret_access_key: "s3-secret-key",
        recipient: "age143llv2nsl3c2832hcsmj4vhqkwp24y23zqd9cvsan4vk0cv3tuaqpth6vt"
      )
    )

    {:ok, _view, html} = live(conn, ~p"/settings")
    assert html =~ "https://s3.example.test/backups/hub1/"
    assert html =~ "age143llv2nsl3c2832hcsmj4vhqkwp24y23zqd9cvsan4vk0cv3tuaqpth6vt"
    refute html =~ "s3-secret-key"
    refute html =~ "AKIDEXAMPLE"
  end
end
