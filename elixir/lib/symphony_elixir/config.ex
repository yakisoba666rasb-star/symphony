defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @current_codex_model "gpt-5.5"
  @retired_codex_models ["gpt-5.3-codex-spark"]

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec current_codex_model() :: String.t()
  def current_codex_model, do: @current_codex_model

  @spec retired_codex_models() :: [String.t()]
  def retired_codex_models, do: @retired_codex_models

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec review_handoff_state() :: String.t()
  def review_handoff_state do
    settings = settings!()
    settings.review.handoff_state || settings.tracker.review_state
  end

  @spec max_review_fix_loops() :: non_neg_integer()
  def max_review_fix_loops do
    settings = settings!()
    settings.review.max_review_fix_loops || settings.agent.max_review_fix_loops
  end

  @spec blocked_issue_comment(String.t(), String.t()) :: String.t()
  def blocked_issue_comment(identifier, reason) do
    settings!().review.blocked_comment_template
    |> blank_to_nil()
    |> case do
      nil -> "Symphony blocked {{ identifier }}.\n\nReason: {{ reason }}"
      template -> template
    end
    |> String.replace("{{ identifier }}", to_string(identifier))
    |> String.replace("{{ reason }}", to_string(reason))
  end

  @spec review_role_codex_options(:implementer | :reviewer) :: keyword()
  def review_role_codex_options(role) when role in [:implementer, :reviewer] do
    settings = settings!()
    review = settings.review

    case review_role_command(review, role) || review_role_generated_command(review, role) do
      nil -> []
      command -> [codex_command: command]
    end
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      retired_model_message(settings) ->
        {:error, {:retired_codex_model, retired_model_message(settings)}}

      true ->
        :ok
    end
  end

  defp retired_model_message(settings) do
    settings
    |> retired_model_fields()
    |> Enum.flat_map(fn {field, value} -> retired_model_matches(field, value) end)
    |> case do
      [] ->
        nil

      matches ->
        details =
          matches
          |> Enum.map(fn {field, model} -> "#{field}=#{model}" end)
          |> Enum.join(", ")

        "Retired Codex model reference found. Use #{current_codex_model()} instead of: #{details}"
    end
  end

  defp retired_model_fields(settings) do
    [
      {"codex.command", settings.codex.command},
      {"review.implementer_command", settings.review.implementer_command},
      {"review.reviewer_command", settings.review.reviewer_command},
      {"review.implementer_model", settings.review.implementer_model},
      {"review.reviewer_model", settings.review.reviewer_model}
    ]
  end

  defp retired_model_matches(field, value) when is_binary(value) do
    @retired_codex_models
    |> Enum.filter(&String.contains?(value, &1))
    |> Enum.map(fn retired_model -> {field, retired_model} end)
  end

  defp retired_model_matches(_field, _value), do: []

  defp review_role_command(review, :implementer), do: blank_to_nil(review.implementer_command)
  defp review_role_command(review, :reviewer), do: blank_to_nil(review.reviewer_command)

  defp review_role_generated_command(review, role) do
    model = review_role_model(review, role)
    profile = review_role_profile(review, role)

    if is_nil(model) and is_nil(profile) do
      nil
    else
      [
        "codex",
        model_config_arg(model),
        profile_arg(profile),
        "app-server"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end
  end

  defp review_role_model(review, :implementer), do: blank_to_nil(review.implementer_model)
  defp review_role_model(review, :reviewer), do: blank_to_nil(review.reviewer_model)

  defp review_role_profile(review, :implementer), do: blank_to_nil(review.implementer_profile)
  defp review_role_profile(review, :reviewer), do: blank_to_nil(review.reviewer_profile)

  defp model_config_arg(nil), do: nil
  defp model_config_arg(model), do: "--config " <> shell_single_quote("model=" <> inspect(model))

  defp profile_arg(nil), do: nil
  defp profile_arg(profile), do: "--profile " <> shell_single_quote(profile)

  defp shell_single_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
