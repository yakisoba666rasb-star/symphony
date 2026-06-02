defmodule SymphonyElixir.HermesKanban do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @type cmd_fun :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec sync_issue_running(Issue.t(), keyword()) :: :ok | {:ok, String.t()} | {:error, term()}
  def sync_issue_running(%Issue{} = issue, opts \\ []) do
    with {:ok, settings} <- enabled_settings() do
      create_or_get_task(issue, settings, true, opts)
    end
  end

  @spec sync_issue_done(Issue.t(), keyword()) :: :ok | {:ok, String.t()} | {:error, term()}
  def sync_issue_done(%Issue{} = issue, opts \\ []) do
    with {:ok, settings} <- enabled_settings(),
         {:ok, task_id} <- task_id_option(opts) do
      summary = Keyword.get(opts, :summary) || default_done_summary(issue)
      metadata = done_metadata(issue, Keyword.get(opts, :metadata, %{}))

      case run_hermes(settings, complete_args(settings, task_id, summary, metadata), opts) do
        {:ok, _payload} -> {:ok, task_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp enabled_settings do
    settings = Config.settings!().observability.hermes_kanban

    cond do
      settings.enabled != true ->
        :ok

      not is_binary(settings.command) or String.trim(settings.command) == "" ->
        {:error, :missing_command}

      true ->
        {:ok, settings}
    end
  end

  defp create_or_get_task(%Issue{} = issue, settings, running?, opts) do
    case run_hermes(settings, create_args(settings, issue, running?), opts) do
      {:ok, payload} -> task_id_from_payload(payload)
      {:error, reason} -> {:error, reason}
    end
  end

  defp task_id_option(opts) do
    case Keyword.get(opts, :task_id) do
      task_id when is_binary(task_id) and task_id != "" -> {:ok, task_id}
      _ -> {:error, :missing_task_id}
    end
  end

  defp run_hermes(settings, args, opts) do
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)

    try do
      case cmd.(settings.command, args, stderr_to_stdout: true) do
        {output, 0} ->
          decode_json_output(output)

        {output, status} when is_integer(status) ->
          {:error, {:command_failed, status, String.trim(to_string(output))}}
      end
    rescue
      exception ->
        {:error, {:command_exception, Exception.message(exception)}}
    end
  end

  defp decode_json_output(output) when is_binary(output) do
    case String.trim(output) do
      "" ->
        {:ok, %{}}

      trimmed ->
        case Jason.decode(trimmed) do
          {:ok, payload} -> {:ok, payload}
          {:error, error} -> {:error, {:invalid_json, Exception.message(error), trimmed}}
        end
    end
  end

  defp create_args(settings, %Issue{} = issue, running?) do
    [
      "kanban"
    ]
    |> add_board(settings.board)
    |> Kernel.++([
      "create",
      issue_title(issue),
      "--idempotency-key",
      idempotency_key(issue),
      "--body",
      issue_body(issue)
    ])
    |> add_initial_status(running?)
    |> add_optional("--tenant", settings.tenant)
    |> add_optional("--assignee", settings.assignee)
    |> Kernel.++(["--json"])
  end

  defp complete_args(settings, task_id, summary, metadata) do
    [
      "kanban"
    ]
    |> add_board(settings.board)
    |> Kernel.++([
      "complete",
      task_id,
      "--summary",
      summary,
      "--metadata",
      Jason.encode!(metadata)
    ])
  end

  defp add_board(args, nil), do: args
  defp add_board(args, ""), do: args
  defp add_board(args, board), do: args ++ ["--board", board]

  defp add_initial_status(args, true), do: args ++ ["--initial-status", "running"]
  defp add_initial_status(args, false), do: args

  defp add_optional(args, _flag, nil), do: args
  defp add_optional(args, _flag, ""), do: args
  defp add_optional(args, flag, value), do: args ++ [flag, value]

  defp task_id_from_payload(payload) when is_map(payload) do
    # Hermes CLI JSON has changed shape across preview builds; accept known task-id envelopes,
    # but fail closed when none is present so callers do not complete an arbitrary task.
    task_id =
      payload["id"] ||
        payload["task_id"] ||
        get_in(payload, ["task", "id"]) ||
        get_in(payload, ["data", "id"]) ||
        first_task_id(payload["tasks"])

    case task_id do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, {:missing_task_id, payload}}
    end
  end

  defp first_task_id([%{"id" => id} | _]) when is_binary(id), do: id
  defp first_task_id(_tasks), do: nil

  defp issue_title(%Issue{identifier: identifier, title: title}) do
    [identifier, title]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp issue_body(%Issue{} = issue) do
    [
      issue.url && "Linear: #{issue.url}",
      issue.description
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp idempotency_key(%Issue{id: id}) when is_binary(id) and id != "", do: "linear:#{id}"
  defp idempotency_key(%Issue{identifier: identifier}), do: "linear:#{identifier}"

  defp done_metadata(%Issue{} = issue, metadata) when is_map(metadata) do
    metadata
    |> put_if_present("linear_identifier", issue.identifier)
    |> put_if_present("linear_url", issue.url)
    |> Map.put("source", "symphony")
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp default_done_summary(%Issue{identifier: identifier}) when is_binary(identifier) and identifier != "" do
    "Symphony completed Linear issue #{identifier}"
  end

  defp default_done_summary(_issue), do: "Symphony completed Linear issue"

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
end
