defmodule Mix.Tasks.Symphony.GithubIssueCloseBackfill do
  use Mix.Task

  alias SymphonyElixir.GitHubIssueCloseBackfill

  @shortdoc "Backfills GitHub source issue closes for Linear Done issues"
  @moduledoc """
  Detects Linear Done issues whose source GitHub issue is still open.

  The task is dry-run by default:

      mix symphony.github_issue_close_backfill --repo yakisoba666rasb-star/symphony

  Add `--execute` to close matching GitHub issues:

      mix symphony.github_issue_close_backfill --repo yakisoba666rasb-star/symphony --execute

  By default the task inspects Linear `Done` issues from the configured tracker
  scope. Use `--states Done,Completed` when a workspace uses different terminal
  state names. Use `--team-key LAB --all-projects` or `--project-slug <slug>`
  to backfill a scope explicitly instead of relying on the active workflow file.
  """

  @switches [
    repo: :string,
    execute: :boolean,
    states: :string,
    team_key: :string,
    project_slug: :string,
    all_projects: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = backfill_opts_for_args(args)

    case GitHubIssueCloseBackfill.run(opts) do
      {:ok, summary} ->
        Mix.shell().info(format_summary(summary, opts[:execute]))

        if summary.errors == [] do
          :ok
        else
          Mix.raise("GitHub issue close backfill completed with #{length(summary.errors)} error(s)")
        end

      {:error, reason} ->
        Mix.raise("GitHub issue close backfill failed: #{inspect(reason)}")
    end
  end

  @doc false
  @spec backfill_opts_for_args([String.t()]) :: keyword()
  def backfill_opts_for_args(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: @switches)

    if invalid != [] do
      Mix.raise("Invalid symphony.github_issue_close_backfill option(s): #{inspect(invalid)}")
    end

    repo =
      opts[:repo] ||
        Mix.raise("Missing required --repo owner/name")

    [
      repo: repo,
      execute: opts[:execute] == true,
      states: parse_states(opts[:states])
    ]
    |> maybe_put(:team_key, opts[:team_key])
    |> maybe_put(:project_slug, opts[:project_slug])
    |> maybe_put(:all_projects, opts[:all_projects])
  end

  @doc false
  @spec format_summary_for_test(GitHubIssueCloseBackfill.t(), boolean()) :: String.t()
  def format_summary_for_test(summary, execute?), do: format_summary(summary, execute?)

  defp parse_states(nil), do: ["Done"]

  defp parse_states(states) do
    states
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> Mix.raise("Invalid --states value; provide at least one state name")
      names -> names
    end
  end

  defp format_summary(summary, execute?) do
    mode = if execute?, do: "execute", else: "dry-run"

    lines = [
      "GitHub issue close backfill (#{mode})",
      "",
      "inspected: #{summary.inspected}",
      "candidates: #{summary.candidates}",
      "closed: #{summary.closed}",
      "already_closed: #{summary.already_closed}",
      "not_applicable: #{summary.not_applicable}",
      "skipped: #{summary.skipped}",
      "errors: #{length(summary.errors)}"
    ]

    action_lines =
      summary.actions
      |> Enum.map(fn action ->
        "- #{action.status} #{action.issue || "unknown"} #{action.url}"
      end)

    error_lines =
      summary.errors
      |> Enum.map(fn error ->
        "- error #{error.issue || "unknown"} #{error.url}: #{inspect(error.reason)}"
      end)

    [lines, maybe_section("Actions", action_lines), maybe_section("Errors", error_lines)]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp maybe_section(_title, []), do: []

  defp maybe_section(title, lines) do
    ["", title | lines]
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
