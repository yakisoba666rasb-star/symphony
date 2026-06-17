defmodule SymphonyElixir.GitHubPrLookup do
  @moduledoc "Lookup GitHub pull requests by repository, head branch, and linked issue metadata."

  alias SymphonyElixir.GitHubCommand

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

  @spec lookup_workspace_head(String.t(), String.t(), deps()) :: {:ok, nil | pr_map()} | {:error, term()}
  def lookup_workspace_head(workspace_path, head_branch, deps \\ runtime_deps())
      when is_binary(workspace_path) and is_binary(head_branch) do
    with {:ok, repo} <- workspace_repo(workspace_path, deps) do
      lookup_by_head(repo, head_branch, deps)
    end
  end

  @spec lookup_workspace_handoff_pr(String.t(), String.t(), [String.t()], deps()) ::
          {:ok, nil | pr_map()} | {:error, term()}
  def lookup_workspace_handoff_pr(workspace_path, head_branch, attachment_urls, deps \\ runtime_deps())
      when is_binary(workspace_path) and is_binary(head_branch) and is_list(attachment_urls) do
    with {:ok, repo} <- workspace_repo(workspace_path, deps) do
      branch_candidates = handoff_branch_candidates(workspace_path, head_branch, deps)

      case lookup_by_head_candidates(repo, branch_candidates, deps) do
        {:ok, {%{} = pr, source, matched_branch}} ->
          {:ok, tag_lookup_source(pr, source, head_branch, matched_branch)}

        {:ok, nil} ->
          lookup_linked_or_workspace_head_pull_request(repo, workspace_path, head_branch, attachment_urls, deps)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec lookup_merged_linked_pull_request(String.t(), [String.t()], deps()) ::
          {:ok, nil | pr_map()} | {:error, term()}
  def lookup_merged_linked_pull_request(repo, attachment_urls, deps \\ runtime_deps())
      when is_binary(repo) and is_list(attachment_urls) do
    with {:ok, gh_bin} <- find_gh_binary(deps),
         {:ok, pull_number} <- linked_pull_number(repo, attachment_urls),
         {:ok, pr} <- view_pull_request(gh_bin, repo, pull_number, deps, :merged_sync),
         :ok <- validate_merged_linked_pull_request(pr) do
      {:ok, tag_lookup_source(pr, "merged_linked_pull_request", nil)}
    else
      :none -> {:ok, nil}
      {:error, {:linked_pull_request_not_merged, _number}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec lookup_merged_issue_pull_request(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          deps()
        ) ::
          {:ok, nil | pr_map()} | {:error, term()}
  def lookup_merged_issue_pull_request(repo, issue_identifier, issue_url, branch_name, deps \\ runtime_deps())
      when is_binary(repo) do
    with {:ok, gh_bin} <- find_gh_binary(deps) do
      issue_pr_search_terms(issue_identifier, issue_url, branch_name)
      |> lookup_merged_issue_pr_candidates(gh_bin, repo, deps)
      |> pick_merged_issue_pull_request(issue_identifier, issue_url, branch_name)
    end
  end

  @spec lookup_open_issue_pull_request(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          [String.t()],
          deps()
        ) ::
          {:ok, nil | pr_map()} | {:error, term()}
  def lookup_open_issue_pull_request(
        repo,
        issue_identifier,
        issue_url,
        branch_name,
        attachment_urls,
        deps \\ runtime_deps()
      )
      when is_binary(repo) and is_list(attachment_urls) do
    with {:ok, gh_bin} <- find_gh_binary(deps) do
      case lookup_open_issue_pull_request_by_issue(repo, issue_identifier, issue_url, branch_name, gh_bin, deps) do
        {:ok, %{} = pr} ->
          {:ok, pr}

        {:ok, nil} ->
          lookup_linked_pull_request(repo, branch_name, attachment_urls, deps)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp lookup_open_issue_pull_request_by_issue(repo, issue_identifier, issue_url, branch_name, gh_bin, deps) do
    issue_pr_search_terms(issue_identifier, issue_url, branch_name)
    |> lookup_open_issue_pr_candidates(gh_bin, repo, deps)
    |> pick_open_issue_pull_request(issue_identifier, issue_url, branch_name)
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      find_gh_bin: fn -> System.find_executable("gh") end,
      find_git_bin: fn -> System.find_executable("git") end,
      run_command: &run_system_cmd/3
    }
  end

  @doc false
  @spec run_system_cmd(String.t(), [String.t()], keyword()) :: command_result()
  def run_system_cmd(cmd, args, opts) do
    GitHubCommand.run_system_cmd(cmd, args, opts)
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

  defp handoff_branch_candidates(workspace_path, expected_branch, deps) do
    [{"branch", expected_branch} | workspace_branch_candidates(workspace_path, deps)]
    |> Enum.map(fn {source, branch} -> {source, normalize_branch_candidate(branch)} end)
    |> Enum.filter(fn {_source, branch} -> valid_branch_candidate?(branch) end)
    |> Enum.uniq_by(fn {_source, branch} -> branch end)
  end

  defp workspace_branch_candidates(workspace_path, deps) do
    case find_git_binary(deps) do
      {:ok, git_bin} ->
        [
          {"workspace_branch", query_current_branch(workspace_path, git_bin, deps)},
          {"workspace_upstream_branch", query_upstream_branch(workspace_path, git_bin, deps)}
        ]
        |> Enum.flat_map(fn
          {source, {:ok, branch}} -> [{source, branch}]
          {_source, :none} -> []
        end)

      {:error, _reason} ->
        []
    end
  end

  defp query_current_branch(workspace_path, git_bin, deps) do
    query_git_branch(workspace_path, git_bin, ["branch", "--show-current"], deps)
  end

  defp query_upstream_branch(workspace_path, git_bin, deps) do
    case query_git_branch(workspace_path, git_bin, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], deps) do
      {:ok, upstream} -> {:ok, strip_remote_prefix(upstream)}
      :none -> :none
    end
  end

  defp query_git_branch(workspace_path, git_bin, git_args, deps) do
    args = ["-C", workspace_path | git_args]

    case normalize_command_result(deps.run_command.(git_bin, args, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> {:ok, String.trim(output)}
      {:ok, {_output, _status}} -> :none
      {:error, _reason} -> :none
    end
  end

  defp strip_remote_prefix(branch) when is_binary(branch) do
    case String.split(String.trim(branch), "/", parts: 2) do
      [_remote, rest] when rest != "" -> rest
      [value] -> value
    end
  end

  defp normalize_branch_candidate(branch) when is_binary(branch), do: String.trim(branch)
  defp normalize_branch_candidate(_branch), do: nil

  defp valid_branch_candidate?(branch) when is_binary(branch) do
    branch != "" and
      branch != "HEAD" and
      not String.starts_with?(branch, "/") and
      not String.starts_with?(branch, ["http://", "https://", "git@"]) and
      not String.contains?(branch, "github.com/") and
      not String.ends_with?(branch, ".git") and
      not String.starts_with?(branch, "fatal:") and
      not String.contains?(branch, ["\n", "\r", <<0>>])
  end

  defp valid_branch_candidate?(_branch), do: false

  defp workspace_repo(workspace_path, deps) do
    with {:ok, git_bin} <- find_git_binary(deps),
         {:ok, remote_url} <- query_remote_url(workspace_path, git_bin, deps) do
      parse_remote_url(remote_url)
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

  defp parse_gh_pr_view_response(output) do
    case Jason.decode(output) do
      {:ok, %{} = pr} -> {:ok, pr}
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

  defp lookup_by_head_candidates(_repo, [], _deps), do: {:ok, nil}

  defp lookup_by_head_candidates(repo, [{source, branch} | rest], deps) do
    case lookup_by_head(repo, branch, deps) do
      {:ok, %{} = pr} -> {:ok, {pr, source, branch}}
      {:ok, nil} -> lookup_by_head_candidates(repo, rest, deps)
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup_linked_or_workspace_head_pull_request(repo, workspace_path, expected_branch, attachment_urls, deps) do
    case lookup_linked_pull_request(repo, expected_branch, attachment_urls, deps) do
      {:ok, %{} = pr} -> {:ok, pr}
      {:ok, nil} -> lookup_workspace_head_commit_pull_request(repo, workspace_path, expected_branch, deps)
      {:error, reason} -> lookup_workspace_head_after_linked_error(repo, workspace_path, expected_branch, deps, reason)
    end
  end

  defp lookup_workspace_head_after_linked_error(
         repo,
         workspace_path,
         expected_branch,
         deps,
         linked_reason
       ) do
    case lookup_workspace_head_commit_pull_request(repo, workspace_path, expected_branch, deps) do
      {:ok, %{} = pr} ->
        {:ok, pr}

      {:ok, nil} ->
        {:error, linked_reason}

      {:error, workspace_head_reason} ->
        {:error, linked_workspace_head_error(linked_reason, workspace_head_reason)}
    end
  end

  defp linked_workspace_head_error(linked_reason, workspace_head_reason) do
    {
      :linked_pull_request_lookup_failed,
      linked_reason,
      {:workspace_head_lookup_failed, workspace_head_reason}
    }
  end

  defp lookup_linked_pull_request(repo, expected_branch, attachment_urls, deps) do
    with {:ok, gh_bin} <- find_gh_binary(deps),
         {:ok, pull_number} <- linked_pull_number(repo, attachment_urls),
         {:ok, pr} <- view_pull_request(gh_bin, repo, pull_number, deps),
         :ok <- validate_linked_pull_request(pr) do
      {:ok, tag_lookup_source(pr, "linked_pull_request", expected_branch)}
    else
      :none -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup_workspace_head_commit_pull_request(repo, workspace_path, expected_branch, deps) do
    with {:ok, gh_bin} <- find_gh_binary(deps),
         {:ok, git_bin} <- find_git_binary(deps),
         {:ok, head_sha} <- query_workspace_head_sha(workspace_path, git_bin, deps) do
      lookup_workspace_head_commit_pull_request_by_sha(gh_bin, repo, head_sha, expected_branch, deps)
    else
      :none -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup_workspace_head_commit_pull_request_by_sha(gh_bin, repo, head_sha, expected_branch, deps) do
    command = github_pull_requests_for_commit_args(repo, head_sha)

    case normalize_command_result(deps.run_command.(gh_bin, command, stderr_to_stdout: true)) do
      {:ok, {output, 0}} ->
        output
        |> parse_commit_pull_request_response()
        |> match_pr_by_head_sha(head_sha, expected_branch)

      {:ok, {_output, status}} ->
        {:error, {:gh_command_failed, status}}

      {:error, reason} ->
        {:error, {:gh_command_failed, reason}}
    end
  end

  defp query_workspace_head_sha(workspace_path, git_bin, deps) do
    args = ["-C", workspace_path, "rev-parse", "HEAD"]

    case normalize_command_result(deps.run_command.(git_bin, args, stderr_to_stdout: true)) do
      {:ok, {output, 0}} ->
        case String.trim(output) do
          <<sha::binary-size(40)>> -> {:ok, sha}
          _other -> :none
        end

      {:ok, {_output, _status}} ->
        :none

      {:error, _reason} ->
        :none
    end
  end

  defp parse_gh_pr_list_response(output) do
    case Jason.decode(output) do
      {:ok, values} when is_list(values) -> {:ok, Enum.filter(values, &is_map/1)}
      {:ok, _other} -> {:error, :invalid_pr_payload}
      {:error, reason} -> {:error, {:gh_json_error, reason}}
    end
  end

  defp parse_commit_pull_request_response(output) do
    with {:ok, prs} <- parse_gh_pr_list_response(output) do
      {:ok, Enum.map(prs, &normalize_commit_pull_request/1)}
    end
  end

  defp normalize_commit_pull_request(%{"head" => %{} = head} = pr) do
    pr
    |> Map.put_new("url", pr["html_url"])
    |> Map.put_new("headRefName", head["ref"])
    |> Map.put_new("headRefOid", head["sha"])
    |> Map.put_new("isDraft", pr["draft"])
    |> Map.put_new("mergeStateStatus", pr["mergeable_state"])
  end

  defp normalize_commit_pull_request(pr), do: pr

  defp match_pr_by_head_sha({:ok, prs}, head_sha, expected_branch) do
    prs
    |> Enum.filter(&(String.downcase(to_string(&1["headRefOid"])) == String.downcase(head_sha)))
    |> reject_draft_closed_prs()
    |> pick_head_sha_pr()
    |> case do
      {:ok, %{} = pr} -> {:ok, tag_lookup_source(pr, "workspace_head_sha", expected_branch, pr["headRefName"])}
      {:ok, nil} -> {:ok, nil}
    end
  end

  defp match_pr_by_head_sha({:error, reason}, _head_sha, _expected_branch), do: {:error, reason}

  defp issue_pr_search_terms(issue_identifier, issue_url, branch_name) do
    [branch_name, issue_url, issue_identifier]
    |> Enum.filter(&present_string?/1)
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
  end

  defp lookup_open_issue_pr_candidates([], _gh_bin, _repo, _deps), do: {:ok, []}

  defp lookup_open_issue_pr_candidates([term | rest], gh_bin, repo, deps) do
    case list_open_issue_pr_candidates(gh_bin, repo, term, deps) do
      {:ok, []} -> lookup_open_issue_pr_candidates(rest, gh_bin, repo, deps)
      {:ok, prs} -> {:ok, prs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_open_issue_pr_candidates(gh_bin, repo, search_term, deps) do
    command = github_pr_open_search_args(repo, search_term)

    case normalize_command_result(deps.run_command.(gh_bin, command, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> parse_gh_pr_list_response(output)
      {:ok, {_output, status}} -> {:error, {:gh_command_failed, status}}
      {:error, reason} -> {:error, {:gh_command_failed, reason}}
    end
  end

  defp pick_open_issue_pull_request({:error, reason}, _issue_identifier, _issue_url, _branch_name),
    do: {:error, reason}

  defp pick_open_issue_pull_request({:ok, prs}, issue_identifier, issue_url, branch_name) do
    prs
    |> Enum.filter(&(open_reviewable_pr?(&1) and issue_pr_evidence?(&1, issue_identifier, issue_url, branch_name)))
    |> pick_best_open_issue_pr(issue_identifier, issue_url, branch_name)
  end

  defp open_reviewable_pr?(%{"state" => state, "isDraft" => is_draft}) do
    String.upcase(to_string(state)) == "OPEN" and is_draft != true
  end

  defp open_reviewable_pr?(_pr), do: false

  defp pick_best_open_issue_pr([], _issue_identifier, _issue_url, _branch_name), do: {:ok, nil}

  defp pick_best_open_issue_pr(prs, issue_identifier, issue_url, branch_name) do
    with :miss <- pick_unique_open_by(prs, &pr_branch_matches?(&1, branch_name)),
         :miss <- pick_unique_open_by(prs, &pr_text_contains?(&1, issue_url)),
         :miss <- pick_unique_open_by(prs, &pr_text_contains?(&1, issue_identifier)) do
      case Enum.uniq_by(prs, &pr_number/1) do
        [pr] ->
          {:ok, tag_lookup_source(pr, "open_issue_pull_request", branch_name, pr["headRefName"])}

        values ->
          {:error, {:ambiguous_open_issue_pull_requests, Enum.map(values, &pr_url/1)}}
      end
    end
  end

  defp pick_unique_open_by(prs, predicate) when is_function(predicate, 1) do
    prs
    |> Enum.filter(predicate)
    |> Enum.uniq_by(&pr_number/1)
    |> case do
      [pr] -> {:ok, tag_lookup_source(pr, "open_issue_pull_request", nil, pr["headRefName"])}
      [] -> :miss
      values -> {:error, {:ambiguous_open_issue_pull_requests, Enum.map(values, &pr_url/1)}}
    end
  end

  defp lookup_merged_issue_pr_candidates([], _gh_bin, _repo, _deps), do: {:ok, []}

  defp lookup_merged_issue_pr_candidates([term | rest], gh_bin, repo, deps) do
    case list_merged_issue_pr_candidates(gh_bin, repo, term, deps) do
      {:ok, []} -> lookup_merged_issue_pr_candidates(rest, gh_bin, repo, deps)
      {:ok, prs} -> {:ok, prs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_merged_issue_pr_candidates(gh_bin, repo, search_term, deps) do
    command = github_pr_merged_search_args(repo, search_term)

    case normalize_command_result(deps.run_command.(gh_bin, command, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> parse_gh_pr_list_response(output)
      {:ok, {_output, status}} -> {:error, {:gh_command_failed, status}}
      {:error, reason} -> {:error, {:gh_command_failed, reason}}
    end
  end

  defp pick_merged_issue_pull_request({:error, reason}, _issue_identifier, _issue_url, _branch_name),
    do: {:error, reason}

  defp pick_merged_issue_pull_request({:ok, prs}, issue_identifier, issue_url, branch_name) do
    prs
    |> Enum.filter(&(merged_pr?(&1) and issue_pr_evidence?(&1, issue_identifier, issue_url, branch_name)))
    |> pick_best_merged_issue_pr(issue_identifier, issue_url, branch_name)
  end

  defp merged_pr?(%{"state" => state, "mergedAt" => merged_at}) do
    String.upcase(to_string(state)) == "MERGED" or present_string?(merged_at)
  end

  defp merged_pr?(_pr), do: false

  defp issue_pr_evidence?(pr, issue_identifier, issue_url, branch_name) do
    pr_text_contains?(pr, issue_identifier) or
      pr_text_contains?(pr, issue_url) or
      pr_branch_matches?(pr, branch_name)
  end

  defp pr_text_contains?(_pr, value) when not is_binary(value), do: false

  defp pr_text_contains?(pr, value) do
    needle = String.trim(value)

    cond do
      needle == "" ->
        false

      url_like?(needle) ->
        pr
        |> pr_searchable_text()
        |> text_contains_case_insensitive?(needle)

      true ->
        pr
        |> pr_searchable_text()
        |> text_contains_token?(needle)
    end
  end

  defp pr_searchable_text(pr) do
    [pr["title"], pr["body"], pr["url"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp url_like?(value), do: Regex.match?(~r{^https?://}i, value)

  defp text_contains_case_insensitive?(text, needle) do
    text
    |> String.downcase()
    |> String.contains?(String.downcase(needle))
  end

  defp text_contains_token?(text, needle) do
    Regex.match?(~r/(^|[^A-Za-z0-9])#{Regex.escape(needle)}([^A-Za-z0-9]|$)/i, text)
  end

  defp pr_branch_matches?(_pr, branch_name) when not is_binary(branch_name), do: false

  defp pr_branch_matches?(pr, branch_name) do
    present_string?(branch_name) and String.trim(to_string(pr["headRefName"])) == String.trim(branch_name)
  end

  defp pick_best_merged_issue_pr([], _issue_identifier, _issue_url, _branch_name), do: {:ok, nil}

  defp pick_best_merged_issue_pr(prs, issue_identifier, issue_url, branch_name) do
    with :miss <- pick_unique_by(prs, &pr_branch_matches?(&1, branch_name)),
         :miss <- pick_unique_by(prs, &pr_text_contains?(&1, issue_url)),
         :miss <- pick_unique_by(prs, &pr_text_contains?(&1, issue_identifier)) do
      case Enum.uniq_by(prs, &pr_number/1) do
        [pr] ->
          {:ok, tag_lookup_source(pr, "merged_issue_pull_request", branch_name, pr["headRefName"])}

        values ->
          {:error, {:ambiguous_merged_issue_pull_requests, Enum.map(values, &pr_url/1)}}
      end
    end
  end

  defp pick_unique_by(prs, predicate) when is_function(predicate, 1) do
    prs
    |> Enum.filter(predicate)
    |> Enum.uniq_by(&pr_number/1)
    |> case do
      [pr] -> {:ok, tag_lookup_source(pr, "merged_issue_pull_request", nil, pr["headRefName"])}
      [] -> :miss
      values -> {:error, {:ambiguous_merged_issue_pull_requests, Enum.map(values, &pr_url/1)}}
    end
  end

  defp reject_draft_closed_prs(prs) do
    Enum.filter(prs, fn pr ->
      String.upcase(to_string(pr["state"])) == "OPEN" and pr["isDraft"] != true
    end)
  end

  defp pick_head_sha_pr([]), do: {:ok, nil}

  defp pick_head_sha_pr(prs) do
    prs
    |> Enum.sort_by(&pr_sort_key/1)
    |> List.first()
    |> then(&{:ok, &1})
  end

  defp linked_pull_number(repo, attachment_urls) do
    attachment_urls
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&linked_pull_url(repo, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(fn {_url, number} -> number end)
    |> case do
      [] -> :none
      [{_url, number}] -> {:ok, number}
      values -> {:error, {:ambiguous_linked_pull_requests, Enum.map(values, &elem(&1, 0))}}
    end
  end

  defp linked_pull_url(repo, url) do
    case Regex.run(~r{^https://github\.com/([^/]+/[^/]+)/pull/(\d+)(?:[/?#].*)?$}i, String.trim(url)) do
      [matched_url, url_repo, number] ->
        if String.downcase(url_repo) == String.downcase(repo) do
          {matched_url, String.to_integer(number)}
        end

      _other ->
        nil
    end
  end

  defp view_pull_request(gh_bin, repo, number, deps, mode \\ :handoff) when is_integer(number) do
    command = github_pr_view_args(repo, number, mode)

    case normalize_command_result(deps.run_command.(gh_bin, command, stderr_to_stdout: true)) do
      {:ok, {output, 0}} -> parse_gh_pr_view_response(output)
      {:ok, {_output, status}} -> {:error, {:gh_command_failed, status}}
      {:error, reason} -> {:error, {:gh_command_failed, reason}}
    end
  end

  defp validate_linked_pull_request(%{"state" => state, "isDraft" => is_draft} = pr) do
    cond do
      String.upcase(to_string(state)) != "OPEN" ->
        {:error, {:linked_pull_request_not_open, pr["number"]}}

      is_draft == true ->
        {:error, {:linked_pull_request_is_draft, pr["number"]}}

      true ->
        :ok
    end
  end

  defp validate_linked_pull_request(pr), do: {:error, {:invalid_linked_pull_request, pr}}

  defp validate_merged_linked_pull_request(%{"state" => state, "mergedAt" => merged_at} = pr) do
    if String.upcase(to_string(state)) == "MERGED" or present_string?(merged_at) do
      :ok
    else
      {:error, {:linked_pull_request_not_merged, pr["number"]}}
    end
  end

  defp validate_merged_linked_pull_request(pr), do: {:error, {:invalid_linked_pull_request, pr}}

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp tag_lookup_source(pr, source, expected_branch, matched_branch \\ nil) when is_map(pr) do
    pr
    |> Map.put("__symphonyLookupSource", source)
    |> Map.put("__symphonyExpectedBranch", expected_branch)
    |> maybe_put_matched_branch(matched_branch)
  end

  defp maybe_put_matched_branch(pr, branch) when is_binary(branch),
    do: Map.put(pr, "__symphonyMatchedBranch", branch)

  defp maybe_put_matched_branch(pr, _branch), do: pr

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

  defp pr_url(%{"url" => url}) when is_binary(url), do: url
  defp pr_url(%{"number" => number}) when is_integer(number), do: Integer.to_string(number)
  defp pr_url(_pr), do: "(unknown)"

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

  defp github_pull_requests_for_commit_args(repo, sha) do
    [
      "api",
      "-H",
      "Accept: application/vnd.github+json",
      "/repos/#{repo}/commits/#{sha}/pulls"
    ]
  end

  defp github_pr_merged_search_args(repo, search_term) do
    [
      "pr",
      "list",
      "--repo",
      repo,
      "--state",
      "merged",
      "--limit",
      "50",
      "--search",
      search_term,
      "--json",
      "number,url,headRefName,isDraft,mergeStateStatus,state,createdAt,mergedAt,title,body"
    ]
  end

  defp github_pr_open_search_args(repo, search_term) do
    [
      "pr",
      "list",
      "--repo",
      repo,
      "--state",
      "open",
      "--limit",
      "50",
      "--search",
      search_term,
      "--json",
      "number,url,headRefName,isDraft,mergeStateStatus,state,title,body"
    ]
  end

  defp github_pr_view_args(repo, number, :handoff) do
    [
      "pr",
      "view",
      Integer.to_string(number),
      "--repo",
      repo,
      "--json",
      "number,url,headRefName,isDraft,mergeStateStatus,state"
    ]
  end

  defp github_pr_view_args(repo, number, :merged_sync) do
    [
      "pr",
      "view",
      Integer.to_string(number),
      "--repo",
      repo,
      "--json",
      "number,url,headRefName,isDraft,mergeStateStatus,state,createdAt,mergedAt"
    ]
  end
end
