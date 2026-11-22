# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.ID02ZitadelEmailsTest do
  @moduledoc """
  Zitadel's emails to a new idejo ID (steward request 2026-11-22): one "Verify email", whose
  link goes on to choosing a password, no invite as well; Zitadel's own password notice off
  (the Hub sends its own, for later changes); its login going to the members' inbox.
  Checked here against Zitadel's API shape.
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias IdejoHub.Identity.Zitadel

  @moduletag req: "ID-02"

  setup do
    token = Path.join(System.tmp_dir!(), "emails-#{System.unique_integer([:positive])}.pat")
    File.write!(token, "pat-token\n")
    original = Application.get_env(:idejo_hub, IdejoHub.Identity)

    Application.put_env(
      :idejo_hub,
      IdejoHub.Identity,
      Keyword.merge(original || [],
        adapter: Zitadel,
        api_url: "http://zitadel:8080",
        domain: "id.idejo.test",
        token_file: token
      )
    )

    Application.put_env(:idejo_hub, :zitadel_req_options, plug: {Req.Test, Zitadel})

    on_exit(fn ->
      Application.put_env(:idejo_hub, IdejoHub.Identity, original)
      Application.delete_env(:idejo_hub, :zitadel_req_options)
      File.rm(token)
    end)
  end

  defp json(conn, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(body))

  # A Zitadel already configured but for its notification policy (`notify`); every request is
  # sent to the test process.
  defp zitadel(notify, events \\ %{}) do
    test = self()

    Req.Test.stub(Zitadel, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(test, {:request, conn.method, conn.request_path, body})

      case {conn.method, conn.request_path} do
        {"GET", "/admin/v1/policies/login"} ->
          json(conn, %{
            "policy" => %{
              "allowUsernamePassword" => true,
              "passwordlessType" => "PASSWORDLESS_TYPE_ALLOWED",
              "secondFactors" => ["SECOND_FACTOR_TYPE_OTP", "SECOND_FACTOR_TYPE_U2F"]
            }
          })

        {"GET", "/admin/v1/policies/notification"} ->
          json(conn, %{"policy" => notify})

        {"GET", "/admin/v1/policies/label"} ->
          json(conn, %{"policy" => %{}})

        {"POST", "/admin/v1/smtp/_search"} ->
          json(conn, %{"result" => []})

        {"POST", "/admin/v1/events/_search"} ->
          json(conn, %{"events" => Map.get(events, Jason.decode!(body)["aggregateId"], [])})

        {"POST", "/v2/users/human"} ->
          json(conn, %{"userId" => "u-1"})

        _ ->
          json(conn, %{})
      end
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:request, method, path, body} -> requests([{method, path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sent(method, path) do
    Enum.find_value(requests(), fn
      {^method, ^path, body} -> Jason.decode!(body)
      _other -> nil
    end)
  end

  test "ID-02 a new idejo ID gets one email: verify, then choose a password" do
    zitadel(%{})

    assert {:ok, "u-1"} =
             Zitadel.create_person(%{
               email: "ana@example.test",
               display_name: "Ana",
               given_name: "Sennoma",
               family_name: "Ulo",
               language: "en"
             })

    all = requests()
    {"POST", _, body} = Enum.find(all, &match?({"POST", "/v2/users/human", _}, &1))
    template = get_in(Jason.decode!(body), ["email", "sendCode", "urlTemplate"])
    assert template =~ "https://id.idejo.test/ui/v2/login/verify?code={{.Code}}"
    refute template =~ "invite"
    refute Enum.any?(all, fn {_, path, _} -> path =~ "invite_code" end)
  end

  test "ID-02 Zitadel's own password notice is turned off" do
    zitadel(%{"passwordChange" => true})
    assert :ok = Zitadel.configure(nil, "noreply@id.idejo.test", nil)
    assert sent("PUT", "/admin/v1/policies/notification") == %{"passwordChange" => false}
  end

  test "ID-02 already off (Zitadel leaves false out), nothing is sent" do
    zitadel(%{})
    assert :ok = Zitadel.configure(nil, "noreply@id.idejo.test", nil)
    assert sent("PUT", "/admin/v1/policies/notification") == nil
  end

  test "ID-02 with a members' inbox, Zitadel's login goes there; without, it is left alone" do
    zitadel(%{})
    assert :ok = Zitadel.configure(nil, "noreply@id.idejo.test", "https://my.idejo.test/")
    policy = sent("PUT", "/admin/v1/policies/login")
    assert policy["defaultRedirectUri"] == "https://my.idejo.test/"
    assert policy["allowRegister"] == false

    assert :ok = Zitadel.configure(nil, "noreply@id.idejo.test", nil)
    assert sent("PUT", "/admin/v1/policies/login") == nil
  end

  test "ID-02 password changes: the person's first is told apart from later ones" do
    first = %{
      "aggregate" => %{"id" => "u-1"},
      "creationDate" => "2026-11-22T10:00:00.123456789Z"
    }

    later = %{
      "aggregate" => %{"id" => "u-1"},
      "creationDate" => "2026-11-22T11:00:00.5Z"
    }

    zitadel(%{}, %{nil => [first, later], "u-1" => [first]})

    assert {:ok, [%{user_id: "u-1", first: true}, %{user_id: "u-1", first: false}]} =
             Zitadel.password_changes_since(nil)
  end
end
