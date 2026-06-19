defmodule SymphonyElixir.RuntimeFreshnessTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RuntimeFreshness

  test "reports fresh when current runtime contains upstream" do
    result =
      RuntimeFreshness.check(
        repo_path: "/repo",
        upstream_ref: "origin/main",
        deps: deps(%{ancestor?: true})
      )

    assert %{
             status: :fresh,
             repo_path: "/repo",
             current_sha: "current-sha",
             upstream_ref: "origin/main",
             upstream_sha: "upstream-sha",
             message: nil
           } = result
  end

  test "reports stale when upstream is not an ancestor of the runtime HEAD" do
    result =
      RuntimeFreshness.check(
        repo_path: "/repo",
        upstream_ref: "origin/main",
        deps: deps(%{ancestor?: false})
      )

    assert %{
             status: :stale,
             current_sha: "current-sha",
             upstream_sha: "upstream-sha"
           } = result

    assert result.message =~ "runtime HEAD does not contain origin/main"
  end

  test "fetches the configured remote branch before checking when requested" do
    owner = self()

    result =
      RuntimeFreshness.check(
        repo_path: "/repo",
        upstream_ref: "origin/main",
        fetch: true,
        deps: deps(%{owner: owner, ancestor?: true})
      )

    assert %{status: :fresh} = result
    assert_receive {:git_args, ["-C", "/repo", "fetch", "--quiet", "origin", "main"]}
  end

  test "reports unknown when git commands fail" do
    result =
      RuntimeFreshness.check(
        repo_path: "/repo",
        upstream_ref: "origin/main",
        deps: deps(%{fail_rev_parse?: true})
      )

    assert %{status: :unknown, current_sha: nil, upstream_sha: nil} = result
    assert result.message =~ "runtime freshness check failed"
  end

  defp deps(opts) do
    owner = Map.get(opts, :owner)

    %{
      run_command: fn "git", args, _cmd_opts ->
        if owner do
          send(owner, {:git_args, args})
        end

        git_result(args, opts)
      end
    }
  end

  defp git_result(["-C", "/repo", "fetch", "--quiet", "origin", "main"], _opts), do: {:ok, {"", 0}}

  defp git_result(["-C", "/repo", "rev-parse", "HEAD"], %{fail_rev_parse?: true}), do: {:ok, {"fatal\n", 128}}
  defp git_result(["-C", "/repo", "rev-parse", "HEAD"], _opts), do: {:ok, {"current-sha\n", 0}}
  defp git_result(["-C", "/repo", "rev-parse", "origin/main"], _opts), do: {:ok, {"upstream-sha\n", 0}}

  defp git_result(["-C", "/repo", "merge-base", "--is-ancestor", "upstream-sha", "current-sha"], %{ancestor?: false}),
    do: {:ok, {"", 1}}

  defp git_result(["-C", "/repo", "merge-base", "--is-ancestor", "upstream-sha", "current-sha"], _opts),
    do: {:ok, {"", 0}}
end
