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
      command = github_pr_list_args(repo, head_branch)

      case normalize_command_result(deps.run_command.(gh_bin, command, stderr_to_stdout: true)) do
        {:ok, {output, 0}} -> parse_gh_response(output)
        {:ok, {_output, status}} -> {:error, {:gh_command_failed, status}}
        {:error, reason} -> {:error, {:gh_command_failed, reason}}
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
