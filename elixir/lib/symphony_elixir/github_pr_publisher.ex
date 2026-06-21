defmodule SymphonyElixir.GitHubPrPublisher do
  @moduledoc """
  Legacy helper that publishes completed workspace changes to GitHub and opens a
  draft pull request.

  The normal orchestrator path is agent-owned: Codex pushes branches and creates
  or updates PRs from the workspace. Keep this module for explicit recovery or
  compatibility paths only.
  """

  alias SymphonyElixir.{GitHubCommand, GitHubPrLookup}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.RepositoryResolver

  @runtime_control_pathspecs [
    ":!.symphony-review-verdict.json",
    ":!.symphony-review-verdict-*.json"
  ]

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
         :ok <- validate_branch_name(head_branch, git_bin, deps),
         :ok <- ensure_workspace_has_changes(workspace_path, git_bin, deps),
         {:ok, remote_url} <- git_output(workspace_path, git_bin, ["remote", "get-url", "origin"], deps),
         {:ok, repo} <- parse_remote_url(remote_url),
         {:ok, base_branch} <- default_base_branch(workspace_path, git_bin, deps),
         :ok <- ensure_git_identity(workspace_path, git_bin, deps),
         :ok <- git_ok(workspace_path, git_bin, ["checkout", "-B", head_branch], deps),
         :ok <- git_ok(workspace_path, git_bin, ["add", "-A", "--", "." | @runtime_control_pathspecs], deps),
         :ok <- ensure_staged_changes(workspace_path, git_bin, deps),
         :ok <- git_ok(workspace_path, git_bin, ["commit", "-m", commit_message(issue)], deps),
         :ok <-
           git_ok(
             workspace_path,
             git_bin,
             ["push", "--force-with-lease", "-u", "origin", "HEAD:refs/heads/#{head_branch}"],
             deps
           ) do
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

  defp run_system_cmd(cmd, args, opts), do: GitHubCommand.run_system_cmd(cmd, args, opts)

  defp find_binary(deps, key, error) do
    case deps[key].() do
      nil -> {:error, error}
      path -> {:ok, path}
    end
  end

  defp validate_branch_name("", _git_bin, _deps), do: {:error, {:invalid_branch_name, :empty}}

  defp validate_branch_name("-" <> _rest, _git_bin, _deps), do: {:error, {:invalid_branch_name, :leading_dash}}

  defp validate_branch_name(branch, git_bin, deps) when is_binary(branch) do
    cond do
      String.match?(branch, ~r/[\x00-\x1F\x7F]/) ->
        {:error, {:invalid_branch_name, :control_character}}

      String.match?(branch, ~r/\s/) ->
        {:error, {:invalid_branch_name, :whitespace}}

      String.contains?(branch, "..") ->
        {:error, {:invalid_branch_name, :dotdot}}

      true ->
        validate_branch_name_with_git(branch, git_bin, deps)
    end
  end

  defp validate_branch_name_with_git(branch, git_bin, deps) do
    case run_command(git_bin, ["check-ref-format", "--branch", branch], deps, stderr_to_stdout: true) do
      {:ok, {output, 0}} ->
        if String.trim(output) == branch do
          :ok
        else
          {:error, {:invalid_branch_name, :git_check_ref_format}}
        end

      {:ok, {_output, _status}} ->
        {:error, {:invalid_branch_name, :git_check_ref_format}}

      {:error, reason} ->
        {:error, {:git_command_failed, ["check-ref-format", "--branch", branch], reason}}
    end
  end

  defp ensure_workspace_has_changes(workspace_path, git_bin, deps) do
    case git_output(workspace_path, git_bin, ["status", "--porcelain", "--", "." | @runtime_control_pathspecs], deps) do
      {:ok, ""} -> {:error, :no_workspace_changes}
      {:ok, _status} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_base_branch(workspace_path, git_bin, deps) do
    case git_output(workspace_path, git_bin, ["rev-parse", "--abbrev-ref", "origin/HEAD"], deps) do
      {:ok, "origin/HEAD"} -> default_base_branch_from_github(workspace_path, deps)
      {:ok, "origin/" <> branch} when branch not in ["", "HEAD"] -> {:ok, branch}
      {:ok, branch} when branch not in ["", "HEAD"] -> {:ok, branch}
      _other -> default_base_branch_from_github(workspace_path, deps)
    end
  end

  defp ensure_git_identity(workspace_path, git_bin, deps) do
    case ensure_git_config(workspace_path, git_bin, "user.name", "Symphony Runtime", deps) do
      :ok ->
        ensure_git_config(workspace_path, git_bin, "user.email", "symphony-runtime@users.noreply.github.com", deps)

      {:error, _reason} = error ->
        error
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
      {:ok, {output, 0}} -> extract_pr_url(output)
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

  defp default_base_branch_from_github(workspace_path, deps) do
    with {:ok, gh_bin} <- find_binary(deps, :find_gh_bin, :gh_not_found),
         {:ok, {output, 0}} <-
           run_command(
             gh_bin,
             ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"],
             deps,
             cd: workspace_path,
             stderr_to_stdout: true
           ),
         branch when branch != "" <- String.trim(output) do
      {:ok, branch}
    else
      {:ok, {output, status}} -> {:error, {:gh_default_branch_failed, status, output}}
      {:error, reason} -> {:error, {:gh_default_branch_failed, reason}}
      "" -> {:error, :default_branch_not_found}
      nil -> {:error, :default_branch_not_found}
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
    #### Context

    Automated Symphony runtime handoff for #{issue_identifier(issue)}.

    #### TL;DR

    Runtime-created draft PR for #{issue_identifier(issue)}.

    #### Summary

    - Symphony created this draft PR after Codex completed workspace changes.
    - PR URL is required before In Review handoff.
    - Linear: #{issue_url}
    #{source_issue_lines(github_issue_url)}
    #### Alternatives

    - Keep runtime-created PRs under the repository PR description lint.

    #### Test Plan

    - [x] Runtime generated this draft PR body.
    """
  end

  defp source_issue_lines(nil), do: ""

  defp source_issue_lines(url) do
    case github_issue_reference(url) do
      nil -> "- Source GitHub issue: #{url}\n"
      reference -> "- Source GitHub issue: #{url}\n- Closes #{reference}\n"
    end
  end

  defp github_issue_reference(url) when is_binary(url) do
    case Regex.run(~r{https://github\.com/([^/]+/[^/]+)/issues/(\d+)(?:[/?#].*)?$}i, String.trim(url)) do
      [_, repo, number] -> "#{repo}##{number}"
      _other -> nil
    end
  end

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
    RepositoryResolver.labeled_source_github_issue_url(issue)
  end

  defp extract_pr_url(output) do
    output
    |> String.split(~r/\s+/, trim: true)
    |> Enum.find(&String.starts_with?(&1, "https://"))
    |> case do
      nil -> {:error, :pr_url_not_found}
      url -> {:ok, url}
    end
  end
end
