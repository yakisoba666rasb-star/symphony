defmodule SymphonyElixir.GitHubPrPublisher do
  @moduledoc """
  Publishes completed workspace changes to GitHub and opens a draft pull request.

  Codex runs in a guarded command environment, so the runtime owns the final
  GitHub handoff instead of asking the agent to push branches or create PRs.
  """

  alias SymphonyElixir.GitHubPrLookup
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepositoryResolver

  @type pr_map() :: %{String.t() => term()}

  @type command_result ::
          {String.t(), integer()} | {:ok, {String.t(), integer()}} | {:error, term()}

  @type deps :: %{
          required(:find_git_bin) => (-> String.t() | nil),
          required(:find_gh_bin) => (-> String.t() | nil),
          required(:run_command) => (String.t(), [String.t()], keyword() -> command_result())
        }

  @spec publish_workspace(String.t(), String.t(), Issue.t() | map(), deps()) ::
          {:ok, pr_map()} | {:error, term()}
  def publish_workspace(workspace_path, head_branch, issue, deps \\ runtime_deps())
      when is_binary(workspace_path) and is_binary(head_branch) do
    with {:ok, git_bin} <- find_binary(deps, :find_git_bin, :git_not_found),
         {:ok, gh_bin} <- find_binary(deps, :find_gh_bin, :gh_not_found),
         :ok <- ensure_workspace_has_changes(workspace_path, git_bin, deps),
         {:ok, remote_url} <- git_output(workspace_path, git_bin, ["remote", "get-url", "origin"], deps),
         {:ok, repo} <- parse_remote_url(remote_url),
         {:ok, base_branch} <- default_base_branch(workspace_path, git_bin, deps),
         :ok <- ensure_git_identity(workspace_path, git_bin, deps),
         :ok <- git_ok(workspace_path, git_bin, ["checkout", "-B", head_branch], deps),
         :ok <- git_ok(workspace_path, git_bin, ["add", "-A"], deps),
         :ok <- ensure_staged_changes(workspace_path, git_bin, deps),
         :ok <- git_ok(workspace_path, git_bin, ["commit", "-m", commit_message(issue)], deps),
         :ok <- git_ok(workspace_path, git_bin, ["push", "-u", "origin", "HEAD:refs/heads/#{head_branch}"], deps) do
      publish_or_refresh_pr(workspace_path, gh_bin, repo, head_branch, base_branch, issue, deps)
    end
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      find_git_bin: fn -> System.find_executable("git") end,
      find_gh_bin: fn -> System.find_executable("gh") end,
      run_command: &run_system_cmd/3
    }
  end

  defp run_system_cmd(cmd, args, opts), do: {:ok, System.cmd(cmd, args, opts)}

  defp find_binary(deps, key, error) do
    case deps[key].() do
      nil -> {:error, error}
      path -> {:ok, path}
    end
  end

  defp ensure_workspace_has_changes(workspace_path, git_bin, deps) do
    case git_output(workspace_path, git_bin, ["status", "--porcelain"], deps) do
      {:ok, ""} -> {:error, :no_workspace_changes}
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_base_branch(workspace_path, git_bin, deps) do
    case git_output(workspace_path, git_bin, ["rev-parse", "--abbrev-ref", "origin/HEAD"], deps) do
      {:ok, "origin/" <> branch} when branch != "" -> {:ok, branch}
      {:ok, branch} when branch != "" -> {:ok, branch}
      _other -> {:ok, "main"}
    end
  end

  defp ensure_git_identity(workspace_path, git_bin, deps) do
    with :ok <- ensure_git_config(workspace_path, git_bin, "user.name", "Symphony Runtime", deps),
         :ok <- ensure_git_config(workspace_path, git_bin, "user.email", "symphony-runtime@users.noreply.github.com", deps) do
      :ok
    end
  end

  defp ensure_git_config(workspace_path, git_bin, key, value, deps) do
    case git_output(workspace_path, git_bin, ["config", "--get", key], deps) do
      {:ok, current} when current != "" -> :ok
      _other -> git_ok(workspace_path, git_bin, ["config", key, value], deps)
    end
  end

  defp ensure_staged_changes(workspace_path, git_bin, deps) do
    case run_command(git_bin, ["-C", workspace_path, "diff", "--cached", "--quiet"], deps, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> {:error, :no_staged_changes}
      {:ok, {_output, 1}} -> :ok
      {:ok, {output, status}} -> {:error, {:git_command_failed, ["diff", "--cached", "--quiet"], status, output}}
      {:error, reason} -> {:error, {:git_command_failed, ["diff", "--cached", "--quiet"], reason}}
    end
  end

  defp create_draft_pr(workspace_path, gh_bin, repo, head_branch, base_branch, issue, deps) do
    args = [
      "pr",
      "create",
      "--repo",
      repo,
      "--head",
      head_branch,
      "--base",
      base_branch,
      "--title",
      pr_title(issue),
      "--body",
      pr_body(issue),
      "--draft"
    ]

    case run_command(gh_bin, args, deps, cd: workspace_path, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, extract_pr_url(output)}
      {:ok, {output, status}} -> {:error, {:gh_pr_create_failed, status, output}}
      {:error, reason} -> {:error, {:gh_pr_create_failed, reason}}
    end
  end

  defp publish_or_refresh_pr(workspace_path, gh_bin, repo, head_branch, base_branch, issue, deps) do
    case create_draft_pr(workspace_path, gh_bin, repo, head_branch, base_branch, issue, deps) do
      {:ok, pr_url} ->
        case GitHubPrLookup.lookup_by_head(repo, head_branch, deps) do
          {:ok, %{} = pr} -> {:ok, pr}
          {:ok, nil} -> {:ok, %{"url" => pr_url, "headRefName" => head_branch, "isDraft" => true}}
          {:error, _reason} -> {:ok, %{"url" => pr_url, "headRefName" => head_branch, "isDraft" => true}}
        end

      {:error, create_reason} ->
        case GitHubPrLookup.lookup_by_head(repo, head_branch, deps) do
          {:ok, %{} = pr} -> {:ok, pr}
          _other -> {:error, create_reason}
        end
    end
  end

  defp git_ok(workspace_path, git_bin, args, deps) do
    case run_command(git_bin, ["-C", workspace_path | args], deps, stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> {:error, {:git_command_failed, args, status, output}}
      {:error, reason} -> {:error, {:git_command_failed, args, reason}}
    end
  end

  defp git_output(workspace_path, git_bin, args, deps) do
    case run_command(git_bin, ["-C", workspace_path | args], deps, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {output, status}} -> {:error, {:git_command_failed, args, status, output}}
      {:error, reason} -> {:error, {:git_command_failed, args, reason}}
    end
  end

  defp run_command(cmd, args, deps, opts) do
    normalize_command_result(deps.run_command.(cmd, args, opts))
  end

  defp normalize_command_result({output, status}) when is_binary(output) and is_integer(status),
    do: {:ok, {output, status}}

  defp normalize_command_result(result), do: result

  defp parse_remote_url(raw_remote_url) when is_binary(raw_remote_url) do
    remote_url = String.trim(raw_remote_url)

    case Regex.run(~r/^git@([^:]+):(.+)$/, remote_url) do
      [_, host, path] ->
        if github_host?(host), do: parse_owner_repo(path), else: {:error, {:unsupported_remote_url, raw_remote_url}}

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
  defp github_host?("github" <> <<separator::binary-size(1)>> <> _rest) when separator in ["-", "."], do: true
  defp github_host?(_host), do: false

  defp parse_owner_repo(raw_path) do
    path = String.trim_trailing(String.trim_leading(raw_path, "/"), ".git")

    case String.split(path, "/", parts: 3) do
      [owner, repo] when owner != "" and repo != "" -> {:ok, owner <> "/" <> repo}
      _ -> {:error, {:unsupported_remote_url, raw_path}}
    end
  end

  defp commit_message(issue), do: "#{issue_identifier(issue)}: #{issue_title(issue)}"
  defp pr_title(issue), do: "[codex] #{issue_identifier(issue)} #{issue_title(issue)}"

  defp pr_body(issue) do
    issue_url = issue_value(issue, :url) || "n/a"
    github_issue_url = github_issue_url(issue)

    """
    Automated Symphony runtime handoff for #{issue_identifier(issue)}.

    PR URL is required before In Review handoff. The runtime created this draft PR after Codex completed workspace changes.

    Linear: #{issue_url}
    #{source_issue_line(github_issue_url)}
    """
  end

  defp source_issue_line(nil), do: ""
  defp source_issue_line(url), do: "Source GitHub issue: #{url}"

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: "issue"

  defp issue_title(%Issue{title: title}) when is_binary(title) and title != "", do: title
  defp issue_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp issue_title(_issue), do: "Automated changes"

  defp issue_value(%Issue{} = issue, key), do: Map.get(issue, key)
  defp issue_value(issue, key) when is_map(issue), do: Map.get(issue, key)
  defp issue_value(_issue, _key), do: nil

  defp github_issue_url(issue) do
    RepositoryResolver.source_github_issue_url(issue)
  end

  defp extract_pr_url(output) do
    output
    |> String.split(~r/\s+/, trim: true)
    |> Enum.find(String.trim(output), &String.starts_with?(&1, "https://"))
  end
end
