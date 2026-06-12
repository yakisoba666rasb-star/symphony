defmodule SymphonyElixirWeb.Plugs.ObservabilityAccess do
  @moduledoc """
  Shared access gate for the observability dashboard and JSON API.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  alias Plug.Conn
  alias SymphonyElixirWeb.Endpoint

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Conn.t(), keyword()) :: Conn.t()
  def call(conn, opts) do
    if local_request?(conn) or bearer_token_valid?(conn) do
      conn
    else
      deny(conn, Keyword.get(opts, :format, :text))
    end
  end

  defp deny(conn, :json) do
    conn
    |> put_status(403)
    |> json(%{error: %{code: "forbidden", message: "Observability API access denied"}})
    |> halt()
  end

  defp deny(conn, _format) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "Observability dashboard access denied")
    |> halt()
  end

  defp local_request?(%Conn{remote_ip: remote_ip}) do
    remote_ip in [
      {127, 0, 0, 1},
      {0, 0, 0, 0, 0, 0, 0, 1}
    ]
  end

  defp bearer_token_valid?(conn) do
    case observability_token() do
      nil ->
        false

      token ->
        conn
        |> get_req_header("authorization")
        |> case do
          ["Bearer " <> provided | _] -> Plug.Crypto.secure_compare(provided, token)
          _ -> false
        end
    end
  end

  defp observability_token do
    Endpoint.config(:observability_token) || blank_to_nil(System.get_env("SYMPHONY_OBSERVABILITY_TOKEN"))
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
