defmodule SymphonyElixir.GitHubPrLookup do
  @moduledoc "Lookup GitHub pull requests by repository and head branch."

  @type pr_map() :: %{String.t() => term()}

  @type command_result ::
          {String.t(), integer()} | {:ok, {String.t(), integer()}} | {:error, term()}

  @type deps :: %{
          required(:find_gh_bin) => (-> String.t() | nil),
          required(:run_command) => (String.t(), [String.t()], keyword() -> command_result()),
          optional(:find_git_bin) => (-> String.t() | nil)
        }

  @spec lookup_by_head(String.t(), String.t(), deps()) :: {:ok, nil | pr_map()} | {:error, term()}
  def lookup_by_head(repo, head_branch, deps \\ runtime_deps())
      when is_binary(repo) and is_binary(head_branch) do
    with {:ok, gh_bin} <- find_gh_binary(deps) do
      with {:ok, nil} <- lookup_by_head_state(gh_bin, repo, head_branch, "open", deps) do
        lookup_by_head_state(gh_bin, repo, head_branch, "all", deps)
      end
    end
  end

  @spec lookup_by_issue(String.t(), String.t(), deps()) :: {:ok, nil | pr_map()} | {:error, term()}
  def lookup_by_issue(repo, issue_identifier, deps \\ runtime_deps())
      when is_binary(repo) and is_binary(issue_identifier) do
    issue_identifier = String.trim(issue_identifier)

    if issue_identifier == "" do
      {:error, :invalid_issue_identifier}
    else
      with {:ok, gh_bin} <- find_gh_binary(deps) do
        with {:ok, nil} <- lookup_by_issue_state(gh_bin, repo, issue_identifier, "open", deps) do
          lookup_by_issue_state(gh_bin, repo, issue_identifier, "all", deps)
        end
      end
    end
  end

  @spec lookup_workspace_head(String.t(), String.t(), deps()) :: {:ok, nil | pr_map()} | {:error, term()}
  def lookup_workspace_head(workspace_path, head_branch, deps \\ runtime_deps())
      when is_binary(workspace_path) and is_binary(head_branch) do
    with {:ok, git_bin} <- find_git_binary(deps),
         {:ok, remote_url} <- query_remote_url(workspace_path, git_bin, deps),
         {:ok, repo} <- parse_remote_url(remote_url) do
      lookup_by_head(repo, head_branch, deps)
    end
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      find_gh_bin: fn -> System.find_executable("gh") end,
      find_git_bin: fn -> System.find_executable("git") end,
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

  defp find_git_binary(deps) do
    case Map.get(deps, :find_git_bin, fn -> System.find_executable("git") end).() do
      nil -> {:error, :git_not_found}
      git -> {:ok, git}
    end
  end

  defp query_remote_url(workspace_path, git_bin, deps) do
    args = ["-C", workspace_path, "remote", "get-url", "origin"]

    case normalize_command_result(deps.run_command.(git_bin, args, stderr_to_stdout: true)) do
      {:ok, {url, 0}} -> {:ok, String.trim(url)}
      {:ok, {_output, status}} -> {:error, {:git_command_failed, status}}
      {:error, reason} -> {:error, {:git_command_failed, reason}}
    end
  end

  defp parse_remote_url(raw_remote_url) when is_binary(raw_remote_url) do
    remote_url = String.trim(raw_remote_url)

    case Regex.run(~r/^git@([^:]+):(.+)$/, remote_url) do
      [_, host, path] ->
        if github_host?(host) do
          parse_owner_repo(path)
        else
          {:error, {:unsupported_remote_url, raw_remote_url}}
        end

      _ ->
        if String.starts_with?(remote_url, "https://github.com/") do
          remote_url
          |> String.replace_prefix("https://", "")
          |> String.replace_prefix("github.com/", "")
          |> parse_owner_repo()
        else
          {:error, {:unsupported_remote_url, raw_remote_url}}
        end
    end
  end

  defp github_host?("github.com"), do: true

  defp github_host?("github" <> <<separator::binary-size(1)>> <> _rest)
       when separator in ["-", "."],
       do: true

  defp github_host?(_host), do: false

  defp parse_owner_repo(raw_path) do
    path = String.trim_trailing(String.trim_leading(raw_path, "/"), ".git")

    case String.split(path, "/", parts: 3) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, owner <> "/" <> repo}
      _ -> {:error, {:unsupported_remote_url, raw_path}}
    end
  end

  defp parse_gh_response(output) do
    case Jason.decode(output) do
      {:ok, []} -> {:ok, nil}
      {:ok, values} when is_list(values) -> pick_pr(values)
      {:ok, _other} -> {:error, :invalid_pr_payload}
      {:error, reason} -> {:error, {:gh_json_error, reason}}
    end
  end

  defp lookup_by_head_state(gh_bin, repo, head_branch, state, deps) do
    command = github_pr_list_args(repo, head_branch, state)

    case normalize_command_result(deps.run_command.(gh_bin, command, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> parse_gh_response(output)
      {:ok, {_output, status}} -> {:error, {:gh_command_failed, status}}
      {:error, reason} -> {:error, {:gh_command_failed, reason}}
    end
  end

  defp lookup_by_issue_state(gh_bin, repo, issue_identifier, state, deps) do
    command = github_pr_search_args(repo, issue_identifier, state)

    case normalize_command_result(deps.run_command.(gh_bin, command, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> parse_gh_response(output)
      {:ok, {_output, status}} -> {:error, {:gh_command_failed, status}}
      {:error, reason} -> {:error, {:gh_command_failed, reason}}
    end
  end

  defp pick_pr(values) do
    values
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&pr_sort_key/1)
    |> case do
      [] -> {:error, :invalid_pr_payload}
      [first | _] -> {:ok, first}
    end
  end

  defp pr_sort_key(pr) do
    {
      if(pr_state(pr) == "OPEN", do: 0, else: 1),
      if(pr["isDraft"] == true, do: 1, else: 0),
      pr_merge_state_rank(pr["mergeStateStatus"]),
      -pr_number(pr)
    }
  end

  defp pr_state(%{"state" => state}) when is_binary(state), do: String.upcase(state)
  defp pr_state(_pr), do: nil

  defp pr_merge_state_rank("CLEAN"), do: 0
  defp pr_merge_state_rank("HAS_HOOKS"), do: 1
  defp pr_merge_state_rank("UNKNOWN"), do: 2
  defp pr_merge_state_rank("DIRTY"), do: 3
  defp pr_merge_state_rank(_state), do: 4

  defp pr_number(%{"number" => number}) when is_integer(number), do: number
  defp pr_number(_pr), do: 0

  defp github_pr_list_args(repo, head_branch, state) do
    [
      "pr",
      "list",
      "--repo",
      repo,
      "--state",
      state,
      "--json",
      "number,url,headRefName,isDraft,mergeStateStatus,state",
      "--head",
      head_branch
    ]
  end

  defp github_pr_search_args(repo, issue_identifier, state) do
    [
      "pr",
      "list",
      "--repo",
      repo,
      "--state",
      state,
      "--json",
      "number,url,headRefName,isDraft,mergeStateStatus,state",
      "--search",
      "#{issue_identifier} in:title,body"
    ]
  end
end
