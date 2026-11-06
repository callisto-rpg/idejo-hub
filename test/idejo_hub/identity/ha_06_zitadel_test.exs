# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.HA06ZitadelTest do
  @moduledoc """
  HA-06: the Zitadel adapter's search, lock and unlock, against Zitadel's answers (taken
  from Zitadel v4.20.1, 2026-11-06).
  """
  use ExUnit.Case, async: false

  import Plug.Conn

  alias IdejoHub.Identity.Zitadel

  @moduletag req: "HA-06"

  setup do
    token = Path.join(System.tmp_dir!(), "ha06-#{System.unique_integer([:positive])}.pat")
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

  defp json(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))

  test "HA-06 search asks for humans whose email, name or username contains the text" do
    Req.Test.stub(Zitadel, fn conn ->
      assert {conn.method, conn.request_path} == {"POST", "/v2/users"}
      assert get_req_header(conn, "authorization") == ["Bearer pat-token"]
      {:ok, body, conn} = read_body(conn)
      body = Jason.decode!(body)
      assert body["query"]["limit"] == 50
      [type, %{"orQuery" => %{"queries" => queries}}] = body["queries"]
      assert type == %{"typeQuery" => %{"type" => "TYPE_HUMAN"}}

      assert %{
               "emailQuery" => %{
                 "emailAddress" => "ADA",
                 "method" => "TEXT_QUERY_METHOD_CONTAINS_IGNORE_CASE"
               }
             } in queries

      assert Enum.any?(queries, &Map.has_key?(&1, "displayNameQuery"))
      assert Enum.any?(queries, &Map.has_key?(&1, "userNameQuery"))

      json(conn, 200, %{
        "details" => %{"totalResult" => "1"},
        "result" => [
          %{
            "userId" => "398338698392895491",
            "state" => "USER_STATE_LOCKED",
            "username" => "ada@x.test",
            "human" => %{
              "profile" => %{"displayName" => "Ada Lovelace"},
              "email" => %{"email" => "ada@x.test", "isVerified" => true}
            }
          }
        ]
      })
    end)

    assert {:ok, [person]} = Zitadel.search_people("ADA")

    assert person == %{
             id: "398338698392895491",
             email: "ada@x.test",
             email_verified: true,
             display_name: "Ada Lovelace",
             username: "ada@x.test",
             state: "locked"
           }
  end

  test "HA-06 locking a locked person, or unlocking one who is not, is done already" do
    Req.Test.stub(Zitadel, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v2/users/u1/lock"} ->
          json(conn, 400, %{
            "code" => 9,
            "message" => "User is not active or initial (COMMAND-lgws8wtsqf)"
          })

        {"GET", "/v2/users/u1"} ->
          json(conn, 200, %{
            "user" => %{
              "state" => "USER_STATE_LOCKED",
              "human" => %{"email" => %{"email" => "a@x.test"}, "profile" => %{}}
            }
          })

        {"POST", "/v2/users/u1/unlock"} ->
          json(conn, 400, %{"code" => 9, "message" => "User is not locked (COMMAND-olb9vb0oca)"})
      end
    end)

    assert Zitadel.lock_person("u1") == :ok
    assert Zitadel.unlock_person("u1") == :ok
  end

  test "HA-06 a person who cannot be locked (inactive) is an error" do
    Req.Test.stub(Zitadel, fn conn ->
      case conn.method do
        "POST" -> json(conn, 400, %{"code" => 9, "message" => "User is not active or initial"})
        "GET" -> json(conn, 200, %{"user" => %{"state" => "USER_STATE_INACTIVE", "human" => %{}}})
      end
    end)

    assert Zitadel.lock_person("u2") == {:error, {:state, "inactive"}}
  end

  test "HA-06 lock and unlock are POSTs to the person's lock and unlock" do
    Req.Test.stub(Zitadel, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path in ["/v2/users/u3/lock", "/v2/users/u3/unlock"]
      json(conn, 200, %{"details" => %{"sequence" => "3"}})
    end)

    assert Zitadel.lock_person("u3") == :ok
    assert Zitadel.unlock_person("u3") == :ok
  end
end
