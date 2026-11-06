# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Identity.Profiles do
  @moduledoc """
  An Idejo ID's public username and picture (steward decisions 2026-11-06). Never the email:
  the username is chosen at sign-up (or later on the member's page), the picture comes from a
  forum. Forums read them for a new member and fill what is missing when a member links an
  existing account (`fill/2`: a later link never overwrites); the member changes them on
  their Idejo ID page. Usernames follow Idejo's rules (letters, digits, underscores, 3 to 30)
  and are unique among Idejo IDs, any case. Pictures are WebP up to 512 KB (Idejo's avatars
  are 256 px WebP without metadata), served at `/account/pictures/<key>.webp` on the sign-in
  host with a new key at each change.
  """
  alias IdejoHub.Identity.Profile
  alias IdejoHub.Repo

  @max_picture 512_000

  @doc "The profile of `subject`, or an empty one."
  @spec get(String.t()) :: Profile.t()
  def get(subject), do: Repo.get(Profile, subject) || %Profile{subject: subject}

  @doc "What forums receive: `%{username:, picture:}` (the picture's address, or nil)."
  @spec public(Profile.t()) :: %{username: String.t() | nil, picture: String.t() | nil}
  def public(%Profile{} = profile),
    do: %{username: profile.username, picture: picture_url(profile)}

  @doc "The picture's public address, or nil."
  def picture_url(%Profile{picture_key: nil}), do: nil

  def picture_url(%Profile{picture_key: key}),
    do: IdejoHub.Identity.issuer() <> "/account/pictures/" <> key <> ".webp"

  @doc "The picture stored under `key`, or nil."
  @spec picture(String.t()) :: binary() | nil
  def picture(key) when is_binary(key) do
    case Repo.get_by(Profile, picture_key: key) do
      %Profile{picture: picture} -> picture
      nil -> nil
    end
  end

  @doc "Sets `subject`'s username: `{:ok, profile}`, or `{:error, :invalid | :taken}`."
  @spec set_username(String.t(), term()) :: {:ok, Profile.t()} | {:error, :invalid | :taken}
  def set_username(subject, username) do
    with {:ok, username} <- check_username(username),
         :ok <- free(username, subject) do
      save(get(subject), username: username)
    end
  end

  @doc "Sets `subject`'s picture (WebP bytes)."
  @spec set_picture(String.t(), term()) :: {:ok, Profile.t()} | {:error, :invalid}
  def set_picture(subject, picture) do
    with :ok <- check_picture(picture) do
      save(get(subject), picture: picture, picture_key: key())
    end
  end

  @doc "Removes `subject`'s picture."
  @spec remove_picture(String.t()) :: {:ok, Profile.t()}
  def remove_picture(subject), do: save(get(subject), picture: nil, picture_key: nil)

  @doc """
  A forum shares a linked account's username and picture: each is kept only when the Idejo
  ID has none yet (a username already taken by another Idejo ID is skipped). Returns the
  profile as it then is.
  """
  @spec fill(String.t(), map()) :: {:ok, Profile.t()}
  def fill(subject, given) do
    profile = get(subject)

    profile =
      with nil <- profile.username,
           {:ok, username} <- check_username(given["username"]),
           :ok <- free(username, subject),
           {:ok, saved} <- save(profile, username: username) do
        saved
      else
        _ -> profile
      end

    profile =
      with nil <- profile.picture_key,
           {:ok, picture} <- decode(given["picture"]),
           :ok <- check_picture(picture),
           {:ok, saved} <- save(profile, picture: picture, picture_key: key()) do
        saved
      else
        _ -> profile
      end

    {:ok, profile}
  end

  @doc "Whether `username` is free for `subject` (any case)."
  @spec available?(String.t(), String.t() | nil) :: boolean()
  def available?(username, subject \\ nil), do: free(username, subject) == :ok

  @doc "Checks a username against Idejo's rules."
  @spec check_username(term()) :: {:ok, String.t()} | {:error, :invalid}
  def check_username(username) when is_binary(username) do
    username = String.trim(username)
    if username =~ ~r/\A[A-Za-z0-9_]{3,30}\z/, do: {:ok, username}, else: {:error, :invalid}
  end

  def check_username(_username), do: {:error, :invalid}

  defp free(username, subject) do
    import Ecto.Query

    taken? =
      Repo.exists?(
        from p in Profile,
          where:
            fragment("lower(?)", p.username) == ^String.downcase(username) and
              p.subject != ^(subject || "")
      )

    if taken?, do: {:error, :taken}, else: :ok
  end

  defp check_picture(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>> = picture)
       when byte_size(picture) <= @max_picture,
       do: :ok

  defp check_picture(_picture), do: {:error, :invalid}

  defp decode(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid}
    end
  end

  defp decode(_value), do: {:error, :invalid}

  defp key, do: 18 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp save(%Profile{} = profile, changes) do
    profile
    |> Ecto.Changeset.change(changes)
    |> Ecto.Changeset.unique_constraint(:username, name: :identity_profiles_username_index)
    |> Repo.insert_or_update()
    |> case do
      {:ok, profile} -> {:ok, profile}
      {:error, _changeset} -> {:error, :taken}
    end
  end
end
