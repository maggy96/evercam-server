defmodule EvercamMedia.Timelapse.ImportTimelapses do
  require Logger
  alias EvercamMedia.Snapshot.Storage
  alias EvercamMedia.Repo

  @root_dir Application.get_env(:evercam_media, :storage_dir)
  @seaweedfs Application.get_env(:evercam_media, :seaweedfs_url)

  def start_import(exid) do
    timelapse = Timelapse.by_exid(exid)
    Logger.info "Start Timelapse import: #{timelapse.title}"
    timelapse_id = Map.get(timelapse.extra, "id")
    create_directory_structure(timelapse.camera.exid, timelapse.exid)
    download_snapshot(timelapse.camera.exid, timelapse.exid, timelapse_id, timelapse.snapshot_count, 0)
    create_hls(timelapse)
    Logger.info "Complete Timelapse import: #{timelapse.title}"
  end

  defp create_directory_structure(camera_id, timelapse_id) do
    timelapse_path = "#{@root_dir}/#{camera_id}/timelapses/#{timelapse_id}/"
    File.mkdir_p(timelapse_path)
    File.mkdir_p("#{timelapse_path}ts")
    File.mkdir_p("#{timelapse_path}images")
    create_bash_file(timelapse_path)
    create_manifest_file(camera_id, timelapse_id)
  end

  defp create_bash_file(timelapse_path) do
    imagesPath = "#{timelapse_path}images/"
    tsPath = "#{timelapse_path}ts/"

    bash_content = "#!/bin/bash"
    bash_content = bash_content <> "\nffmpeg -threads 1 -y -framerate 24 -i #{imagesPath}/%d.jpg -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 2.1 -maxrate 500K -bufsize 2M -crf 18 -r 24 -g 30  -f hls -hls_time 2 -hls_list_size 0 -s 480x270 #{tsPath}/low.m3u8"
    bash_content = bash_content <> "\nffmpeg -threads 1 -y -framerate 24 -i #{imagesPath}/%d.jpg -c:v libx264 -pix_fmt yuv420p -profile:v baseline -level 3.1 -maxrate 1M -bufsize 3M -crf 18 -r 24 -g 72 -f hls -hls_time 2 -hls_list_size 0 -s 640x360 #{tsPath}/medium.m3u8"
    bash_content = bash_content <> "\nffmpeg -threads 1 -y -framerate 24 -i #{imagesPath}/%d.jpg -c:v libx264 -pix_fmt yuv420p -profile:v high -level 3.2 -maxrate 4M -crf 18 -r 24 -g 100 -f hls -hls_time 2 -hls_list_size 0 #{tsPath}/high.m3u8"
    File.write("#{timelapse_path}build.sh", bash_content)
  end

  defp create_manifest_file(camera_exid, timelapse_id) do
    m3u8_file = "#EXTM3U"
    m3u8_file = m3u8_file <> "\n#EXT-X-STREAM-INF:BANDWIDTH=500000"
    m3u8_file = m3u8_file <> "\nts/low.m3u8"
    m3u8_file = m3u8_file <> "\n#EXT-X-STREAM-INF:BANDWIDTH=1000000"
    m3u8_file = m3u8_file <> "\nts/medium.m3u8"
    m3u8_file = m3u8_file <> "\n#EXT-X-STREAM-INF:BANDWIDTH=4000000"
    m3u8_file = m3u8_file <> "\nts/high.m3u8"
    Storage.save_timelapse_manifest(camera_exid, timelapse_id, m3u8_file)
  end

  defp create_hls(timelapse) do
    timelapse_path = "#{@root_dir}/#{timelapse.camera.exid}/timelapses/#{timelapse.exid}/"
    Porcelain.shell("bash #{timelapse_path}build.sh", [err: :out]).out

    new_index = get_ts_fileindex(timelapse_path)
    Storage.save_timelapse_metadata(timelapse.camera.exid, timelapse.exid, new_index.low, new_index.medium, new_index.high)
    clean_images(timelapse, "images")
    upload_to_seaweed(timelapse, timelapse_path)
  end

  defp upload_to_seaweed(timelapse, timelapse_path) do
    spawn(fn ->
      "#{timelapse_path}ts/"
      |> File.ls!
      |> Enum.each(fn(file) ->
        Storage.save_hls_files(timelapse.camera.exid, timelapse.exid, file)
      end)
      clean_images(timelapse, "ts")
    end)
  end

  defp get_ts_fileindex(timelapse_path) do
    hls_path = "#{timelapse_path}ts/"
    files = File.ls!(hls_path)
    low = files |> Enum.filter(fn(f) -> String.match?(f, ~r/low/) and !String.match?(f, ~r/low.m3u8/) end) |> Enum.count
    medium = files |> Enum.filter(fn(f) -> String.match?(f, ~r/medium/) and !String.match?(f, ~r/medium.m3u8/) end) |> Enum.count
    high = files |> Enum.filter(fn(f) -> String.match?(f, ~r/high/) and !String.match?(f, ~r/high.m3u8/) end) |> Enum.count

    %{low: low, medium: medium, high: high}
  end

  defp clean_images(timelapse, directory) do
    images_path = "#{@root_dir}/#{timelapse.camera.exid}/timelapses/#{timelapse.exid}/#{directory}/"
    File.rm_rf!(images_path)
    File.mkdir_p(images_path)
  end

  defp download_snapshot(camera_id, timelapse_exid, timelapse_id, total_snaps, n) when n < total_snaps do
    download_url = "http://timelapse.evercam.io/timelapses/#{camera_id}/#{timelapse_id}/images/#{n}.jpg"
    save_url = "#{@root_dir}/#{camera_id}/timelapses/#{timelapse_exid}/images/#{n}.jpg"
    case HTTPoison.get(download_url, [], hackney: [pool: :seaweedfs_download_pool]) do
      {:ok, %HTTPoison.Response{status_code: 200, body: image}} ->
        File.write(save_url, image)
        download_snapshot(camera_id, timelapse_exid, timelapse_id, total_snaps, n + 1)
      error ->
        Logger.info "[snapshot-get] [error] [#{camera_id}] [#{timelapse_exid}] [#{inspect error}]"
        {:error, :not_found}
    end
  end
  defp download_snapshot(_camera_id, _timelapse_exid, _timelapse_id, _total_snaps, _n), do: :noop

  def get_timelapses(timelapse_url, app_id, app_key) do
    url = "#{timelapse_url}/#{app_id}/#{app_key}"
    headers = ["Accept": "Accept:application/json"]
    response = HTTPoison.get(url, headers) |> elem(1)
    case response.status_code do
      200 ->
        response.body
        |> Poison.decode!
        |> Enum.each(fn(timelapse) ->
          camera = Camera.by_exid(timelapse["camera_id"])
          user = User.by_username(timelapse["user_id"])
          insert_into_evercam(timelapse, camera, user)
        end)
      _ -> {:error, response}
    end
  end

  defp insert_into_evercam(_timelapse, nil, _user), do: :noop
  defp insert_into_evercam(_timelapse, _camera, nil), do: :noop
  defp insert_into_evercam(timelapse, camera, user) do
    params = %{
      camera_id: camera.id,
      user_id: user.id,
      title: timelapse["title"],
      frequency: timelapse["interval"],
      status: get_status(timelapse["status"]),
      date_always: timelapse["is_date_always"],
      time_always: timelapse["is_time_always"],
      snapshot_count: timelapse["snaps_count"],
      resolution: timelapse["resolution"],
      watermark_logo: timelapse["watermark_file"],
      watermark_position: get_logo_position(timelapse["watermark_position"]),
      from_datetime: (timelapse["from_date"] |> Timex.parse!("%m/%d/%Y %T", :strftime)),
      to_datetime: (timelapse["to_date"] |> Timex.parse!("%m/%d/%Y %T", :strftime)),
      last_snapshot_at: ("#{timelapse["last_snap_date"]}:00" |> Timex.parse!("%d %B %Y %T", :strftime)),
      inserted_at: ("#{timelapse["created_date"]}:00" |> Timex.parse!("%d %B %Y %T", :strftime)),
      extra: %{"id" => timelapse["id"]}
    }

    timelapse_changeset = Timelapse.changeset(%Timelapse{}, params)
    case Repo.insert(timelapse_changeset) do
      {:ok, _} -> Logger.debug "Timelapse inserted: #{timelapse["title"]}"
      {:error, changeset} ->
        Logger.debug "Failed to insert timelapse: #{timelapse["title"]}"
        IO.inspect EvercamMedia.Util.parse_changeset(changeset)
    end
  end

  defp get_status(code) do
    case code do
      0 -> 0
      1 -> 0
      2 -> 4
      3 -> 1
      4 -> 4
      5 -> 4
      6 -> 2
      7 -> 3
    end
  end

  defp get_logo_position(position) do
    case position do
      0 -> "TopLeft"
      1 -> "TopRight"
      2 -> "BottomLeft"
      3 -> "BottomRight"
    end
  end
end
