# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.OutsideForumsTest do
  @moduledoc """
  Outside forums (steward decisions 2026-11-06): an idejo server hosted elsewhere registers
  for an idejo ID client by proving it controls its address, asks to be in the directory with
  that client's credentials, and appears there once an operator approves.
  """
  use IdejoHubWeb.ConnCase, async: false

  import IdejoHub.OperatorFixtures
  import Phoenix.LiveViewTest

  alias IdejoHub.{Audit, Identity, Repo}
  alias IdejoHub.Identity.{Fake, OutsideForum, OutsideForums, Proof}

  @id_host "id.idejo.test"

  setup do
    Fake.start()
    original = Application.get_env(:idejo_hub, Identity)
    Application.put_env(:idejo_hub, Identity, Keyword.put(original, :adapter, Fake))
    # Every name resolves to a public address but `private.example`'s.
    Application.put_env(:idejo_hub, :proof_resolver, fn
      "private.example" -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 5}]}
      "nowhere.example" -> {:error, :nxdomain}
      _host -> {:ok, [{93, 184, 216, 34}]}
    end)

    Application.put_env(:idejo_hub, :proof_req_options, plug: {Req.Test, Proof})

    on_exit(fn ->
      Application.put_env(:idejo_hub, Identity, original)
      Application.delete_env(:idejo_hub, :proof_resolver)
      Application.delete_env(:idejo_hub, :proof_req_options)
    end)

    :ok
  end

  defp api(method, path, body, auth \\ nil) do
    conn =
      %{
        build_conn()
        | host: @id_host,
          remote_ip: {10, 9, 0, rem(System.unique_integer([:positive]), 250)}
      }
      |> put_req_header("accept", "application/json")

    conn =
      if auth,
        do:
          put_req_header(
            conn,
            "authorization",
            Plug.BasicAuth.encode_basic_auth(elem(auth, 0), elem(auth, 1))
          ),
        else: conn

    case method do
      :get -> get(conn, path)
      :post -> post(conn, path, body)
      :put -> put(conn, path, body)
    end
  end

  # The forum serves `proof` at the well-known address.
  defp serve(proof, host \\ "club.example.org") do
    Req.Test.stub(Proof, fn conn ->
      assert conn.request_path == "/.well-known/idejo-id-registration"
      assert Plug.Conn.get_req_header(conn, "host") == [host]
      Plug.Conn.send_resp(conn, 200, proof <> "\n")
    end)
  end

  defp register!(host \\ "club.example.org", name \\ "Chess club") do
    started = api(:post, "/account/api/registrations", %{"host" => host, "name" => name})
    assert %{"registration" => registration, "proof" => proof} = json_response(started, 201)
    serve(proof, host)

    api(:post, "/account/api/registrations/verify", %{"registration" => registration})
    |> json_response(200)
  end

  test "a forum proves its address and gets its idejo ID client, once" do
    started =
      api(:post, "/account/api/registrations", %{
        "host" => "Club.Example.org",
        "name" => "Chess club"
      })

    assert %{
             "registration" => registration,
             "proof" => proof,
             "proof_path" => "/.well-known/idejo-id-registration",
             "expires_in" => 600
           } = json_response(started, 201)

    # Only hashes are kept.
    stored = Repo.get_by!(OutsideForum, host: "club.example.org")
    refute stored.registration_hash == registration
    assert stored.status == "pending"

    serve(proof)
    verified = api(:post, "/account/api/registrations/verify", %{"registration" => registration})

    assert %{
             "issuer" => "https://id.idejo.test",
             "client_id" => client_id,
             "client_secret" => secret,
             "label" => "idejo ID",
             "sign_up_url" => "https://id.idejo.test/account/sign-up",
             "directory_url" => "https://forums.idejo.test/"
           } = json_response(verified, 200)

    assert get_resp_header(verified, "cache-control") == ["no-store"]
    assert [%{client_id: ^client_id}] = Map.values(Fake.clients())

    assert %OutsideForum{status: "registered", display_name: "Chess club"} =
             OutsideForums.authenticate(client_id, secret)

    refute OutsideForums.authenticate(client_id, "wrong")

    # The key works once.
    assert json_response(
             api(:post, "/account/api/registrations/verify", %{"registration" => registration}),
             404
           )["error"] == "unknown"

    assert Repo.get_by!(Audit.Entry, action: "identity.outside_forum.register", outcome: "ok").details[
             "host"
           ] ==
             "club.example.org"
  end

  test "a wrong proof, a private or missing address, and an expired one give nothing" do
    for {host, served, error} <- [
          {"club.example.org", "not-the-proof", "proof_failed"},
          {"private.example", nil, "proof_failed"},
          {"nowhere.example", nil, "proof_failed"}
        ] do
      %{"registration" => registration, "proof" => proof} =
        api(:post, "/account/api/registrations", %{"host" => host, "name" => "X"})
        |> json_response(201)

      serve(served || proof, host)

      response =
        api(:post, "/account/api/registrations/verify", %{"registration" => registration})

      assert json_response(response, 422)["error"] == error, host
    end

    assert json_response(
             api(:post, "/account/api/registrations/verify", %{"registration" => "made-up"}),
             404
           )

    assert Fake.clients() == %{}

    %{"registration" => registration, "proof" => proof} =
      api(:post, "/account/api/registrations", %{"host" => "late.example.org", "name" => "Late"})
      |> json_response(201)

    Repo.update_all(OutsideForum, set: [challenge_expires_at: ~U[2020-01-01 00:00:00Z]])
    serve(proof, "late.example.org")

    assert json_response(
             api(:post, "/account/api/registrations/verify", %{"registration" => registration}),
             410
           )
  end

  test "the Hub's own hosts, addresses and odd names are refused" do
    for host <- [
          "tennis.idejo.test",
          "idejo.test",
          "id.idejo.test",
          "localhost",
          "10.0.0.1",
          "a b.org",
          "",
          "x.123"
        ] do
      response = api(:post, "/account/api/registrations", %{"host" => host, "name" => "X"})
      assert json_response(response, 422)["error"] == "invalid_host", host
    end

    assert json_response(
             api(:post, "/account/api/registrations", %{"host" => "ok.example.org", "name" => ""}),
             422
           )["error"] ==
             "invalid_name"
  end

  test "asking again for a registered host changes nothing until proven, then renews the secret" do
    %{"client_id" => client_id, "client_secret" => old} = register!()

    # Someone else asks for the same host, with another name: the forum keeps its name and
    # its secret.
    api(:post, "/account/api/registrations", %{
      "host" => "club.example.org",
      "name" => "Taken over"
    })

    assert %OutsideForum{display_name: "Chess club"} = OutsideForums.authenticate(client_id, old)

    # The forum itself registers again (a lost secret): same client, new secret.
    %{"client_id" => ^client_id, "client_secret" => new} =
      register!("club.example.org", "Chess club")

    refute new == old
    refute OutsideForums.authenticate(client_id, old)
    assert OutsideForums.authenticate(client_id, new)
  end

  test "listing: the forum asks, an operator approves, the directory shows it", %{conn: conn} do
    %{"client_id" => id, "client_secret" => secret} = register!()

    assert json_response(api(:get, "/account/api/listing", nil, {id, secret}), 200) == %{
             "listing" => "none"
           }

    assert json_response(api(:get, "/account/api/listing", nil, {id, "wrong"}), 401)

    assert json_response(
             api(:put, "/account/api/listing", %{"listed" => true}, {"nobody", "x"}),
             401
           )

    asked =
      api(:put, "/account/api/listing", %{"listed" => true, "name" => "Chess club"}, {id, secret})

    assert json_response(asked, 200) == %{"listing" => "requested"}

    directory = fn -> %{build_conn() | host: "forums.idejo.test"} |> get("/") end
    refute html_response(directory.(), 200) =~ "club.example.org"

    # The operator's page lists the request first and approves it.
    {signed_in, _operator, _password} = sign_in(conn)
    {:ok, view, html} = live(signed_in, ~p"/outside-forums")
    assert html =~ "asks to be listed"
    forum = Repo.get_by!(OutsideForum, host: "club.example.org")
    view |> element("#outside-#{forum.id} button", "Approve") |> render_click()
    assert render(view) =~ "club.example.org: listed."

    page = directory.()
    html = html_response(page, 200)
    assert html =~ ~s(href="https://club.example.org/")
    assert html =~ ~s(src="https://club.example.org/logo")
    # Its logo's host is allowed on that page.
    assert [csp] = get_resp_header(page, "content-security-policy")
    assert csp =~ "img-src 'self' data: blob: https://*.idejo.test https://club.example.org"

    assert json_response(api(:get, "/account/api/listing", nil, {id, secret}), 200) == %{
             "listing" => "approved"
           }

    # A new name goes back to the operator; leaving takes it out at once.
    assert json_response(
             api(
               :put,
               "/account/api/listing",
               %{"listed" => true, "name" => "Chess & Go"},
               {id, secret}
             ),
             200
           ) ==
             %{"listing" => "requested"}

    refute html_response(directory.(), 200) =~ "club.example.org"

    assert json_response(
             api(:put, "/account/api/listing", %{"listed" => false}, {id, secret}),
             200
           ) == %{"listing" => "none"}
  end

  test "a refused forum stays out until it leaves and asks again; removing ends its client", %{
    conn: conn
  } do
    %{"client_id" => id, "client_secret" => secret} = register!()
    api(:put, "/account/api/listing", %{"listed" => true}, {id, secret})
    forum = Repo.get_by!(OutsideForum, host: "club.example.org")

    assert {:ok, %{listing: "refused"}} = OutsideForums.decide(forum.id, "refused", "op@hub.test")

    assert json_response(
             api(:put, "/account/api/listing", %{"listed" => true}, {id, secret}),
             200
           ) == %{"listing" => "refused"}

    api(:put, "/account/api/listing", %{"listed" => false}, {id, secret})

    assert json_response(
             api(:put, "/account/api/listing", %{"listed" => true}, {id, secret}),
             200
           ) == %{"listing" => "requested"}

    {signed_in, _operator, _password} = sign_in(conn)
    {:ok, view, _html} = live(signed_in, ~p"/outside-forums")
    view |> element("#outside-#{forum.id} button", "Remove") |> render_click()
    assert Fake.clients() == %{}
    refute OutsideForums.authenticate(id, secret)
    assert Repo.get_by!(Audit.Entry, action: "identity.outside_forum.remove").actor =~ "@"
  end

  test "sign-up leads back to a registered outside forum" do
    register!()

    html =
      %{build_conn() | host: @id_host}
      |> get("/account/sign-up?return_to=https://club.example.org/")
      |> html_response(200)

    assert html =~ "Chess club"
  end
end
