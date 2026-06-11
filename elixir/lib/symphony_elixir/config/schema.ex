defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:team_key, :string)
      field(:project_slug, :string)
      field(:all_projects, :boolean, default: false)
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
      field(:review_state, :string, default: "In Review")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :team_key,
          :project_slug,
          :all_projects,
          :assignee,
          :active_states,
          :terminal_states,
          :review_state
        ],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule GitHubIntake do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:state, :string, default: "Backlog")
      field(:todo_labels, {:array, :string}, default: [])
      field(:interval_ms, :integer, default: 300_000)
      field(:retry_ttl_ms, :integer, default: 3_600_000)
      field(:limit, :integer, default: 100)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :state, :todo_labels, :interval_ms, :retry_ttl_ms, :limit], empty_values: [])
      |> validate_required([:state])
      |> validate_number(:interval_ms, greater_than: 0)
      |> validate_number(:retry_ttl_ms, greater_than: 0)
      |> validate_number(:limit, greater_than: 0, less_than_or_equal_to: 500)
      |> validate_change(:state, &validate_non_blank/2)
      |> validate_change(:todo_labels, &validate_label_names/2)
      |> validate_retry_ttl_ms()
    end

    defp validate_non_blank(field, value) when is_binary(value) do
      if String.trim(value) == "", do: [{field, "must not be blank"}], else: []
    end

    defp validate_non_blank(field, _value), do: [{field, "must not be blank"}]

    defp validate_label_names(field, labels) when is_list(labels) do
      if Enum.all?(labels, &(is_binary(&1) and String.trim(&1) != "")) do
        []
      else
        [{field, "must contain only non-blank strings"}]
      end
    end

    defp validate_retry_ttl_ms(changeset) do
      interval_ms = get_field(changeset, :interval_ms)
      retry_ttl_ms = get_field(changeset, :retry_ttl_ms)

      if is_integer(interval_ms) and is_integer(retry_ttl_ms) and retry_ttl_ms < interval_ms do
        add_error(changeset, :retry_ttl_ms, "must be greater than or equal to interval_ms")
      else
        changeset
      end
    end
  end

  defmodule DoneSync do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 120_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Stall do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:threshold_ms, :integer, default: 900_000)
      field(:review_threshold_ms, :integer, default: 900_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :threshold_ms, :review_threshold_ms], empty_values: [])
      |> validate_number(:threshold_ms, greater_than: 0)
      |> validate_number(:review_threshold_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
      field(:dirty_workspace_retention_days, :integer, default: 7)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root, :dirty_workspace_retention_days], empty_values: [])
      |> validate_number(:dirty_workspace_retention_days, greater_than_or_equal_to: 0)
    end
  end

  defmodule Repository do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:default, :string)
      field(:clone_protocol, :string, default: "https")
      field(:project_routes, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:default, :clone_protocol, :project_routes], empty_values: [])
      |> validate_change(:default, &validate_optional_repository_slug/2)
      |> validate_change(:project_routes, &validate_project_routes/2)
      |> validate_inclusion(:clone_protocol, ["https", "ssh"])
    end

    defp validate_optional_repository_slug(_field, nil), do: []
    defp validate_optional_repository_slug(_field, ""), do: []

    defp validate_optional_repository_slug(field, value) when is_binary(value) do
      if valid_repository_slug?(value) do
        []
      else
        [{field, "must be a GitHub repository slug like owner/name"}]
      end
    end

    defp valid_repository_slug?(value) when is_binary(value) do
      Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, String.trim(value))
    end

    defp validate_project_routes(_field, value) when value in [nil, %{}], do: []

    defp validate_project_routes(field, value) when is_map(value) do
      invalid? =
        Enum.any?(value, fn {repo_slug, aliases} ->
          !valid_repository_slug?(to_string(repo_slug)) or !valid_project_route_aliases?(aliases)
        end)

      if invalid? do
        [
          {field, "must map GitHub repository slugs like owner/name to non-empty Linear project aliases"}
        ]
      else
        []
      end
    end

    defp validate_project_routes(field, _value) do
      [{field, "must be a map of GitHub repository slugs to Linear project aliases"}]
    end

    defp valid_project_route_aliases?(aliases) do
      aliases
      |> List.wrap()
      |> case do
        [] -> false
        values -> Enum.all?(values, &valid_project_route_alias?/1)
      end
    end

    defp valid_project_route_alias?(value) when is_binary(value) do
      value
      |> String.trim()
      |> then(fn trimmed -> trimmed != "" and Regex.match?(~r/[A-Za-z0-9]/, trimmed) end)
    end

    defp valid_project_route_alias?(_value), do: false
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_change(:ssh_hosts, &validate_ssh_hosts/2)
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end

    defp validate_ssh_hosts(field, values) when is_list(values) do
      values
      |> Enum.reject(&valid_ssh_host?/1)
      |> case do
        [] -> []
        _invalid -> [{field, "must contain non-empty SSH destinations that do not start with '-' or contain control characters"}]
      end
    end

    defp valid_ssh_host?(value) when is_binary(value) do
      trimmed = String.trim(value)

      trimmed != "" and
        not String.starts_with?(trimmed, "-") and
        not String.contains?(trimmed, ["\n", "\r", <<0>>])
    end

    defp valid_ssh_host?(_value), do: false
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_continuations, :integer, default: 3)
      field(:max_retry_attempts, :integer, default: 5)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_review_fix_loops, :integer, default: 3)
      field(:same_review_fingerprint_limit, :integer, default: 4)
      field(:same_test_failure_fingerprint_limit, :integer, default: 4)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :max_concurrent_agents,
          :max_turns,
          :max_continuations,
          :max_retry_attempts,
          :max_retry_backoff_ms,
          :max_review_fix_loops,
          :same_review_fingerprint_limit,
          :same_test_failure_fingerprint_limit,
          :max_concurrent_agents_by_state
        ],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_continuations, greater_than_or_equal_to: 0)
      |> validate_number(:max_retry_attempts, greater_than_or_equal_to: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> validate_number(:max_review_fix_loops, greater_than_or_equal_to: 0)
      |> validate_number(:same_review_fingerprint_limit, greater_than_or_equal_to: 0)
      |> validate_number(:same_test_failure_fingerprint_limit, greater_than_or_equal_to: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Retry do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:max_attempts, :integer)
      field(:max_continuations, :integer)
      field(:max_handoff_pr_discovery_attempts, :integer)
      field(:max_blocked_review_handoff_attempts, :integer)
      field(:max_review_handoff_attempts, :integer)
      field(:max_done_sync_attempts, :integer)
      field(:base_backoff_ms, :integer, default: 10_000)
      field(:max_backoff_ms, :integer)
      field(:continuation_delay_ms, :integer, default: 1_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :max_attempts,
          :max_continuations,
          :max_handoff_pr_discovery_attempts,
          :max_blocked_review_handoff_attempts,
          :max_review_handoff_attempts,
          :max_done_sync_attempts,
          :base_backoff_ms,
          :max_backoff_ms,
          :continuation_delay_ms
        ],
        empty_values: []
      )
      |> validate_number(:max_attempts, greater_than_or_equal_to: 0)
      |> validate_number(:max_continuations, greater_than_or_equal_to: 0)
      |> validate_number(:max_handoff_pr_discovery_attempts, greater_than_or_equal_to: 0)
      |> validate_number(:max_blocked_review_handoff_attempts, greater_than_or_equal_to: 0)
      |> validate_number(:max_review_handoff_attempts, greater_than_or_equal_to: 0)
      |> validate_number(:max_done_sync_attempts, greater_than_or_equal_to: 0)
      |> validate_number(:base_backoff_ms, greater_than: 0)
      |> validate_number(:max_backoff_ms, greater_than: 0)
      |> validate_number(:continuation_delay_ms, greater_than: 0)
    end
  end

  defmodule Review do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:final_review, :string, default: "human_required")
      field(:handoff_state, :string)
      field(:require_pr_url_before_handoff, :boolean, default: true)
      field(:approve_equivalent_required_before_handoff, :boolean, default: true)
      field(:merge_decision, :string, default: "human_required_after_approve_equivalent")
      field(:auto_merge, :boolean, default: false)
      field(:max_review_fix_loops, :integer)
      field(:implementer_command, :string)
      field(:reviewer_command, :string)
      field(:implementer_model, :string)
      field(:reviewer_model, :string)
      field(:implementer_profile, :string)
      field(:reviewer_profile, :string)
      field(:blocked_comment_template, :string, default: "Symphony blocked {{ identifier }}.\n\nReason: {{ reason }}")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :final_review,
          :handoff_state,
          :require_pr_url_before_handoff,
          :approve_equivalent_required_before_handoff,
          :merge_decision,
          :auto_merge,
          :max_review_fix_loops,
          :implementer_command,
          :reviewer_command,
          :implementer_model,
          :reviewer_model,
          :implementer_profile,
          :reviewer_profile,
          :blocked_comment_template
        ],
        empty_values: []
      )
      |> validate_number(:max_review_fix_loops, greater_than_or_equal_to: 0)
      |> validate_inclusion(:final_review, ["human_required"])
      |> validate_inclusion(:merge_decision, ["human_required_after_approve_equivalent"])
      |> validate_boolean_policy(:require_pr_url_before_handoff, true)
      |> validate_boolean_policy(:approve_equivalent_required_before_handoff, true)
      |> validate_boolean_policy(:auto_merge, false)
    end

    defp validate_boolean_policy(changeset, field, expected) when is_boolean(expected) do
      validate_change(changeset, field, fn ^field, value ->
        if value == expected do
          []
        else
          [{field, "must be #{expected} for the official human-review workflow"}]
        end
      end)
    end
  end

  defmodule ReviewRework do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:max_rounds, :integer, default: 2)
      field(:interval_ms, :integer, default: 120_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :max_rounds, :interval_ms], empty_values: [])
      |> validate_number(:max_rounds, greater_than_or_equal_to: 0)
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      field(:allow_linear_graphql_mutations, :boolean, default: false)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms,
          :allow_linear_graphql_mutations
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:github_intake, GitHubIntake, on_replace: :update, defaults_to_struct: true)
    embeds_one(:done_sync, DoneSync, on_replace: :update, defaults_to_struct: true)
    embeds_one(:stall, Stall, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:repository, Repository, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:retry, Retry, on_replace: :update, defaults_to_struct: true)
    embeds_one(:review, Review, on_replace: :update, defaults_to_struct: true)
    embeds_one(:review_rework, ReviewRework, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> promote_review_workflow_config()
    |> case do
      {:ok, config} ->
        config
        |> changeset()
        |> apply_action(:validate)
        |> case do
          {:ok, settings} ->
            {:ok, finalize_settings(settings)}

          {:error, changeset} ->
            {:error, {:invalid_workflow_config, format_errors(changeset)}}
        end

      {:error, message} when is_binary(message) ->
        {:error, {:invalid_workflow_config, message}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:github_intake, with: &GitHubIntake.changeset/2)
    |> cast_embed(:done_sync, with: &DoneSync.changeset/2)
    |> cast_embed(:stall, with: &Stall.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:repository, with: &Repository.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:retry, with: &Retry.changeset/2)
    |> cast_embed(:review, with: &Review.changeset/2)
    |> cast_embed(:review_rework, with: &ReviewRework.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> validate_done_sync_interval()
    |> validate_review_rework_interval()
    |> validate_stall_review_threshold()
  end

  defp validate_done_sync_interval(changeset) do
    polling = get_field(changeset, :polling)
    done_sync = get_field(changeset, :done_sync)

    polling_interval_ms = if polling, do: polling.interval_ms
    done_sync_interval_ms = if done_sync, do: done_sync.interval_ms

    if is_integer(polling_interval_ms) and is_integer(done_sync_interval_ms) and
         done_sync_interval_ms < polling_interval_ms do
      add_error(changeset, :done_sync, "interval_ms must be greater than or equal to polling.interval_ms")
    else
      changeset
    end
  end

  defp validate_review_rework_interval(changeset) do
    polling = get_field(changeset, :polling)
    review_rework = get_field(changeset, :review_rework)

    polling_interval_ms = if polling, do: polling.interval_ms
    review_rework_interval_ms = if review_rework, do: review_rework.interval_ms

    if is_integer(polling_interval_ms) and is_integer(review_rework_interval_ms) and
         review_rework_interval_ms < polling_interval_ms do
      add_error(changeset, :review_rework, "interval_ms must be greater than or equal to polling.interval_ms")
    else
      changeset
    end
  end

  defp validate_stall_review_threshold(changeset) do
    polling = get_field(changeset, :polling)
    stall = get_field(changeset, :stall)

    polling_interval_ms = if polling, do: polling.interval_ms
    review_threshold_ms = if stall, do: stall.review_threshold_ms

    if is_integer(polling_interval_ms) and is_integer(review_threshold_ms) and
         review_threshold_ms <= polling_interval_ms do
      add_error(changeset, :stall, "review_threshold_ms must be greater than polling.interval_ms")
    else
      changeset
    end
  end

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)

  defp promote_review_workflow_config(%{"x-lab-runtime" => %{} = runtime} = config) do
    case Map.get(runtime, "review_workflow") do
      review_workflow when is_map(review_workflow) ->
        case Map.get(config, "review") do
          nil ->
            {:ok, Map.put(config, "review", review_workflow)}

          existing_review when is_map(existing_review) ->
            {:ok, Map.put(config, "review", Map.merge(existing_review, review_workflow))}

          _ ->
            {:error, "x-lab-runtime.review_workflow requires review to be a map"}
        end

      nil ->
        {:ok, config}

      _ ->
        {:error, "x-lab-runtime.review_workflow must be an object"}
    end
  end

  defp promote_review_workflow_config(config), do: {:ok, config}
end
