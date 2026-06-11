defmodule SymphonyElixir.AcceptanceRunner do
  @moduledoc "Runs a live zero-touch acceptance probe and emits a markdown report."

  require Logger

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Linear.Issue

  @type leg :: :linear_created | :todo | :in_progress | :pr_exists | :in_review | :done

  @type result :: %{
          nonce: String.t(),
          repo: String.t(),
          source_issue_url: String.t() | nil,
          legs: %{optional(leg()) => DateTime.t()},
          status: :passed | :failed,
          failed_leg: leg() | nil,
          report: String.t()
        }

  @type command_result ::
          {String.t(), integer()} | {:ok, {String.t(), integer()}} | {:error, term()}

  @type deps :: %{
          required(:find_gh_bin) => (-> String.t() | nil),
          required(:run_command) => (String.t(), [String.t()], keyword() -> command_result()),
          required(:fetch_issues_by_states) => ([String.t()] -> {:ok, [Issue.t()]} | {:error, term()})
        }

  @spec run(keyword(), deps()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ [], deps \\ runtime_deps()) do
    settings = Config.settings!()
    nonce = Keyword.get(opts, :nonce, default_nonce())
    repo = Keyword.get(opts, :repo) || settings.repository.default
    label = Keyword.get(opts, :label) || List.first(settings.github_intake.todo_labels || [])

    with {:ok, repo} <- require_repo(repo),
         {:ok, label} <- require_label(label),
         {:ok, source_issue_url} <- create_source_issue(repo, label, nonce, deps) do
      do_run(nonce, repo, source_issue_url, opts, deps)
    end
  end

  @spec markdown_report(result()) :: String.t()
  def markdown_report(%{} = result) do
    legs = [:linear_created, :todo, :in_progress, :pr_exists, :in_review, :done]

    leg_rows =
      Enum.map_join(legs, "\n", fn leg ->
        timestamp =
          result.legs
          |> Map.get(leg)
          |> format_timestamp()

        "- #{leg}: #{timestamp}"
      end)

    """
    # Symphony Acceptance Report

    Status: #{result.status}
    Nonce: #{result.nonce}
    Repository: #{result.repo}
    Source issue: #{result.source_issue_url || "unknown"}
    Failed leg: #{result.failed_leg || "none"}

    ## Legs
    #{leg_rows}
    """
    |> String.trim()
  end

  defp do_run(nonce, repo, source_issue_url, opts, deps) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 900_000)
    poll_ms = Keyword.get(opts, :poll_ms, 5_000)
    up_to = Keyword.get(opts, :up_to, :done)
    restart_during_review? = Keyword.get(opts, :restart_during_review, false)
    restart_command = Keyword.get(opts, :restart_command, "systemctl restart symphony-engine.service")

    initial = %{
      nonce: nonce,
      repo: repo,
      source_issue_url: source_issue_url,
      legs: %{},
      status: :failed,
      failed_leg: nil,
      report: ""
    }

    target_legs(up_to)
    |> Enum.reduce_while({:ok, initial}, fn leg, {:ok, result} ->
      case wait_for_leg(leg, result, timeout_ms, poll_ms, deps) do
        {:ok, result} ->
          maybe_restart_during_review(leg, restart_during_review?, restart_command, deps)
          {:cont, {:ok, result}}

        {:error, reason} ->
          {:halt, {:error, Map.merge(result, %{failed_leg: leg, failure: reason})}}
      end
    end)
    |> finalize_acceptance_result()
  end

  defp wait_for_leg(leg, result, timeout_ms, poll_ms, deps) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_leg(leg, result, deadline_ms, poll_ms, deps)
  end

  defp do_wait_for_leg(leg, result, deadline_ms, poll_ms, deps) do
    case fetch_acceptance_issue(result.nonce, result.source_issue_url, deps) do
      {:ok, %Issue{} = issue} ->
        if leg_reached?(leg, issue) do
          {:ok, put_in(result.legs[leg], DateTime.utc_now())}
        else
          continue_waiting_for_leg(leg, result, deadline_ms, poll_ms, deps)
        end

      {:ok, nil} ->
        continue_waiting_for_leg(leg, result, deadline_ms, poll_ms, deps)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_waiting_for_leg(leg, result, deadline_ms, poll_ms, deps) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      {:error, :timeout}
    else
      Process.sleep(poll_ms)
      do_wait_for_leg(leg, result, deadline_ms, poll_ms, deps)
    end
  end

  defp fetch_acceptance_issue(nonce, source_issue_url, deps) do
    case deps.fetch_issues_by_states.(fetch_states()) do
      {:ok, issues} when is_list(issues) ->
        {:ok, Enum.find(issues, &acceptance_issue?(&1, nonce, source_issue_url))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp acceptance_issue?(%Issue{} = issue, nonce, source_issue_url) do
    issue_text = Enum.join([issue.identifier, issue.title, issue.description, issue.url], "\n")

    String.contains?(issue_text, nonce) or
      Enum.any?(issue_attachment_urls(issue), &(&1 == source_issue_url))
  end

  defp leg_reached?(:linear_created, %Issue{}), do: true
  defp leg_reached?(:todo, %Issue{state: state}), do: normalize_state(state) == "todo"
  defp leg_reached?(:in_progress, %Issue{state: state}), do: normalize_state(state) == "in progress"
  defp leg_reached?(:pr_exists, %Issue{} = issue), do: Enum.any?(issue_attachment_urls(issue), &pull_request_url?/1)
  defp leg_reached?(:in_review, %Issue{state: state}), do: normalize_state(state) == normalize_state(Config.review_handoff_state())
  defp leg_reached?(:done, %Issue{state: state}), do: normalize_state(state) == "done"

  defp target_legs(:in_review), do: [:linear_created, :todo, :in_progress, :pr_exists, :in_review]
  defp target_legs("in_review"), do: target_legs(:in_review)
  defp target_legs(_up_to), do: [:linear_created, :todo, :in_progress, :pr_exists, :in_review, :done]

  defp maybe_restart_during_review(:pr_exists, true, command, deps) do
    [cmd | args] = String.split(command, " ", trim: true)

    case normalize_command_result(deps.run_command.(cmd, args, stderr_to_stdout: true)) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {output, status}} -> Logger.warning("Acceptance restart command exited #{status}: #{String.trim(output)}")
      {:error, reason} -> Logger.warning("Acceptance restart command failed: #{inspect(reason)}")
    end
  end

  defp maybe_restart_during_review(_leg, _restart?, _command, _deps), do: :ok

  defp finalize_acceptance_result({:ok, result}) do
    result = %{result | status: :passed, report: markdown_report(%{result | status: :passed})}
    {:ok, result}
  end

  defp finalize_acceptance_result({:error, result}) when is_map(result) do
    result = %{result | status: :failed, report: markdown_report(%{result | status: :failed})}
    {:ok, result}
  end

  defp create_source_issue(repo, label, nonce, deps) do
    with {:ok, gh_bin} <- find_gh_binary(deps) do
      title = "Symphony acceptance #{nonce}"

      body = """
      Symphony acceptance probe.

      Nonce: #{nonce}
      """

      args = ["issue", "create", "--repo", repo, "--title", title, "--body", body, "--label", label]

      case normalize_command_result(deps.run_command.(gh_bin, args, stderr_to_stdout: true)) do
        {:ok, {output, 0}} -> {:ok, output |> String.trim() |> String.split("\n") |> List.last()}
        {:ok, {output, status}} -> {:error, {:gh_issue_create_failed, status, String.trim(output)}}
        {:error, reason} -> {:error, {:gh_issue_create_failed, reason}}
      end
    end
  end

  defp runtime_deps do
    %{
      find_gh_bin: fn -> System.find_executable("gh") end,
      run_command: &run_system_cmd/3,
      fetch_issues_by_states: &Tracker.fetch_issues_by_states/1
    }
  end

  defp run_system_cmd(cmd, args, opts) do
    {:ok, System.cmd(cmd, args, opts)}
  end

  defp find_gh_binary(deps) do
    case deps.find_gh_bin.() do
      nil -> {:error, :gh_not_found}
      gh -> {:ok, gh}
    end
  end

  defp require_repo(repo) when is_binary(repo) do
    case String.trim(repo) do
      "" -> {:error, :repository_required}
      repo -> {:ok, repo}
    end
  end

  defp require_repo(_repo), do: {:error, :repository_required}

  defp require_label(label) when is_binary(label) do
    case String.trim(label) do
      "" -> {:error, :todo_label_required}
      label -> {:ok, label}
    end
  end

  defp require_label(_label), do: {:error, :todo_label_required}

  defp fetch_states do
    settings = Config.settings!()

    ([settings.github_intake.state, settings.tracker.review_state] ++
       settings.tracker.active_states ++ settings.tracker.terminal_states)
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or &1 == "nil"))
    |> Enum.uniq()
  end

  defp normalize_command_result({output, status}) when is_binary(output) and is_integer(status),
    do: {:ok, {output, status}}

  defp normalize_command_result(result), do: result

  defp issue_attachment_urls(%Issue{attachment_urls: urls}) when is_list(urls), do: urls
  defp issue_attachment_urls(_issue), do: []

  defp pull_request_url?(url) when is_binary(url) do
    Regex.match?(~r{^https://github\.com/[^/]+/[^/]+/pull/\d+(?:[/?#].*)?$}i, String.trim(url))
  end

  defp pull_request_url?(_url), do: false

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""

  defp default_nonce do
    "acceptance-#{System.system_time(:second)}-#{System.unique_integer([:positive])}"
  end

  defp format_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp format_timestamp(_timestamp), do: "pending"
end
