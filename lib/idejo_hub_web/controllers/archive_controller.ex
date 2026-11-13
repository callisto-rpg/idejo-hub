# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.ArchiveController do
  @moduledoc """
  HA-03: downloads one of a forum's kept archives (a standard idejo backup) for a signed-in
  operator. Taking a forum's data out is an operator action like any other: audited
  (`forum.archive.download`, SC-06). `no-store`, as an attachment.
  """
  use IdejoHubWeb, :controller

  alias IdejoHub.{Audit, Forums, Repo}
  alias IdejoHub.Forums.Export

  # The path is the exports directory, the forum's validated subdomain and a recorded name.
  # sobelow_skip ["Traversal.SendDownload"]
  def show(conn, %{"forum_id" => forum_id, "id" => id}) do
    forum = Forums.get_forum!(forum_id)
    export = Repo.get_by!(Export, id: id, forum_id: forum.id)
    path = Export.path(export)

    if File.exists?(path) do
      {:ok, _} =
        Audit.record(
          conn.assigns.current_operator.email,
          "forum.archive.download",
          "ok",
          forum,
          %{
            "file" => export.file_name,
            "kind" => export.kind
          }
        )

      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_download({:file, path},
        filename: "#{forum.subdomain}-#{export.file_name}",
        content_type: "application/x-tar"
      )
    else
      conn |> put_status(:not_found) |> text("This archive's file is not on the server any more.")
    end
  end
end
