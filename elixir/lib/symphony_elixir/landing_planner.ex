defmodule SymphonyElixir.LandingPlanner do
  @moduledoc """
  Creates dry-run plans for the Approved to Land landing queue.

  This MVP is intentionally non-mutating beyond Linear comments. It does not
  move issues to Landing and does not merge pull requests.
  """

  require Logger

  alias SymphonyElixir.{Config, GitHubPrLookup, RepositoryResolver}
  alias SymphonyElixir.Linear.Issue

  @marker "<!-- symphony:approved-to-land:dry-run:v1"

  @type reconcile_result :: %{
          inspected: non_neg_integer(),
          commented: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer(),
          queue: [map()]
        }

  @spec marker() :: String.t()
  def marker, do: @marker

  @spec reconcile(Config.Schema.t(), module(), module()) :: reconcile_result()
  def reconcile(settings, tracker, pr_lookup \\ GitHubPrLookup) do
    result = empty_result()

    cond do
      not settings.landing.enabled ->
        result

      not function_exported?(tracker, :fetch_issues_by_states, 1) ->
        Logger.warning("Skipping Approved to Land dry-run planning; #{inspect(tracker)} does not export fetch_issues_by_states/1")
        result

      not function_exported?(tracker, :create_comment, 2) ->
        Logger.warning("Skipping Approved to Land dry-run planning; #{inspect(tracker)} does not export create_comment/2")
        result

      true ->
        do_reconcile(settings, tracker, pr_lookup, result)
    end
  end

  defp empty_result, do: %{inspected: 0, commented: 0, skipped: 0, errors: 0, queue: []}

  defp do_reconcile(settings, tracker, pr_lookup, result) do
    case tracker.fetch_issues_by_states([settings.landing.approval_state]) do
      {:ok, issues} when is_list(issues) ->
        plan_id = plan_id()
        queue = queue_entries(issues, plan_id, settings, pr_lookup)

        result =
          Enum.reduce(queue, %{result | queue: Enum.map(queue, &queue_payload/1)}, fn entry, acc ->
            maybe_comment_plan(entry, settings, tracker, acc)
          end)

        %{result | inspected: Enum.count(queue, &match?(%{issue: %Issue{}}, &1))}

      {:error, reason} ->
        Logger.warning("Skipping Approved to Land dry-run planning; failed to fetch issues: #{inspect(reason)}")
        %{result | errors: result.errors + 1}

      other ->
        Logger.warning("Skipping Approved to Land dry-run planning; unexpected fetch result: #{inspect(other)}")
        %{result | errors: result.errors + 1}
    end
  end

  defp queue_entries(issues, plan_id, settings, pr_lookup) do
    entries = Enum.map(issues, &queue_entry(&1, plan_id, settings, pr_lookup))
    total = length(entries)

    entries
    |> Enum.sort_by(&Map.fetch!(&1, :sort_key))
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, index} ->
      entry
      |> Map.put(:queue_position, index)
      |> Map.put(:queue_total, total)
    end)
  end

  defp queue_entry(%Issue{} = issue, plan_id, settings, pr_lookup) do
    snapshot = validation_snapshot(issue, settings, pr_lookup)
    action = if snapshot.status == :ready, do: "merge", else: "skip"

    %{
      issue: issue,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      project: issue.project_slug || issue.project_name,
      repository: snapshot.repository,
      pr_url: snapshot.pr_url,
      pr_state: snapshot.pr_state,
      draft: snapshot.draft,
      mergeability: snapshot.mergeability,
      review_decision: snapshot.review_decision,
      head_branch: snapshot.head_branch,
      head_sha: snapshot.head_sha,
      blocker: snapshot.blocker,
      status: Atom.to_string(snapshot.status),
      planned_action: action,
      dry_run_comment_exists: landing_plan_comment_exists?(issue),
      plan_id: plan_id,
      sort_key: {
        snapshot.repository,
        priority_rank(issue.priority),
        created_at_sort_key(issue),
        issue.identifier || issue.id || ""
      },
      snapshot: snapshot
    }
  end

  defp queue_entry(issue, plan_id, _settings, _pr_lookup) do
    %{
      issue: issue,
      issue_id: nil,
      issue_identifier: nil,
      title: nil,
      state: nil,
      project: nil,
      repository: "unknown",
      pr_url: "unknown",
      pr_state: "unknown",
      draft: "unknown",
      mergeability: "unknown",
      review_decision: "unknown",
      head_branch: "unknown",
      blocker: "invalid issue payload",
      status: "blocked",
      planned_action: "skip",
      dry_run_comment_exists: false,
      plan_id: plan_id,
      sort_key: {"unknown", priority_rank(nil), created_at_sort_key(nil), ""},
      snapshot: blocked_snapshot("unknown", "invalid issue payload")
    }
  end

  defp queue_payload(entry) do
    Map.take(entry, [
      :issue_id,
      :issue_identifier,
      :title,
      :state,
      :project,
      :repository,
      :pr_url,
      :pr_state,
      :draft,
      :mergeability,
      :review_decision,
      :head_branch,
      :head_sha,
      :blocker,
      :status,
      :planned_action,
      :dry_run_comment_exists,
      :plan_id,
      :queue_position,
      :queue_total
    ])
  end

  defp maybe_comment_plan(%{issue: %Issue{} = issue} = entry, settings, tracker, result) do
    cond do
      landing_plan_comment_exists?(issue) ->
        %{result | skipped: result.skipped + 1}

      not valid_issue_id?(issue.id) ->
        Logger.warning("Skipping Approved to Land dry-run plan; issue has no id identifier=#{inspect(issue.identifier)}")
        %{result | errors: result.errors + 1}

      true ->
        comment_plan(entry, settings, tracker, result)
    end
  end

  defp maybe_comment_plan(_entry, _settings, _tracker, result) do
    %{result | skipped: result.skipped + 1}
  end

  defp comment_plan(%{issue: %Issue{} = issue} = entry, settings, tracker, result) do
    body =
      plan_comment(
        issue,
        entry.queue_position,
        entry.queue_total,
        entry.plan_id,
        entry.snapshot,
        settings
      )

    case tracker.create_comment(issue.id, body) do
      :ok ->
        Logger.info("Created Approved to Land dry-run plan for #{issue_context(issue)} plan_id=#{entry.plan_id}")
        %{result | commented: result.commented + 1}

      {:ok, _comment} ->
        Logger.info("Created Approved to Land dry-run plan for #{issue_context(issue)} plan_id=#{entry.plan_id}")
        %{result | commented: result.commented + 1}

      {:error, reason} ->
        Logger.warning("Failed to create Approved to Land dry-run plan for #{issue_context(issue)}: #{inspect(reason)}")
        %{result | errors: result.errors + 1}

      other ->
        Logger.warning("Unexpected Approved to Land dry-run comment result for #{issue_context(issue)}: #{inspect(other)}")
        %{result | errors: result.errors + 1}
    end
  end

  @spec plan_comment(Issue.t(), pos_integer(), pos_integer(), String.t(), map(), Config.Schema.t()) :: String.t()
  def plan_comment(%Issue{} = issue, index, total, plan_id, snapshot, settings) do
    action = if snapshot.status == :ready, do: "merge", else: "skip"

    """
    #{@marker} issue_id=#{issue.id} -->
    Symphony Approved to Land dry-run plan

    Plan id: #{plan_id}
    Issue: #{issue.identifier || issue.id}
    Queue position: #{index} of #{total}
    Planned action: #{action} (execution gated)

    Validation snapshot:
    - repository: #{snapshot.repository}
    - PR: #{snapshot.pr_url}
    - PR state: #{snapshot.pr_state}
    - draft: #{snapshot.draft}
    - mergeability: #{snapshot.mergeability}
    - review decision: #{snapshot.review_decision}
    - head branch: #{snapshot.head_branch}
    - head SHA: #{snapshot.head_sha}
    - blocker: #{snapshot.blocker}

    Ordering rule: repository/base grouping, then Linear priority and issue creation time.

    Execution is gated by landing.execute_enabled. When enabled, the landing worker can move this issue to #{settings.landing.in_progress_state} and merge only after revalidating this plan.
    """
    |> String.trim()
  end

  defp validation_snapshot(%Issue{} = issue, settings, pr_lookup) do
    with {:ok, %{slug: repo}} when is_binary(repo) and repo != "" <- RepositoryResolver.resolve(issue, settings),
         {:ok, pr} <- lookup_open_pr(repo, issue, pr_lookup) do
      pr_snapshot(repo, pr)
    else
      {:ok, other} ->
        blocked_snapshot("unknown", "repository resolver returned invalid result: #{inspect(other)}")

      {:error, reason} ->
        blocked_snapshot("unknown", inspect(reason))
    end
  end

  defp lookup_open_pr(repo, %Issue{} = issue, pr_lookup) do
    if function_exported?(pr_lookup, :lookup_open_issue_pull_request, 5) do
      pr_lookup.lookup_open_issue_pull_request(
        repo,
        issue.identifier,
        issue.url,
        issue.branch_name,
        issue.attachment_urls
      )
    else
      {:error, {:missing_github_pr_lookup, pr_lookup}}
    end
  end

  defp pr_snapshot(repo, %{} = pr) do
    state = pr_value(pr, "state", "unknown")
    draft = pr_value(pr, "isDraft", "unknown")
    mergeability = pr_value(pr, "mergeStateStatus", "unknown")
    review_decision = pr_value(pr, "reviewDecision", "unknown")
    blocker = pr_blocker(state, draft, mergeability, review_decision)

    %{
      status: if(blocker == "none", do: :ready, else: :blocked),
      repository: repo,
      pr_url: pr_value(pr, "url", "unknown"),
      pr_state: state,
      draft: format_pr_value(draft),
      mergeability: mergeability,
      review_decision: review_decision,
      head_branch: pr_value(pr, "headRefName", "unknown"),
      head_sha: pr_value(pr, "headRefOid", "unknown"),
      blocker: blocker
    }
  end

  defp pr_snapshot(repo, nil), do: blocked_snapshot(repo, "no open GitHub PR found")

  defp blocked_snapshot(repo, blocker) do
    %{
      status: :blocked,
      repository: repo,
      pr_url: "unknown",
      pr_state: "unknown",
      draft: "unknown",
      mergeability: "unknown",
      review_decision: "unknown",
      head_branch: "unknown",
      head_sha: "unknown",
      blocker: blocker
    }
  end

  defp pr_blocker(state, _draft, _mergeability, _review_decision) when state != "OPEN" do
    "PR is not open: #{state}"
  end

  defp pr_blocker(_state, true, _mergeability, _review_decision), do: "PR is draft"
  defp pr_blocker(_state, "true", _mergeability, _review_decision), do: "PR is draft"

  defp pr_blocker(_state, _draft, mergeability, _review_decision) when mergeability != "CLEAN" do
    "PR mergeability is #{mergeability}"
  end

  defp pr_blocker(_state, _draft, _mergeability, "CHANGES_REQUESTED") do
    "GitHub review decision is CHANGES_REQUESTED"
  end

  defp pr_blocker(_state, _draft, _mergeability, _review_decision), do: "none"

  defp landing_plan_comment_exists?(%Issue{comments: comments}) when is_list(comments) do
    Enum.any?(comments, fn
      %{"body" => body} when is_binary(body) -> String.contains?(body, @marker)
      %{body: body} when is_binary(body) -> String.contains?(body, @marker)
      _ -> false
    end)
  end

  defp landing_plan_comment_exists?(_issue), do: false

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp pr_value(pr, key, fallback) when is_map(pr) and is_binary(key) do
    Map.get(pr, key) || Map.get(pr, atom_key(key)) || fallback
  end

  defp format_pr_value(value) when is_binary(value), do: value
  defp format_pr_value(value), do: inspect(value)

  defp atom_key("url"), do: :url
  defp atom_key("state"), do: :state
  defp atom_key("isDraft"), do: :isDraft
  defp atom_key("mergeStateStatus"), do: :mergeStateStatus
  defp atom_key("reviewDecision"), do: :reviewDecision
  defp atom_key("headRefName"), do: :headRefName
  defp atom_key("headRefOid"), do: :headRefOid
  defp atom_key(_key), do: nil

  defp valid_issue_id?(id), do: is_binary(id) and String.trim(id) != ""

  defp issue_context(%Issue{} = issue), do: "issue_id=#{issue.id} issue_identifier=#{issue.identifier || "unknown"}"

  defp plan_id do
    "land-dry-run-" <>
      (DateTime.utc_now()
       |> DateTime.truncate(:second)
       |> DateTime.to_iso8601(:basic))
  end
end
