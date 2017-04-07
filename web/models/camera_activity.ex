defmodule CameraActivity do
  use EvercamMedia.Web, :model
  import Ecto.Changeset
  import Ecto.Query
  alias EvercamMedia.SnapshotRepo

  @required_fields ~w(camera_id action)
  @optional_fields ~w(access_token_id camera_exid name action extra done_at)

  schema "camera_activities" do
    belongs_to :camera, Camera
    belongs_to :access_token, AccessToken

    field :action, :string
    field :done_at, Ecto.DateTime, default: Ecto.DateTime.utc
    field :extra, EvercamMedia.Types.JSON
    field :camera_exid, :string
    field :name, :string
  end

  def log_activity(user, camera, action, extra \\ nil) do
    access_token_id = AccessToken.active_token_id_for(user.id)
    params = %{
      camera_id: camera.id,
      camera_exid: camera.exid,
      access_token_id: access_token_id,
      name: User.get_fullname(user),
      action: action,
      extra: extra,
      done_at: Ecto.DateTime.utc
    }
    %CameraActivity{}
    |> changeset(params)
    |> SnapshotRepo.insert
  end

  def get_all(query) do
    query
    |> order_by([c], desc: c.done_at)
    |> SnapshotRepo.all
  end

  def delete_by_camera_id(camera_id) do
    CameraActivity
    |> where(camera_id: ^camera_id)
    |> SnapshotRepo.delete_all
  end

  def for_a_user(full_name, from, to, types) do
    CameraActivity
    |> where(name: ^full_name)
    |> where([c], c.done_at >= ^from and c.done_at <= ^to)
    |> with_types_if_specified(types)
    |> order_by([c], desc: c.done_at)
    |> SnapshotRepo.all
  end

  def get_last_on_off_log(camera_id) do
    CameraActivity
    |> where(camera_id: ^camera_id)
    |> where([c], c.action in ["online", "offline"])
    |> order_by(desc: :id)
    |> limit(1)
    |> SnapshotRepo.one
  end

  def with_types_if_specified(query, nil) do
    query
  end
  def with_types_if_specified(query, types) do
    query
    |> where([c], c.action in ^types)
  end

  def changeset(camera_activity, params \\ :invalid) do
    camera_activity
    |> cast(params, @required_fields, @optional_fields)
    |> unique_constraint(:camera_id, name: :camera_activities_camera_id_done_at_index)
  end
end
