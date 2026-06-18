defmodule SymphonyElixir.GitHubIssueCloseBackfill do
  @moduledoc """
  Backfills GitHub source issue closes for Linear issues that are already Done.

  This is an operational safety net for historical sync drift. The runtime Done
  sync handles new cases, while this module lets operators detect and repair old
  Linear-Done/GitHub-open mismatches in a dry-run-first flow.
  """

  alias SymphonyElixir.{GitHubIssue, Linear.Client, Linear.Issue, RepositoryResolver}

  defstruct inspected: 0,
            candidates: 0,
            closed: 0,
            already_closed: 0,
            not_applicable: 0,
            skipped: 0,
            errors: [],
            actions: []

  @type action :: %{
          issue: String.t() | nil,
          url: String.t(),
          status: atom(),
          reason: term() | nil
        }

  @type t :: %__MODULE__{
          inspected: non_neg_integer(),
          candidates: non_neg_integer(),
          closed: non_neg_integer(),
          already_closed: non_neg_integer(),
          not_applicable: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [action()],
          actions: [action()]
        }

  @spec run(keyword()) :: {:ok, t()} | {:error, term()}
  def run(opts) when is_list(opts) do
    repo = Keyword.fetch!(opts, :repo)
    states = Keyword.get(opts, :states, ["Done"])
    execute? = Keyword.get(opts, :execute, false)
    linear_client = Keyword.get(opts, :linear_client, Client)
    github_issue = Keyword.get(opts, :github_issue, GitHubIssue)
    linear_scope_opts = Keyword.take(opts, [:all_projects, :project_slug, :team_key])

    with :ok <- validate_repo(repo),
         :ok <- validate_states(states),
         {:ok, issues} <- fetch_linear_issues(linear_client, states, linear_scope_opts) do
      summary =
        Enum.reduce(issues, %__MODULE__{}, fn issue, summary ->
          process_issue(summary, issue, repo, execute?, github_issue)
        end)

      {:ok, finalize_summary(summary)}
    end
  end

  defp fetch_linear_issues(linear_client, states, []), do: linear_client.fetch_issues_by_states(states)

  defp fetch_linear_issues(linear_client, states, linear_scope_opts) do
    if function_exported?(linear_client, :fetch_issues_by_states, 2) do
      linear_client.fetch_issues_by_states(states, linear_scope_opts)
    else
      linear_client.fetch_issues_by_states(states)
    end
  end

  defp process_issue(%__MODULE__{} = summary, %Issue{} = issue, repo, execute?, github_issue) do
    summary = %{summary | inspected: summary.inspected + 1}

    case source_issue_url_for_repo(issue, repo) do
      nil ->
        %{summary | skipped: summary.skipped + 1}

      issue_url ->
        classify_source_issue(summary, issue, repo, issue_url, execute?, github_issue)
    end
  end

  defp process_issue(%__MODULE__{} = summary, _issue, _repo, _execute?, _github_issue) do
    %{summary | inspected: summary.inspected + 1, skipped: summary.skipped + 1}
  end

  defp classify_source_issue(summary, issue, repo, issue_url, execute?, github_issue) do
    case github_issue.closed_at(repo, issue_url) do
      {:ok, closed_at} when is_binary(closed_at) ->
        record_action(summary, issue, issue_url, :already_closed, closed_at)

      {:ok, nil} ->
        summary = %{summary | candidates: summary.candidates + 1}

        if execute? do
          close_source_issue(summary, issue, repo, issue_url, github_issue)
        else
          record_action(summary, issue, issue_url, :would_close, nil)
        end

      {:error, reason} ->
        record_error(summary, issue, issue_url, {:closed_at_failed, reason})
    end
  end

  defp close_source_issue(summary, issue, repo, issue_url, github_issue) do
    case github_issue.close_if_open(repo, issue_url, close_comment(issue)) do
      {:ok, :closed} ->
        record_action(%{summary | closed: summary.closed + 1}, issue, issue_url, :closed, nil)

      {:ok, :already_closed} ->
        record_action(summary, issue, issue_url, :already_closed, nil)

      {:ok, :not_applicable} ->
        record_action(%{summary | not_applicable: summary.not_applicable + 1}, issue, issue_url, :not_applicable, nil)

      {:error, reason} ->
        record_error(summary, issue, issue_url, {:close_failed, reason})
    end
  end

  defp source_issue_url_for_repo(%Issue{} = issue, repo) do
    issue
    |> RepositoryResolver.source_github_issue_url()
    |> normalize_issue_url_for_repo(repo)
  end

  defp normalize_issue_url_for_repo(url, repo) when is_binary(url) do
    trimmed = String.trim(url)

    case Regex.run(~r{^https://github\.com/([^/]+/[^/]+)/issues/\d+(?:[/?#].*)?$}i, trimmed) do
      [_, url_repo] ->
        if String.downcase(url_repo) == String.downcase(repo), do: trimmed

      _other ->
        nil
    end
  end

  defp normalize_issue_url_for_repo(_url, _repo), do: nil

  defp record_action(summary, issue, issue_url, status, reason) do
    summary =
      case status do
        :already_closed -> %{summary | already_closed: summary.already_closed + 1}
        _ -> summary
      end

    %{summary | actions: [action(issue, issue_url, status, reason) | summary.actions]}
  end

  defp record_error(summary, issue, issue_url, reason) do
    %{summary | errors: [action(issue, issue_url, :error, reason) | summary.errors]}
  end

  defp action(%Issue{} = issue, issue_url, status, reason) do
    %{
      issue: issue.identifier || issue.id,
      url: issue_url,
      status: status,
      reason: reason
    }
  end

  defp finalize_summary(%__MODULE__{} = summary) do
    %{summary | actions: Enum.reverse(summary.actions), errors: Enum.reverse(summary.errors)}
  end

  defp close_comment(%Issue{} = issue) do
    """
    Closed by `mix symphony.github_issue_close_backfill` because the corresponding Linear issue is already Done.

    Linear issue: #{issue.identifier || issue.id || "unknown"}
    Linear URL: #{issue.url || "unknown"}
    """
    |> String.trim()
  end

  defp validate_repo(repo) when is_binary(repo) do
    if Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, String.trim(repo)) do
      :ok
    else
      {:error, {:invalid_repo, repo}}
    end
  end

  defp validate_repo(repo), do: {:error, {:invalid_repo, repo}}

  defp validate_states(states) when is_list(states) do
    if Enum.all?(states, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, {:invalid_states, states}}
    end
  end

  defp validate_states(states), do: {:error, {:invalid_states, states}}
end
