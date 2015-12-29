defmodule EvercamMedia.Snapshot.S3UploadHandler do
  @moduledoc """
  TODO
  """

  use GenEvent
  alias EvercamMedia.Snapshot.S3
  require Logger

  def handle_event({:got_snapshot, data}, state) do
    {camera_exid, timestamp, image} = data
    spawn fn ->
      Logger.debug "Uploading snapshot to S3 for camera #{camera_exid} taken at #{timestamp}"
      S3.upload(camera_exid, timestamp, image)
    end
    {:ok, state}
  end

  def handle_event(_, state) do
    {:ok, state}
  end
end
