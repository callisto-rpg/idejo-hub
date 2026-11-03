# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHub.Forums.Errors do
  @moduledoc "Short, secret-free descriptions of lifecycle failures, for forum rows and audit entries."

  @doc "Describes an error term from a lifecycle step."
  @spec describe(term()) :: String.t()
  def describe(:timeout), do: "no healthy answer in time"
  def describe(:not_found), do: "not found"
  def describe({:image_unavailable, image}), do: "image #{image} could not be pulled"
  def describe(:invalid), do: "a stored secret could not be decrypted"
  def describe({:exit, code}), do: "idejo-admin setup exited with #{code}"
  def describe({:denied, message}), do: "refused by docker-guard (#{message})"
  def describe({:status, status, message}), do: "Docker answered #{status} (#{message})"
  def describe({:unreachable, _detail}), do: "Docker is unreachable"
  def describe({:postgres, message}), do: "PostgreSQL: #{message}"
  def describe({:backup_exit, code}), do: "idejo-admin backup exited with #{code}"
  def describe(:backup_file_not_named), do: "idejo-admin backup did not name its file"
  def describe({:archive, _reason}), do: "the backup could not be copied out"
  def describe({:error, reason}), do: describe(reason)
  def describe({:posix, reason}), do: "file: #{reason}"
  def describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  def describe(other), do: inspect(other)
end
