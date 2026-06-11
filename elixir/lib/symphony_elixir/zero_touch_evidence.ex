defmodule SymphonyElixir.ZeroTouchEvidence do
  @moduledoc "Builds and posts zero-touch loop evidence comments for GitHub-intake issues."

  require Logger

  alias SymphonyElixir.Linear.Issue

  @marker "<!-- symphony:zero-touch-loop-evidence:v1 -->"
  @timeline_keys [
    :intake_at,
    :dispatched_at,
    :pr_created_at,
    :in_review_at,
    :merged_at,
    :done_at,
    :source_closed_at
  ]

  @spec marker() :: String.t()
  def marker, do: @marker

  @spec maybe_post_after_done(Issue.t(), String.t(), map(), module(), module()) :: :ok | {:error, term()}
  def maybe_post_after_done(%Issue{} = issue, repo, pr, tracker, github_issue)
      when is_binary(repo) and is_map(pr) and is_atom(tracker) and is_atom(github_issue) do
    with :ok <- ensure_tracker_support(tracker),
         {:ok, evidence} <- tracker.fetch_zero_touch_evidence(issue.id),
         true <- intake_origin?(evidence),
         false <- evidence_comment_exists?(evidence),
         source_issue_url <- source_issue_url(evidence),
         source_closed_at <- source_closed_at(github_issue, repo, source_issue_url),
         comment <- compose_comment(issue, evidence, pr, source_issue_url, source_closed_at),
         :ok <- tracker.create_comment(issue.id, comment) do
      :ok
    else
      false ->
        :ok

      true ->
        :ok

      {:error, {:unsupported_tracker_adapter, _adapter}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Skipping zero-touch loop evidence for #{issue_label(issue)}: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.warning("Skipping zero-touch loop evidence for #{issue_label(issue)}: #{inspect(other)}")
        {:error, other}
    end
  rescue
    exception ->
      Logger.warning("Skipping zero-touch loop evidence for #{issue_label(issue)}: #{Exception.message(exception)}")
      {:error, {:exception, Exception.message(exception)}}
  end

  def maybe_post_after_done(_issue, _repo, _pr, _tracker, _github_issue), do: :ok

  @spec intake_origin?(map()) :: boolean()
  def intake_origin?(%{} = evidence) do
    evidence
    |> attachments()
    |> Enum.any?(&github_issue_attachment?/1)
  end

  @spec evidence_comment_exists?(map()) :: boolean()
  def evidence_comment_exists?(%{} = evidence) do
    evidence
    |> comments()
    |> Enum.any?(fn comment ->
      comment
      |> value("body")
      |> case do
        body when is_binary(body) -> String.contains?(body, @marker)
        _ -> false
      end
    end)
  end

  @spec compose_comment(Issue.t(), map(), map(), String.t() | nil, String.t() | nil) :: String.t()
  def compose_comment(%Issue{} = issue, evidence, pr, source_issue_url, source_closed_at)
      when is_map(evidence) and is_map(pr) do
    timeline = timeline(evidence, pr, source_closed_at)

    """
    #{@marker}
    Zero-touch loop evidence

    Issue: #{issue.identifier || issue.id || "unknown"}
    Source GitHub issue: #{format_value(source_issue_url)}
    Pull request: #{format_value(pr_url(pr))}

    Timeline:
    #{format_timeline(timeline)}
    """
    |> String.trim()
  end

  @spec source_issue_url(map()) :: String.t() | nil
  def source_issue_url(%{} = evidence) do
    evidence
    |> attachments()
    |> Enum.find_value(fn attachment ->
      url = value(attachment, "url")

      if github_issue_url?(url), do: String.trim(url)
    end)
  end

  defp ensure_tracker_support(tracker) do
    if Code.ensure_loaded?(tracker) and
         function_exported?(tracker, :fetch_zero_touch_evidence, 1) and
         function_exported?(tracker, :create_comment, 2) do
      :ok
    else
      {:error, {:unsupported_tracker_adapter, tracker}}
    end
  end

  defp source_closed_at(github_issue, repo, source_issue_url) do
    if Code.ensure_loaded?(github_issue) and function_exported?(github_issue, :closed_at, 2) do
      case github_issue.closed_at(repo, source_issue_url) do
        {:ok, closed_at} -> closed_at
        {:error, reason} -> log_partial(:source_closed_at, reason)
        _other -> nil
      end
    end
  end

  defp timeline(evidence, pr, source_closed_at) do
    %{
      intake_at: intake_at(evidence),
      dispatched_at: first_transition_at(evidence, ["In Progress"]),
      pr_created_at: pr_timestamp(pr, "createdAt"),
      in_review_at: first_transition_at(evidence, ["In Review"]),
      merged_at: pr_timestamp(pr, "mergedAt"),
      done_at: first_transition_at(evidence, ["Done"]),
      source_closed_at: source_closed_at
    }
  end

  defp intake_at(evidence) do
    evidence
    |> attachments()
    |> Enum.filter(&github_issue_attachment?/1)
    |> Enum.map(&value(&1, "createdAt"))
    |> Enum.find(&present?/1)
  end

  defp first_transition_at(evidence, state_names) do
    evidence
    |> history()
    |> Enum.find_value(fn event ->
      if value_in?(event, "toState", "name", state_names) do
        value(event, "createdAt")
      end
    end)
  end

  defp format_timeline(timeline) do
    Enum.map_join(@timeline_keys, "\n", fn key -> "- #{key}: #{format_value(Map.get(timeline, key))}" end)
  end

  defp attachments(%{attachments: attachments}) when is_list(attachments), do: attachments
  defp attachments(%{"attachments" => attachments}) when is_list(attachments), do: attachments
  defp attachments(%{issue: issue}) when is_map(issue), do: relation_nodes(issue, "attachments")
  defp attachments(%{"issue" => issue}) when is_map(issue), do: relation_nodes(issue, "attachments")
  defp attachments(_evidence), do: []

  defp history(%{history: history}) when is_list(history), do: history
  defp history(%{"history" => history}) when is_list(history), do: history
  defp history(%{issue: issue}) when is_map(issue), do: relation_nodes(issue, "history")
  defp history(%{"issue" => issue}) when is_map(issue), do: relation_nodes(issue, "history")
  defp history(_evidence), do: []

  defp comments(%{comments: comments}) when is_list(comments), do: comments
  defp comments(%{"comments" => comments}) when is_list(comments), do: comments
  defp comments(%{issue: issue}) when is_map(issue), do: relation_nodes(issue, "comments")
  defp comments(%{"issue" => issue}) when is_map(issue), do: relation_nodes(issue, "comments")
  defp comments(_evidence), do: []

  defp relation_nodes(container, key) do
    case value(container, key) do
      %{"nodes" => nodes} when is_list(nodes) -> nodes
      %{nodes: nodes} when is_list(nodes) -> nodes
      nodes when is_list(nodes) -> nodes
      _ -> []
    end
  end

  defp github_issue_attachment?(attachment) when is_map(attachment) do
    github_issue_url?(value(attachment, "url"))
  end

  defp github_issue_attachment?(_attachment), do: false

  defp github_issue_url?(url) when is_binary(url) do
    Regex.match?(~r{^https://github\.com/[^/]+/[^/]+/issues/\d+(?:[/?#].*)?$}i, String.trim(url))
  end

  defp github_issue_url?(_url), do: false

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp value(_map, _key), do: nil

  defp value_in?(map, outer_key, inner_key, expected_values) do
    map
    |> value(outer_key)
    |> value(inner_key)
    |> case do
      value when is_binary(value) -> value in expected_values
      _ -> false
    end
  end

  defp pr_timestamp(pr, key), do: value(pr, key)

  defp pr_url(pr), do: value(pr, "url")

  defp format_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp format_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "n/a"
      text -> text
    end
  end

  defp format_value(_value), do: "n/a"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp issue_label(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_label(%Issue{id: id}) when is_binary(id), do: id
  defp issue_label(_issue), do: "issue"

  defp log_partial(field, reason) do
    Logger.warning("Zero-touch loop evidence missing #{field}: #{inspect(reason)}")
    nil
  end
end
