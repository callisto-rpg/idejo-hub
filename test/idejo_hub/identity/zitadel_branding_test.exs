# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.ZitadelBrandingTest do
  @moduledoc """
  Zitadel's sign-in screens in idejo's look (steward request 2026-11-06): the Hub sets the
  instance's branding (colours, the idejo logo) when it configures Zitadel, only when it
  differs. Checked here against Zitadel's API shape; against Zitadel v4.20.1 itself by hand
  (the PR has the screenshots).
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias IdejoHub.Identity.Zitadel

  @moduletag req: "ID-01"

  setup do
    token = Path.join(System.tmp_dir!(), "brand-#{System.unique_integer([:positive])}.pat")
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

  # A Zitadel answering the login policy and SMTP as already set, and the label policy as
  # given; every request is sent to the test process.
  defp zitadel(label) do
    test = self()

    Req.Test.stub(Zitadel, fn conn ->
      {:ok, body, conn} = read_body(conn)

      send(
        test,
        {:request, conn.method, conn.request_path, get_req_header(conn, "content-type"), body}
      )

      case {conn.method, conn.request_path} do
        {"GET", "/admin/v1/policies/login"} ->
          json(conn, %{
            "policy" => %{
              "allowUsernamePassword" => true,
              "passwordlessType" => "PASSWORDLESS_TYPE_ALLOWED",
              "secondFactors" => ["SECOND_FACTOR_TYPE_OTP", "SECOND_FACTOR_TYPE_U2F"]
            }
          })

        {"GET", "/admin/v1/policies/label"} ->
          json(conn, %{"policy" => label})

        {"POST", "/admin/v1/smtp/_search"} ->
          json(conn, %{"result" => []})

        _ ->
          json(conn, %{})
      end
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:request, method, path, type, body} -> requests([{method, path, type, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "Zitadel's default branding becomes idejo's colours and logo, then is activated" do
    zitadel(%{
      "primaryColor" => "#5469d4",
      "warnColor" => "#cd3d56",
      "hideLoginNameSuffix" => true
    })

    assert :ok = Zitadel.configure(nil, "noreply@id.idejo.test")
    sent = requests()

    {"PUT", _, _, body} = Enum.find(sent, &match?({"PUT", "/admin/v1/policies/label", _, _}, &1))
    body = Jason.decode!(body)
    assert body["primaryColor"] == "#daa304"
    assert body["backgroundColor"] == "#fdfcf6"
    assert body["backgroundColorDark"] == "#000000"
    assert body["themeMode"] == "THEME_MODE_AUTO"
    # What the operator or Zitadel set otherwise is kept.
    assert body["warnColor"] == "#cd3d56"
    assert body["hideLoginNameSuffix"] == true

    uploads =
      for {"POST", "/assets/v1/instance/policy/label/" <> kind, [type], body} <- sent do
        assert type =~ "multipart/form-data"
        assert body =~ ~s(name="file"; filename=")
        assert body =~ "\x89PNG"
        kind
      end

    assert uploads == ["logo", "logo/dark", "icon", "icon/dark"]

    paths = Enum.map(sent, &elem(&1, 1))
    activate = Enum.find_index(paths, &(&1 == "/admin/v1/policies/label/_activate"))

    assert activate >
             Enum.find_index(paths, &(&1 == "/assets/v1/instance/policy/label/icon/dark"))
  end

  test "already in idejo's look, nothing is sent" do
    zitadel(%{
      "primaryColor" => "#daa304",
      "backgroundColor" => "#fdfcf6",
      "fontColor" => "#000000",
      "primaryColorDark" => "#daa304",
      "backgroundColorDark" => "#000000",
      "fontColorDark" => "#e9e8e2",
      "themeMode" => "THEME_MODE_AUTO",
      "logoUrl" => "https://id.idejo.test/assets/v1/x/logo",
      "logoUrlDark" => "https://id.idejo.test/assets/v1/x/logo-dark",
      "iconUrl" => "https://id.idejo.test/assets/v1/x/icon",
      "iconUrlDark" => "https://id.idejo.test/assets/v1/x/icon-dark"
    })

    assert :ok = Zitadel.configure(nil, "noreply@id.idejo.test")
    paths = requests() |> Enum.map(&elem(&1, 1))
    refute Enum.any?(paths, &String.starts_with?(&1, "/assets/"))
    refute "/admin/v1/policies/label/_activate" in paths
  end
end
