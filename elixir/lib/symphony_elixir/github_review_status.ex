defmodule SymphonyElixir.GitHubReviewStatus do
  @moduledoc "Reads human review status for a GitHub pull request."

  @type status :: %{
          decision: String.t() | nil,
          state: String.t() | nil,
          url: String.t() | nil,
          number: integer() | nil,
          head_ref_name: String.t() | nil,
          latest_changes_requested_review_id: String.t() | nil,
          changes_requested_body: String.t()
        }

  @type command_result ::
          {String.t(), integer()} | {:ok, {String.t(), integer()}} | {:error, term()}

  @type deps :: %{
          required(:find_gh_bin) => (-> String.t() | nil),
          required(:run_command) => (String.t(), [String.t()], keyword() -> command_result())
        }

  @spec view(String.t(), deps()) :: {:ok, status()} | {:error, term()}
  def view(pr_url, deps \\ runtime_deps()) when is_binary(pr_url) do
    with {:ok, gh_bin} <- find_gh_binary(deps),
         {:ok, raw} <- run_view(gh_bin, pr_url, deps),
         {:ok, decoded} <- Jason.decode(raw) do
      {:ok, normalize_status(decoded)}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec changes_requested?(status()) :: boolean()
  def changes_requested?(%{decision: decision}) when is_binary(decision) do
    String.upcase(decision) == "CHANGES_REQUESTED"
  end

  def changes_requested?(_status), do: false

  @spec open?(status()) :: boolean()
  def open?(%{state: state}) when is_binary(state) do
    String.upcase(state) == "OPEN"
  end

  def open?(_status), do: false

  defp runtime_deps do
    %{
      find_gh_bin: fn -> System.find_executable("gh") end,
      run_command: &run_system_cmd/3
    }
  end

  defp run_system_cmd(cmd, args, opts) do
    {:ok, System.cmd(cmd, args, opts)}
  end

  defp find_gh_binary(deps) do
    case deps.find_gh_bin.() do
      nil -> {:error, :gh_not_found}
      gh -> {:ok, gh}
    end
  end

  defp run_view(gh_bin, pr_url, deps) do
    args = [
      "pr",
      "view",
      pr_url,
      "--json",
      "reviewDecision,latestReviews,state,url,number,headRefName"
    ]

    case normalize_command_result(deps.run_command.(gh_bin, args, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:gh_pr_view_failed, status, String.trim(output)}}
      {:error, reason} -> {:error, {:gh_pr_view_failed, reason}}
    end
  end

  defp normalize_command_result({output, status}) when is_binary(output) and is_integer(status),
    do: {:ok, {output, status}}

  defp normalize_command_result(result), do: result

  defp normalize_status(%{} = decoded) do
    changes_requested_review = latest_changes_requested_review(decoded)

    %{
      decision: string_value(Map.get(decoded, "reviewDecision")),
      state: string_value(Map.get(decoded, "state")),
      url: string_value(Map.get(decoded, "url")),
      number: Map.get(decoded, "number"),
      head_ref_name: string_value(Map.get(decoded, "headRefName")),
      latest_changes_requested_review_id: review_id(changes_requested_review),
      changes_requested_body: review_body(changes_requested_review)
    }
  end

  defp latest_changes_requested_review(decoded) do
    decoded
    |> relation_nodes("latestReviews")
    |> Enum.find(fn review ->
      review_state(review) == "CHANGES_REQUESTED"
    end)
  end

  defp relation_nodes(map, key) when is_map(map) do
    case Map.get(map, key) do
      %{"nodes" => nodes} when is_list(nodes) -> nodes
      %{nodes: nodes} when is_list(nodes) -> nodes
      nodes when is_list(nodes) -> nodes
      _ -> []
    end
  end

  defp relation_nodes(_map, _key), do: []

  defp review_state(review) when is_map(review) do
    review
    |> Map.get("state", Map.get(review, :state))
    |> string_value()
    |> String.upcase()
  end

  defp review_state(_review), do: nil

  defp review_id(review) when is_map(review) do
    string_value(Map.get(review, "id", Map.get(review, :id)))
  end

  defp review_id(_review), do: nil

  defp review_body(review) when is_map(review) do
    string_value(
      Map.get(review, "body") ||
        Map.get(review, :body) ||
        Map.get(review, "bodyText") ||
        Map.get(review, :bodyText)
    )
  end

  defp review_body(_review), do: ""

  defp string_value(value) when is_binary(value), do: value
  defp string_value(nil), do: nil
  defp string_value(value), do: to_string(value)
end
