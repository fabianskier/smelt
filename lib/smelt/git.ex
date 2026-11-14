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
  """
  @spec cmd(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, error()}
  def cmd(repo, args) when is_binary(repo) and is_list(args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true, env: env()) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git, args, status, output}}
    end
  end

  defp env do
    extra = :smelt |> Application.get_env(__MODULE__, []) |> Keyword.get(:env, [])
    @base_env ++ extra
  end
end
