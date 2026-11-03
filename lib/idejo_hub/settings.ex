# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Settings do
  @moduledoc """
  HA-05: the Hub's settings an operator changes in the interface.

  | Key | What | Default |
  | --- | --- | --- |
  | `smtp_host`, `smtp_port`, `smtp_security`, `smtp_username`, `smtp_password` | SMTP shared by forums (HN-07). Set here, it replaces `HUB_SMTP_*` as a whole; the password is encrypted (SC-04) | the environment |
  | `alert_email` | Where alerts go (OP-08, milestone 4) | none |
  | `reserved_subdomains` | Names refused for new forums, on top of FL-03's | none |

  The forum domain stays in the environment (`IDEJO_FORUM_DOMAIN`): every forum's address,
  certificate and links depend on it. Backups are kept in the exports volume; off-server
  storage comes with OP-02.

  Changes are audited (`settings.update`, the keys only, never a value of a secret).
  """

  import Ecto.Query

  alias IdejoHub.{Audit, Repo, Secrets}
  alias IdejoHub.Identity.SetupWorker
  alias IdejoHub.Settings.Setting

  @keys ~w(smtp_host smtp_port smtp_security smtp_username smtp_password alert_email reserved_subdomains)
  @secret ~w(smtp_password)

  @doc "Every setting's stored value (secrets decrypted), missing ones as nil."
  @spec all() :: %{String.t() => term()}
  def all do
    stored = Repo.all(from s in Setting, where: s.key in ^@keys) |> Map.new(&{&1.key, decode(&1)})
    Map.new(@keys, &{&1, stored[&1]})
  end

  @doc "One setting's value, or nil."
  @spec get(String.t()) :: term()
  def get(key) when key in @keys do
    case Repo.get(Setting, key) do
      nil -> nil
      setting -> decode(setting)
    end
  end

  @doc """
  Saves the given settings: empty strings (and empty lists) remove a setting. A secret left
  empty in a form keeps its stored value unless `clear_<key>` is set. Checks the values.
  """
  @spec update(map(), String.t()) :: {:ok, map()} | {:error, %{String.t() => String.t()}}
  def update(params, actor) do
    with {:ok, changes} <- validate(params) do
      Repo.transaction(fn -> save(changes, actor) end)
      {:ok, all()}
    end
  end

  defp save(changes, actor) do
    for {key, value} <- changes, do: put(key, value)
    # ID-02: the identity provider sends its invites through the same SMTP.
    if Enum.any?(Map.keys(changes), &String.starts_with?(&1, "smtp_")),
      do: SetupWorker.queue()

    keys = changes |> Map.keys() |> Enum.sort()
    {:ok, _} = Audit.record(actor, "settings.update", "ok", nil, %{"keys" => keys})
  end

  defp validate(params) do
    changes =
      for key <- @keys,
          Map.has_key?(params, key) or params["clear_" <> key] == "true",
          into: %{} do
        {key, normalize(key, params[key], params["clear_" <> key] == "true")}
      end
      |> Enum.reject(fn {key, value} -> key in @secret and value == :keep end)
      |> Map.new()

    errors =
      for {key, value} <- changes, message = check(key, value), into: %{}, do: {key, message}

    if errors == %{}, do: {:ok, changes}, else: {:error, errors}
  end

  defp normalize(key, _value, true) when key in @secret, do: nil

  defp normalize(key, value, _clear) when key in @secret,
    do: if(blank?(value), do: :keep, else: value)

  defp normalize("reserved_subdomains", value, _clear) do
    value
    |> to_string()
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> then(&if(&1 == [], do: nil, else: &1))
  end

  defp normalize(_key, value, _clear),
    do: if(blank?(value), do: nil, else: String.trim(to_string(value)))

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp check(_key, nil), do: nil

  defp check("smtp_port", port) do
    case Integer.parse(port) do
      {n, ""} when n in 1..65_535 -> nil
      _ -> "must be a port number (1 to 65535)"
    end
  end

  defp check("smtp_security", s) when s in ["starttls", "tls", "none"], do: nil
  defp check("smtp_security", _), do: "must be starttls, tls or none"

  defp check("alert_email", email),
    do: if(email =~ ~r/\A[^@\s]+@[^@\s]+\.[^@\s]+\z/, do: nil, else: "must be an email address")

  defp check("reserved_subdomains", names) do
    bad = Enum.reject(names, &(&1 =~ ~r/\A[a-z0-9-]+\z/))

    if bad == [],
      do: nil,
      else: "lowercase letters, digits and hyphens only: #{Enum.join(bad, ", ")}"
  end

  defp check(_key, _value), do: nil

  defp put(key, nil), do: Repo.delete_all(from s in Setting, where: s.key == ^key)

  defp put(key, value) do
    stored = Jason.encode!(value)
    stored = if key in @secret, do: Secrets.encrypt(stored, "setting:" <> key), else: stored

    Repo.insert!(%Setting{key: key, value: stored},
      on_conflict: [set: [value: stored, updated_at: DateTime.utc_now(:second)]],
      conflict_target: :key
    )
  end

  defp decode(%Setting{key: key, value: value}) when key in @secret do
    case Secrets.decrypt(value, "setting:" <> key) do
      {:ok, json} -> Jason.decode!(json)
      {:error, :invalid} -> nil
    end
  end

  defp decode(%Setting{value: value}), do: Jason.decode!(value)

  @doc """
  HN-07, as set here or else in the environment: the SMTP server forums share, as a keyword
  list (`host`, `port`, `security`, `username`, `password`), or nil.
  """
  @spec shared_smtp() :: keyword() | nil
  def shared_smtp do
    case all() do
      %{"smtp_host" => host} = s when is_binary(host) ->
        [
          host: host,
          port: s["smtp_port"],
          security: s["smtp_security"],
          username: s["smtp_username"],
          password: s["smtp_password"]
        ]

      _none ->
        Application.get_env(:idejo_hub, IdejoHub.Forums.Mail, [])[:shared_smtp]
    end
  end

  @doc "FL-03 + HA-05: the operator's extra reserved subdomains."
  @spec reserved_subdomains() :: [String.t()]
  def reserved_subdomains, do: get("reserved_subdomains") || []
end
