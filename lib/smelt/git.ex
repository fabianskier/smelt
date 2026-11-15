defmodule Smelt.Git do
  @moduledoc """
  Thin wrapper around the `git` CLI.

  Every call runs as `git -C <repo> ...` with stderr merged into the output
  and a fixed base environment:

    * `GIT_TERMINAL_PROMPT=0`, so git never waits for credentials
    * `LC_ALL=C`, so messages are the same on every machine

  plus any variables from `config :smelt, Smelt.Git, env: [{"NAME", "value"}]`.
  """

  @base_env [{"GIT_TERMINAL_PROMPT", "0"}, {"LC_ALL", "C"}]

  @type error :: {:git, [String.t()], non_neg_integer(), String.t()}

  @doc """
  Runs `git -C repo args...`.

  Returns `{:ok, output}` when git exits with status 0, or
  `{:error, {:git, args, exit_status, output}}` otherwise.

  Options:

    * `:env` - extra environment variables for this call only, as
      `[{"NAME", "value"}]`, added after the base and configured ones
  """
  @spec cmd(Path.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, error()}
  def cmd(repo, args, opts \\ []) when is_binary(repo) and is_list(args) do
    env = env() ++ Keyword.get(opts, :env, [])

    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git, args, status, output}}
    end
  end

  @doc """
  Returns the worktrees of `repo` that have a branch checked out, as a map of
  branch name to worktree path. The main checkout is included. Git allows a
  branch to be checked out in only one worktree.
  """
  @spec worktrees(Path.t()) :: {:ok, %{String.t() => Path.t()}} | {:error, error()}
  def worktrees(repo) do
    # `git worktree list --porcelain` prints one block per worktree, separated
    # by blank lines:
    #
    #     worktree /path/to/worktree
    #     HEAD <sha>
    #     branch refs/heads/<branch>
    with {:ok, output} <- cmd(repo, ["worktree", "list", "--porcelain"]) do
      worktrees =
        for block <- String.split(output, "\n\n", trim: true),
            lines = String.split(block, "\n", trim: true),
            "worktree " <> path <- Enum.take(lines, 1),
            "branch refs/heads/" <> branch <- lines,
            into: %{} do
          {branch, path}
        end

      {:ok, worktrees}
    end
  end

  defp env do
    extra = :smelt |> Application.get_env(__MODULE__, []) |> Keyword.get(:env, [])
    @base_env ++ extra
  end
end
