defmodule EvercamMedia.Intercom do
  alias EvercamMedia.Util
  require Logger

  @intercom_url System.get_env["INTERCOM_URL"]
  @intercom_auth {System.get_env["INTERCOM_ID"], System.get_env["INTERCOM_KEY"]}
  @hackney [basic_auth: @intercom_auth]

  def get_user(user_id) do
    url = "#{@intercom_url}?user_id=#{user_id}"
    headers = ["Accept": "Accept:application/json"]
    response = HTTPoison.get(url, headers, hackney: @hackney) |> elem(1)
    case response.status_code do
      200 -> {:ok, response}
      _ -> {:error, response}
    end
  end

  def get_company(company_id) do
    intercom_url = @intercom_url |> String.replace("users", "companies")
    url = "#{intercom_url}?company_id=#{company_id}"
    headers = ["Accept": "Accept:application/json"]
    response = HTTPoison.get(url, headers, hackney: @hackney) |> elem(1)
    case response.status_code do
      200 -> {:ok, response.body |> Poison.decode!}
      _ -> {:error, response}
    end
  end

  def create_user(user, user_agent, requester_ip, status) do
    company_id =
      case get_company(String.split(user.email, "@") |> List.last) do
        {:ok, company} -> company["company_id"]
        _ -> ""
      end
    headers = ["Accept": "Accept:application/json", "Content-Type": "application/json"]
    intercom_new_user = %{
      "email": user.email,
      "name": user.firstname <> " " <> user.lastname,
      "last_seen_user_agent": user_agent,
      "last_request_at": user.created_at |> Util.ecto_datetime_to_unix,
      "last_seen_ip": requester_ip,
      "signed_up_at": user.created_at |> Util.ecto_datetime_to_unix,
      "custom_attributes": %{
        "viewed_camera": 0,
        "viewed_recordings": 0,
        "has_shared": false,
        "has_snapmail": false
      }
    }
    |> add_userid(user.username)
    |> add_session(user.username)
    |> add_status(status)
    |> add_company(company_id)

    json =
      case Poison.encode(intercom_new_user) do
        {:ok, json} -> json
        _ -> nil
      end
    HTTPoison.post(@intercom_url, json, headers, hackney: @hackney)
    tag_user(user.email, get_tag_name(company_id))
  end

  def tag_user(_email, ""), do: :noop
  def tag_user(email, tag) do
    intercom_url = @intercom_url |> String.replace("users", "tags")
    headers = ["Accept": "Accept:application/json", "Content-Type": "application/json"]
    tag_params = %{
      "name": tag,
      "users": [%{"email": email}]
    }

    json =
      case Poison.encode(tag_params) do
        {:ok, json} -> json
        _ -> nil
      end
    HTTPoison.post(intercom_url, json, headers, hackney: @hackney)
  end

  defp add_userid(params, ""), do: params
  defp add_userid(params, id) do
    Map.put(params, "user_id", id)
  end

  defp add_session(params, user_id) when user_id in [nil, ""], do: params
  defp add_session(params, _user_id) do
    Map.put(params, "new_session", true)
  end

  defp add_status(params, ""), do: params
  defp add_status(params, status) do
    put_in(params, [:custom_attributes, "status"], status)
  end

  defp add_company(params, ""), do: params
  defp add_company(params, company_id) do
    Map.put(params, "companies", [%{company_id: "#{company_id}"}])
  end

  def delete_user(user, by_val \\ "user_id", tries \\ 1)
  def delete_user(_user, _by_val, 3), do: :noop
  def delete_user(user, by_val, tries) do
    url = "#{@intercom_url}?#{by_val}=#{user}"
    headers = ["Accept": "Accept:application/json"]

    case HTTPoison.delete(url, headers, hackney: @hackney) do
      {:ok, _response} -> :noop
      {:error, _reason} -> delete_user(user, by_val, tries + 1)
    end
  end

  def intercom_activity(is_create, user, user_agent, requester_ip, status \\ "")
  def intercom_activity(false, _user, _user_agent, _requester_ip, _status), do: :noop
  def intercom_activity(true, user, user_agent, requester_ip, status) do
    Task.start(fn ->
      case get_user(user.username) do
        {:ok, _} -> Logger.info "User '#{user.username}' already present at Intercom."
        {:error, _} -> create_user(user, user_agent, requester_ip, status)
      end
    end)
  end

  def update_user(false, _user, _user_agent, _requester_ip), do: :noop
  def update_user(true, user, user_agent, requester_ip) do
    Task.start(fn ->
      create_user(user, user_agent, requester_ip, "Share-Accepted")
    end)
  end

  def delete_or_update_user(false, _email, _user_agent, _ip, _key), do: :noop
  def delete_or_update_user(true, email, _user_agent, _ip, nil) do
    Task.start(fn ->
      delete_user(email, "email")
    end)
  end
  def delete_or_update_user(true, email, user_agent, ip, _key) do
    Task.start(fn ->
      user = %User{
        username: "",
        firstname: "",
        lastname: "",
        email: email,
        created_at: Ecto.DateTime.utc
      }
      create_user(user, user_agent, ip, "Share-Revoked")
    end)
  end

  defp get_tag_name(company_id) do
    case company_id do
      "sisk.ie" -> "Construction"
      "sisk.co.uk" -> "Construction"
      "evercam.io" -> "Evercam team"
      _ -> ""
    end
  end
end
