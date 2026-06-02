defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, RepositoryResolver, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_dirty_workspace_marker "__SYMPHONY_DIRTY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host) do
        case maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
          :ok ->
            {:ok, workspace}

          {:error, reason} = error ->
            cleanup_created_workspace_after_create_failure(workspace, worker_host, created?, reason)
            error
        end
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        with :ok <- ensure_reusable_workspace(workspace) do
          {:ok, workspace, false}
        end

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "  cd \"$workspace\"",
        "  if [ -d .git ]; then",
        "    dirty_status=$(git status --porcelain)",
        "    if [ -n \"$dirty_status\" ]; then",
        "      {",
        "        printf '%s\\n\\n' 'dirty workspace detected'",
        "        printf 'Workspace: %s\\n' \"$(pwd -P)\"",
        "        printf 'Recorded at: %s\\n\\n' \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"",
        "        printf '%s\\n' 'Git status --porcelain:'",
        "        printf '%s\\n' \"$dirty_status\"",
        "        printf '\\n%s\\n' 'Git diff --stat:'",
        "        git diff --stat || true",
        "      } > \"$workspace.dirty-reason.log\"",
        "      escaped_dirty_status=$(printf '%s' \"$dirty_status\" | sed ':a;N;$!ba;s/\\n/\\\\n/g')",
        "      printf '%s\\t%s\\t%s\\n' '#{@remote_dirty_workspace_marker}' \"$(pwd -P)\" \"$escaped_dirty_status\"",
        "      exit 72",
        "    fi",
        "  fi",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        case parse_remote_dirty_workspace_output(output) do
          {:ok, workspace, dirty_status} ->
            {:error, {:dirty_workspace, workspace, dirty_status}}

          :error ->
            {:error, {:workspace_prepare_failed, worker_host, status, output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  defp cleanup_created_workspace_after_create_failure(_workspace, _worker_host, false, _reason), do: :ok

  defp cleanup_created_workspace_after_create_failure(workspace, nil, true, reason) do
    Logger.warning("Removing newly-created workspace after after_create failure workspace=#{workspace} reason=#{inspect(reason)}")
    File.rm_rf(workspace)
    :ok
  end

  defp cleanup_created_workspace_after_create_failure(workspace, worker_host, true, reason)
       when is_binary(worker_host) do
    Logger.warning("Removing newly-created remote workspace after after_create failure workspace=#{workspace} worker_host=#{worker_host} reason=#{inspect(reason)}")

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning(
          "Failed to remove workspace after after_create failure workspace=#{workspace} worker_host=#{worker_host} status=#{status} output=#{inspect(sanitize_hook_output_for_log(output))}"
        )

        :ok

      {:error, cleanup_reason} ->
        Logger.warning("Failed to remove workspace after after_create failure workspace=#{workspace} worker_host=#{worker_host} reason=#{inspect(cleanup_reason)}")
        :ok
    end
  end

  defp ensure_reusable_workspace(workspace) do
    if File.dir?(Path.join(workspace, ".git")) do
      case System.cmd("git", ["-C", workspace, "status", "--porcelain"], stderr_to_stdout: true) do
        {"", 0} ->
          :ok

        {output, 0} ->
          write_dirty_workspace_reason_log(workspace, output)
          {:error, {:dirty_workspace, workspace, output}}

        {output, status} ->
          {:error, {:workspace_git_status_failed, workspace, status, output}}
      end
    else
      :ok
    end
  end

  defp write_dirty_workspace_reason_log(workspace, dirty_status) do
    diff_summary =
      case System.cmd("git", ["-C", workspace, "diff", "--stat"], stderr_to_stdout: true) do
        {"", 0} -> ""
        {output, 0} -> "\nGit diff --stat:\n#{output}"
        {output, status} -> "\nGit diff --stat failed status=#{status}:\n#{output}"
      end

    body = """
    dirty workspace detected

    Workspace: #{workspace}
    Recorded at: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    Git status --porcelain:
    #{dirty_status}#{diff_summary}
    """

    File.write(dirty_workspace_reason_log_path(workspace), body)
    :ok
  end

  defp dirty_workspace_reason_log_path(workspace) do
    Path.join(Path.dirname(workspace), "#{Path.basename(workspace)}.dirty-reason.log")
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove(workspace, worker_host)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove(workspace, nil)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec cleanup_dirty_workspaces(keyword()) :: {:ok, %{removed: [String.t()], kept: [String.t()]}} | {:error, term()}
  def cleanup_dirty_workspaces(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    settings = Config.settings!()
    root = settings.workspace.root
    retention_days = settings.workspace.dirty_workspace_retention_days

    with true <- retention_days > 0,
         {:ok, entries} <- File.ls(root) do
      cutoff = DateTime.add(now, -retention_days, :day)

      entries
      |> Enum.map(&Path.join(root, &1))
      |> Enum.reduce({[], []}, fn path, {removed, kept} ->
        case dirty_workspace_timestamp(path) do
          {:ok, timestamp} ->
            if DateTime.compare(timestamp, cutoff) == :lt do
              File.rm_rf(path)
              {[path | removed], kept}
            else
              {removed, [path | kept]}
            end

          :error ->
            {removed, kept}
        end
      end)
      |> then(fn {removed, kept} -> {:ok, %{removed: Enum.reverse(removed), kept: Enum.reverse(kept)}} end)
    else
      false -> {:ok, %{removed: [], kept: []}}
      {:error, :enoent} -> {:ok, %{removed: [], kept: []}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command],
          cd: workspace,
          stderr_to_stdout: true,
          env: hook_env(issue_context)
        )
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      [
        remote_hook_env_assignments(issue_context),
        "cd #{shell_escape(workspace)}",
        command
      ]
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_dirty_workspace_output(output) do
    output
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.find_value(:error, fn line ->
      case String.split(line, "\t", parts: 3) do
        [@remote_dirty_workspace_marker, path, dirty_status] when path != "" ->
          {:ok, path, String.replace(dirty_status, "\\n", "\n")}

        _ ->
          nil
      end
    end)
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp dirty_workspace_timestamp(path) when is_binary(path) do
    basename = Path.basename(path)

    with true <- File.dir?(path),
         [date, time] <- Regex.run(~r/\.dirty-(\d{8})-(\d{6})$/, basename, capture: :all_but_first),
         {:ok, naive} <- NaiveDateTime.from_iso8601(dirty_timestamp_iso8601(date, time)) do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      _ -> :error
    end
  end

  defp dirty_timestamp_iso8601(<<year::binary-size(4), month::binary-size(2), day::binary-size(2)>>, <<hour::binary-size(2), minute::binary-size(2), second::binary-size(2)>>) do
    "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}"
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp hook_env(issue_context) do
    repository = Map.get(issue_context, :repository, %{})

    [
      {"SYMPHONY_ISSUE_ID", issue_context.issue_id},
      {"SYMPHONY_ISSUE_IDENTIFIER", issue_context.issue_identifier},
      {"SYMPHONY_REPOSITORY", Map.get(repository, :slug)},
      {"SYMPHONY_REPOSITORY_OWNER", Map.get(repository, :owner)},
      {"SYMPHONY_REPOSITORY_NAME", Map.get(repository, :name)},
      {"SYMPHONY_REPOSITORY_CLONE_URL", Map.get(repository, :clone_url)},
      {"SYMPHONY_GITHUB_ISSUE_URL", Map.get(repository, :github_issue_url)}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
  end

  defp remote_hook_env_assignments(issue_context) do
    Enum.map(hook_env(issue_context), fn {key, value} -> remote_shell_assign(key, value) end)
  end

  defp issue_context(%{id: issue_id, identifier: identifier} = issue) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      repository: RepositoryResolver.resolve!(issue)
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      repository: RepositoryResolver.resolve!(identifier)
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      repository: RepositoryResolver.resolve!(nil)
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
