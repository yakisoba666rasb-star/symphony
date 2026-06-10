defmodule SymphonyElixir.GitHubIssue do
  @moduledoc "Small GitHub issue operations used by runtime reconciliation."

  @type command_result ::
          {String.t(), integer()} | {:ok, {String.t(), integer()}} | {:error, term()}

  @type deps :: %{
          required(:find_gh_bin) => (-> String.t() | nil),
          required(:run_command) => (String.t(), [String.t()], keyword() -> command_result())
        }

  @spec close_if_open(String.t(), String.t() | nil, String.t(), deps()) ::
          {:ok, :closed | :already_closed | :not_applicable} | {:error, term()}
  def close_if_open(repo, issue_url, comment, deps \\ runtime_deps())

  def close_if_open(repo, issue_url, comment, deps)
      when is_binary(repo) and is_binary(issue_url) and is_binary(comment) do
    with {:ok, number} <- issue_number_for_repo(repo, issue_url),
         {:ok, gh_bin} <- find_gh_binary(deps),
         {:ok, state} <- view_issue_state(gh_bin, repo, number, deps) do
      case String.upcase(to_string(state)) do
        "OPEN" -> close_issue(gh_bin, repo, number, comment, deps)
        "CLOSED" -> {:ok, :already_closed}
        other -> {:error, {:unexpected_issue_state, other}}
      end
    else
      :not_applicable -> {:ok, :not_applicable}
      {:error, reason} -> {:error, reason}
    end
  end

  def close_if_open(_repo, _issue_url, _comment, _deps), do: {:ok, :not_applicable}

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      find_gh_bin: fn -> System.find_executable("gh") end,
      run_command: &run_system_cmd/3
    }
  end

  defp run_system_cmd(cmd, args, opts), do: {:ok, System.cmd(cmd, args, opts)}

  defp find_gh_binary(deps) do
    case deps.find_gh_bin.() do
      nil -> {:error, :gh_not_found}
      gh -> {:ok, gh}
    end
  end

  defp issue_number_for_repo(repo, issue_url) do
    case Regex.run(~r{^https://github\.com/([^/]+/[^/]+)/issues/(\d+)(?:[/?#].*)?$}i, String.trim(issue_url)) do
      [_, ^repo, number] -> {:ok, String.to_integer(number)}
      [_matched, _other_repo, _number] -> :not_applicable
      _other -> :not_applicable
    end
  end

  defp view_issue_state(gh_bin, repo, number, deps) do
    args = ["issue", "view", Integer.to_string(number), "--repo", repo, "--json", "state"]

    case normalize_command_result(deps.run_command.(gh_bin, args, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> parse_issue_state(output)
      {:ok, {output, status}} -> {:error, {:gh_issue_view_failed, status, output}}
      {:error, reason} -> {:error, {:gh_issue_view_failed, reason}}
    end
  end

  defp parse_issue_state(output) do
    case Jason.decode(output) do
      {:ok, %{"state" => state}} when is_binary(state) -> {:ok, state}
      {:ok, other} -> {:error, {:invalid_issue_payload, other}}
      {:error, reason} -> {:error, {:gh_json_error, reason}}
    end
  end

  defp close_issue(gh_bin, repo, number, comment, deps) do
    args = ["issue", "close", Integer.to_string(number), "--repo", repo, "--comment", comment]

    case normalize_command_result(deps.run_command.(gh_bin, args, stderr_to_stdout: true)) do
      {:ok, {_output, 0}} -> {:ok, :closed}
      {:ok, {output, status}} -> {:error, {:gh_issue_close_failed, status, output}}
      {:error, reason} -> {:error, {:gh_issue_close_failed, reason}}
    end
  end

  defp normalize_command_result({output, status}) when is_binary(output) and is_integer(status),
    do: {:ok, {output, status}}

  defp normalize_command_result(result), do: result
end
