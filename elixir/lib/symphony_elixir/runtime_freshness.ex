defmodule SymphonyElixir.RuntimeFreshness do
  @moduledoc """
  Checks whether the long-running Symphony runtime contains the configured upstream.

  Landing automation is intentionally fail-closed when this check reports a
  stale or unknown runtime. Otherwise an old process can mutate Linear state
  with behavior that has already been fixed on `origin/main`.
  """

  alias SymphonyElixir.GitHubCommand

  @default_upstream_ref "origin/main"
  @default_timeout_ms 10_000

  @type status :: :fresh | :stale | :unknown

  @type t :: %{
          status: status(),
          checked_at: DateTime.t(),
          repo_path: String.t() | nil,
          current_sha: String.t() | nil,
          upstream_ref: String.t(),
          upstream_sha: String.t() | nil,
          message: String.t() | nil
        }

  @type deps :: %{
          required(:run_command) => (String.t(), [String.t()], keyword() -> GitHubCommand.result())
        }

  @spec check(keyword()) :: t()
  def check(opts \\ []) do
    repo_path = Keyword.get(opts, :repo_path) || configured_repo_path() || discover_repo_root()
    upstream_ref = Keyword.get(opts, :upstream_ref) || configured_upstream_ref()
    fetch? = Keyword.get(opts, :fetch, false)
    deps = Keyword.get(opts, :deps, runtime_deps())

    do_check(repo_path, upstream_ref, fetch?, deps)
  end

  defp do_check(nil, upstream_ref, _fetch?, _deps) do
    result(:unknown, nil, nil, upstream_ref, nil, "could not discover a Git repository for the running runtime")
  end

  defp do_check(repo_path, upstream_ref, fetch?, deps) do
    with :ok <- maybe_fetch_upstream(repo_path, upstream_ref, fetch?, deps),
         {:ok, current_sha} <- git_output(repo_path, ["rev-parse", "HEAD"], deps),
         {:ok, upstream_sha} <- git_output(repo_path, ["rev-parse", upstream_ref], deps),
         {:ok, fresh?} <- upstream_ancestor?(repo_path, upstream_sha, current_sha, deps) do
      if fresh? do
        result(:fresh, repo_path, current_sha, upstream_ref, upstream_sha, nil)
      else
        message = "runtime HEAD does not contain #{upstream_ref}; pull/restart required"
        result(:stale, repo_path, current_sha, upstream_ref, upstream_sha, message)
      end
    else
      {:error, reason} ->
        result(:unknown, repo_path, nil, upstream_ref, nil, "runtime freshness check failed: #{inspect(reason)}")
    end
  end

  defp maybe_fetch_upstream(_repo_path, _upstream_ref, false, _deps), do: :ok

  defp maybe_fetch_upstream(repo_path, upstream_ref, true, deps) do
    case String.split(upstream_ref, "/", parts: 2) do
      [remote, branch] when remote != "" and branch != "" ->
        case git(repo_path, ["fetch", "--quiet", remote, branch], deps) do
          {:ok, {_output, 0}} -> :ok
          {:ok, {output, status}} -> {:error, {:git_fetch_failed, status, String.trim(output)}}
          {:error, reason} -> {:error, {:git_fetch_failed, reason}}
        end

      _ ->
        :ok
    end
  end

  defp upstream_ancestor?(repo_path, upstream_sha, current_sha, deps) do
    case git(repo_path, ["merge-base", "--is-ancestor", upstream_sha, current_sha], deps) do
      {:ok, {_output, 0}} -> {:ok, true}
      {:ok, {_output, 1}} -> {:ok, false}
      {:ok, {output, status}} -> {:error, {:git_merge_base_failed, status, String.trim(output)}}
      {:error, reason} -> {:error, {:git_merge_base_failed, reason}}
    end
  end

  defp git_output(repo_path, args, deps) do
    case git(repo_path, args, deps) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, status}} ->
        {:error, {:git_failed, args, status, String.trim(output)}}

      {:error, reason} ->
        {:error, {:git_failed, args, reason}}
    end
  end

  defp git(repo_path, args, deps) do
    deps.run_command.("git", ["-C", repo_path | args], stderr_to_stdout: true, timeout_ms: @default_timeout_ms)
  end

  defp result(status, repo_path, current_sha, upstream_ref, upstream_sha, message) do
    %{
      status: status,
      checked_at: DateTime.utc_now() |> DateTime.truncate(:second),
      repo_path: repo_path,
      current_sha: current_sha,
      upstream_ref: upstream_ref,
      upstream_sha: upstream_sha,
      message: message
    }
  end

  defp configured_repo_path do
    case Application.get_env(:symphony_elixir, :runtime_freshness_repo_path) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp configured_upstream_ref do
    case Application.get_env(:symphony_elixir, :runtime_freshness_upstream_ref) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> @default_upstream_ref
    end
  end

  defp discover_repo_root do
    [File.cwd!(), Path.expand("../../..", __DIR__)]
    |> Enum.find_value(&ancestor_git_root/1)
  end

  defp ancestor_git_root(path) when is_binary(path) do
    path
    |> Path.expand()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(nil, fn candidate, _acc ->
      cond do
        File.exists?(Path.join(candidate, ".git")) ->
          {:halt, candidate}

        Path.dirname(candidate) == candidate ->
          {:halt, nil}

        true ->
          {:cont, nil}
      end
    end)
  end

  defp runtime_deps do
    %{run_command: &GitHubCommand.run_system_cmd/3}
  end
end
