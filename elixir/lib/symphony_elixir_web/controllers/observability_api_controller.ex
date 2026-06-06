defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  plug(:require_observability_access)

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp require_observability_access(conn, _opts) do
    if local_request?(conn) or bearer_token_valid?(conn) do
      conn
    else
      conn
      |> put_status(403)
      |> json(%{error: %{code: "forbidden", message: "Observability API access denied"}})
      |> halt()
    end
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

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
