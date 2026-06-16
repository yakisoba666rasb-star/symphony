defmodule SymphonyElixir.ReviewRunner do
  @moduledoc """
  Runs the official-style implementer/reviewer/rework loop before human review.

  The runtime owns loop boundaries only: a separate reviewer turn emits a
  structured verdict, and blocking findings are sent back to an implementer
  rework turn until the existing PR is approve-equivalent or the configured
  loop limit is reached. The implementer remains responsible for pushing PR
  branch updates.
  """

  require Logger

  alias SymphonyElixir.{Codex.AppServer, Config}
  alias SymphonyElixir.Linear.Issue

  @verdict_file_prefix ".symphony-review-verdict"

  @type verdict :: %{
          approved_equivalent: boolean(),
          blocking_findings: [String.t()],
          tests_required: [String.t()],
          residual_risk: String.t()
        }

  @spec run_loop(Path.t(), Issue.t() | map(), map(), keyword()) ::
          {:ok, verdict()} | {:error, term()}
  def run_loop(workspace_path, issue, pr, opts \\ [])
      when is_binary(workspace_path) and is_map(pr) do
    max_loops = Keyword.get(opts, :max_review_fix_loops, Config.max_review_fix_loops())
    do_run_loop(workspace_path, issue, pr, 0, max_loops, opts)
  end

  defp do_run_loop(workspace_path, issue, pr, loop_index, max_loops, opts) do
    case run_reviewer_turn(workspace_path, issue, pr, loop_index, opts) do
      {:ok, verdict} -> continue_or_finish_review(workspace_path, issue, pr, verdict, loop_index, max_loops, opts)
      {:error, _reason} = error -> error
    end
  end

  defp continue_or_finish_review(workspace_path, issue, pr, verdict, loop_index, max_loops, opts) do
    cond do
      verdict.approved_equivalent ->
        {:ok, verdict}

      loop_index >= max_loops ->
        {:error, {:max_review_fix_loops_reached, max_loops, verdict}}

      true ->
        Logger.info("Reviewer requested rework for #{issue_identifier(issue)} loop=#{loop_index + 1}/#{max_loops}")
        continue_rework_loop(workspace_path, issue, pr, verdict, loop_index, max_loops, opts)
    end
  end

  defp continue_rework_loop(workspace_path, issue, pr, verdict, loop_index, max_loops, opts) do
    with :ok <- run_rework_turn(workspace_path, issue, pr, verdict, loop_index + 1, opts) do
      do_run_loop(workspace_path, issue, pr, loop_index + 1, max_loops, opts)
    end
  end

  defp run_reviewer_turn(workspace_path, issue, pr, loop_index, opts) do
    verdict_path = verdict_path(workspace_path, loop_index, opts)

    with :ok <- remove_existing_verdict_file(verdict_path) do
      prompt = reviewer_prompt(issue, pr, loop_index, verdict_path)

      result =
        case run_codex_turn(workspace_path, prompt, issue, :reviewer, opts) do
          :ok -> read_verdict(verdict_path)
          {:error, _reason} = error -> error
        end

      case remove_verdict_file(verdict_path) do
        :ok -> result
        {:error, _reason} = error -> error
      end
    end
  end

  defp run_rework_turn(workspace_path, issue, pr, verdict, loop_number, opts) do
    prompt = rework_prompt(issue, pr, verdict, loop_number)
    run_codex_turn(workspace_path, prompt, issue, :implementer, opts)
  end

  defp run_codex_turn(workspace_path, prompt, issue, role, opts) do
    app_server = Keyword.get(opts, :app_server_module, app_server_module())

    turn_opts =
      opts
      |> Keyword.drop([
        :app_server_module,
        :max_review_fix_loops,
        :implementer_codex_command,
        :reviewer_codex_command
      ])
      |> Keyword.merge(role_codex_options(role, opts))

    case app_server.start_session(workspace_path, turn_opts) do
      {:ok, session} ->
        try do
          case app_server.run_turn(session, prompt, issue, turn_opts) do
            {:ok, _result} -> :ok
            {:error, reason} -> {:error, {:codex_turn_failed, reason}}
          end
        after
          app_server.stop_session(session)
        end

      {:error, reason} ->
        {:error, {:codex_session_failed, reason}}
    end
  end

  defp app_server_module do
    Application.get_env(:symphony_elixir, :codex_app_server, AppServer)
  end

  defp role_codex_options(:implementer, opts) do
    case Keyword.get(opts, :implementer_codex_command) do
      command when is_binary(command) -> [codex_command: command]
      _ -> Config.review_role_codex_options(:implementer)
    end
  end

  defp role_codex_options(:reviewer, opts) do
    case Keyword.get(opts, :reviewer_codex_command) do
      command when is_binary(command) -> [codex_command: command]
      _ -> Config.review_role_codex_options(:reviewer)
    end
  end

  defp read_verdict(verdict_path) do
    with {:ok, raw_json} <- File.read(verdict_path),
         {:ok, decoded} <- Jason.decode(raw_json) do
      normalize_verdict(decoded)
    else
      {:error, :enoent} -> {:error, {:review_verdict_missing, verdict_path}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_review_verdict_json, Exception.message(error)}}
      {:error, reason} -> {:error, {:review_verdict_read_failed, reason}}
    end
  end

  defp remove_verdict_file(verdict_path) do
    case File.rm(verdict_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:review_verdict_cleanup_failed, reason}}
    end
  end

  defp remove_existing_verdict_file(verdict_path) do
    case File.rm(verdict_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:review_verdict_initial_cleanup_failed, reason}}
    end
  end

  defp normalize_verdict(%{} = raw) do
    approved = Map.get(raw, "approved_equivalent")

    if is_boolean(approved) do
      {:ok,
       %{
         approved_equivalent: approved,
         blocking_findings: string_list(Map.get(raw, "blocking_findings")),
         tests_required: string_list(Map.get(raw, "tests_required")),
         residual_risk: string_value(Map.get(raw, "residual_risk"))
       }}
    else
      {:error, {:invalid_review_verdict, :approved_equivalent_required}}
    end
  end

  defp normalize_verdict(_raw), do: {:error, {:invalid_review_verdict, :map_required}}

  defp string_list(values) when is_list(values), do: values |> Enum.map(&string_value/1) |> Enum.reject(&(&1 == ""))
  defp string_list(nil), do: []
  defp string_list(value), do: [string_value(value)]

  defp string_value(nil), do: ""
  defp string_value(%{} = value), do: finding_map_to_string(value)
  defp string_value(value), do: to_string(value)

  defp finding_map_to_string(value) do
    summary =
      [finding_location(value), finding_issue(value)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" - ")

    if summary == "", do: inspect(value), else: summary
  end

  defp finding_location(value) do
    file = string_value(Map.get(value, "file") || Map.get(value, :file))
    line = string_value(Map.get(value, "line") || Map.get(value, :line))

    cond do
      file != "" and line != "" -> "#{file}:#{line}"
      file != "" -> file
      true -> ""
    end
  end

  defp finding_issue(value) do
    string_value(
      Map.get(value, "issue") ||
        Map.get(value, :issue) ||
        Map.get(value, "message") ||
        Map.get(value, :message)
    )
  end

  defp verdict_path(workspace_path, loop_index, opts) do
    case Keyword.get(opts, :review_verdict_path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        Path.join(
          workspace_path,
          "#{@verdict_file_prefix}-#{Path.basename(workspace_path)}-#{loop_index}-#{System.unique_integer([:positive])}.json"
        )
    end
  end

  defp reviewer_prompt(issue, pr, loop_index, verdict_path) do
    """
    You are the independent reviewer in the Symphony runtime loop.

    Review the current workspace and draft PR before it can move to human final review.

    Linear issue:
    - Identifier: #{issue_identifier(issue)}
    - Title: #{issue_title(issue)}

    Draft PR:
    - URL: #{pr_url(pr)}
    - Number: #{pr_number(pr)}

    Rules:
    - Do not merge.
    - Do not approve on GitHub.
    - Inspect the diff and run focused validation where practical.
    - If there are blocking correctness, safety, CI, or spec issues, set approved_equivalent to false.
    - If the PR is ready for human final review, set approved_equivalent to true.
    - Write the verdict JSON to #{verdict_path}. Do not put the verdict anywhere else.

    Required JSON shape:
    {
      "approved_equivalent": true,
      "blocking_findings": [],
      "tests_required": [],
      "residual_risk": ""
    }

    Review loop index: #{loop_index}
    """
  end

  defp rework_prompt(issue, pr, verdict, loop_number) do
    """
    You are the implementer in the Symphony rework loop.

    The reviewer found blocking issues. Fix them in the current workspace and keep the existing PR branch.

    Linear issue:
    - Identifier: #{issue_identifier(issue)}
    - Title: #{issue_title(issue)}

    Draft PR:
    - URL: #{pr_url(pr)}
    - Number: #{pr_number(pr)}

    Blocking findings:
    #{bullet_list(verdict.blocking_findings)}

    Required validation or follow-up:
    #{bullet_list(verdict.tests_required)}

    Residual risk noted by reviewer:
    #{blank_to_none(verdict.residual_risk)}

    Rules:
    - Do not merge.
    - Do not move the Linear issue to human review yourself.
    - Keep changes scoped to the issue and reviewer findings.
    - Push any required branch updates yourself; the runtime will reuse the existing PR for the next review.

    Rework loop: #{loop_number}
    """
  end

  defp bullet_list([]), do: "- none"
  defp bullet_list(items), do: Enum.map_join(items, "\n", &("- " <> &1))

  defp blank_to_none(""), do: "none"
  defp blank_to_none(value), do: value

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: "issue"

  defp issue_title(%Issue{title: title}) when is_binary(title) and title != "", do: title
  defp issue_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp issue_title(_issue), do: "Automated changes"

  defp pr_url(%{"url" => url}) when is_binary(url), do: url
  defp pr_url(%{url: url}) when is_binary(url), do: url
  defp pr_url(_pr), do: "unknown"

  defp pr_number(%{"number" => number}), do: number
  defp pr_number(%{number: number}), do: number
  defp pr_number(_pr), do: "unknown"
end
