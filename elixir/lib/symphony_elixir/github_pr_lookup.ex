defmodule SymphonyElixir.GitHubPrLookup do
  @moduledoc "Lookup GitHub pull requests by repository and head branch."

  @type pr_map() :: %{String.t() => term()}

  @type command_result ::
          {String.t(), integer()} | {:ok, {String.t(), integer()}} | {:error, term()}

  @type deps :: %{
          required(:find_gh_bin) => (-> String.t() | nil),
          required(:run_command) => (String.t(), [String.t()], keyword() -> command_result())
        }

  @spec lookup_by_head(String.t(), String.t(), deps()) :: {:ok, nil | pr_map()} | {:error, term()}
  def lookup_by_head(repo, head_branch, deps \\ runtime_deps()) when is_binary(repo) and is_binary(head_branch) do
    with {:ok, gh_bin} <- find_gh_binary(deps) do
      command = github_pr_list_args(repo, head_branch)

      case normalize_command_result(deps.run_command.(gh_bin, command, stderr_to_stdout: true)) do
        {:ok, {output, 0}} -> parse_gh_response(output)
        {:ok, {_output, status}} -> {:error, {:gh_command_failed, status}}
        {:error, reason} -> {:error, {:gh_command_failed, reason}}
      end
    end
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      find_gh_bin: fn -> System.find_executable("gh") end,
      run_command: &run_system_cmd/3
    }
  end

  defp run_system_cmd(cmd, args, opts) do
    {:ok, System.cmd(cmd, args, opts)}
  end

  defp normalize_command_result({output, status}) when is_binary(output) and is_integer(status),
    do: {:ok, {output, status}}

  defp normalize_command_result(result), do: result

  defp find_gh_binary(deps) do
    case deps.find_gh_bin.() do
      nil -> {:error, :gh_not_found}
      gh -> {:ok, gh}
    end
  end

  defp parse_gh_response(output) do
    with {:ok, parsed} <- Jason.decode(output) do
      case parsed do
        [] -> {:ok, nil}
        [%{} = first | _] -> {:ok, first}
        _ -> {:error, :invalid_pr_payload}
      end
    else
      {:error, reason} -> {:error, {:gh_json_error, reason}}
    end
  end

  defp github_pr_list_args(repo, head_branch) do
    [
      "pr",
      "list",
      "--repo",
      repo,
      "--state",
      "all",
      "--json",
      "number,url,headRefName,isDraft,mergeStateStatus",
      "--head",
      head_branch
    ]
  end
end
