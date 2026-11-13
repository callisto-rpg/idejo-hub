# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.Proof do
  @moduledoc """
  Proof that a server asking for an idejo ID client controls its address (steward decisions
  2026-11-06; extra review: DV-06): the Hub fetches
  `https://<host>/.well-known/idejo-id-registration`, which must answer the proof the Hub
  gave. Only public addresses are asked (never the Hub's own networks: every address the
  name resolves to must be public, and the request goes to the one checked, so DNS cannot
  change it in between), over https with the certificate checked against the name, no
  redirects, five seconds, 256 bytes at most.
  """
  import Bitwise

  @path "/.well-known/idejo-id-registration"

  @doc "Where the forum serves the proof."
  def path, do: @path

  @doc "The text `host` serves at `path/0`, trimmed."
  @spec fetch(String.t()) :: {:ok, String.t()} | {:error, atom() | {:status, integer()}}
  def fetch(host) do
    with {:ok, address} <- resolve(host) do
      ip = address |> :inet.ntoa() |> to_string()
      url_host = if tuple_size(address) == 8, do: "[#{ip}]", else: ip

      options =
        [
          url: "https://#{url_host}#{@path}",
          headers: [{"host", host}],
          connect_options: [hostname: host, timeout: 5_000],
          receive_timeout: 5_000,
          retry: false,
          redirect: false,
          decode_body: false
        ]
        |> Keyword.merge(Application.get_env(:idejo_hub, :proof_req_options, []))

      case Req.get(options) do
        {:ok, %Req.Response{status: 200, body: body}}
        when is_binary(body) and byte_size(body) <= 256 ->
          {:ok, String.trim(body)}

        {:ok, %Req.Response{status: 200}} ->
          {:error, :too_long}

        {:ok, %Req.Response{status: status}} ->
          {:error, {:status, status}}

        {:error, _reason} ->
          {:error, :unreachable}
      end
    end
  end

  defp resolve(host) do
    resolver = Application.get_env(:idejo_hub, :proof_resolver, &getaddrs/1)

    case resolver.(host) do
      {:ok, [first | _] = addresses} ->
        if Enum.all?(addresses, &public?/1), do: {:ok, first}, else: {:error, :not_public}

      _ ->
        {:error, :no_address}
    end
  end

  @doc false
  def getaddrs(host) do
    name = String.to_charlist(host)

    case Enum.flat_map([:inet, :inet6], &addresses(name, &1)) do
      [] -> {:error, :nxdomain}
      list -> {:ok, list}
    end
  end

  defp addresses(name, family) do
    case :inet.getaddrs(name, family) do
      {:ok, list} -> list
      _ -> []
    end
  end

  @doc "Whether an address is on a public network (as idejo's push endpoint check)."
  @spec public?(:inet.ip_address()) :: boolean()
  def public?({a, b, c, d} = address)
      when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
      do: not Enum.any?(ipv4_blocks(), &in_block?(address, &1))

  # IPv4-mapped, IPv4-compatible and NAT64 addresses reach the IPv4 address they carry.
  def public?({0, 0, 0, 0, 0, 0xFFFF, x, y}), do: public?(ipv4(x, y))
  def public?({0x64, 0xFF9B, 0, 0, 0, 0, x, y}), do: public?(ipv4(x, y))

  def public?({0, 0, 0, 0, 0, 0, x, y}) when {x, y} not in [{0, 0}, {0, 1}],
    do: public?(ipv4(x, y))

  def public?({_, _, _, _, _, _, _, _} = address),
    do: not Enum.any?(ipv6_blocks(), &in_block?(address, &1))

  def public?(_address), do: false

  defp ipv4(x, y), do: {x >>> 8, x &&& 0xFF, y >>> 8, y &&& 0xFF}

  # RFC 6890 and the IANA special-purpose registries.
  defp ipv4_blocks do
    [
      {{0, 0, 0, 0}, 8},
      {{10, 0, 0, 0}, 8},
      {{100, 64, 0, 0}, 10},
      {{127, 0, 0, 0}, 8},
      {{169, 254, 0, 0}, 16},
      {{172, 16, 0, 0}, 12},
      {{192, 0, 0, 0}, 24},
      {{192, 0, 2, 0}, 24},
      {{192, 88, 99, 0}, 24},
      {{192, 168, 0, 0}, 16},
      {{198, 18, 0, 0}, 15},
      {{198, 51, 100, 0}, 24},
      {{203, 0, 113, 0}, 24},
      {{224, 0, 0, 0}, 4},
      {{240, 0, 0, 0}, 4}
    ]
  end

  defp ipv6_blocks do
    [
      {{0, 0, 0, 0, 0, 0, 0, 0}, 128},
      {{0, 0, 0, 0, 0, 0, 0, 1}, 128},
      {{0x0100, 0, 0, 0, 0, 0, 0, 0}, 64},
      {{0x2001, 0, 0, 0, 0, 0, 0, 0}, 23},
      {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32},
      {{0x2002, 0, 0, 0, 0, 0, 0, 0}, 16},
      {{0xFC00, 0, 0, 0, 0, 0, 0, 0}, 7},
      {{0xFE80, 0, 0, 0, 0, 0, 0, 0}, 10},
      {{0xFEC0, 0, 0, 0, 0, 0, 0, 0}, 10},
      {{0xFF00, 0, 0, 0, 0, 0, 0, 0}, 8}
    ]
  end

  defp in_block?(address, {base, bits}) when tuple_size(address) == tuple_size(base) do
    width = if tuple_size(address) == 4, do: 8, else: 16
    shift = tuple_size(address) * width - bits
    to_integer(address, width) >>> shift == to_integer(base, width) >>> shift
  end

  defp in_block?(_address, _block), do: false

  defp to_integer(address, width),
    do: address |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< width ||| &1))
end
