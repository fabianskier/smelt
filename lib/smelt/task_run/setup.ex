defmodule Smelt.TaskRun.Setup do
  @moduledoc """
  Prepares a task workspace before the agent starts.

  A workspace is a fresh worktree: no dependencies, no build. When the task's
  base commit has a `.smelt/setup.sh`, `run/2` runs it in the workspace (for
  example `mix deps.get` and a compile), so the agent does not spend turns
  and context on it. The script's output stays with Smelt.

  The script is read from the base commit, like the checks script, so a task
  cannot change it. It must write only ignored files: anything else would be
  committed with the task.
  """

  alias Smelt.Gate.Command
  alias Smelt.Git
  alias Smelt.Workspace

  @script ".smelt/setup.sh"
  @timeout_ms 900_000

  @type outcome ::
          :skipped
          | :ok
          | {:error, %{optional(:exit_status) => integer(), reason: atom(), output: String.t()}}

  @doc "The path of the setup script inside a project."
  @spec script() :: String.t()
  def script, do: @script

  @doc """
  Runs the base commit's setup script in the workspace.

  Returns `:skipped` when the project has none, `:ok` when it exits with
  status 0, and `{:error, details}` when it fails (`reason: :failed`, with the
  exit status) or runs out of time (`reason: :timeout`), with the end of its
  output.

  Options:

    * `:timeout` - milliseconds before the script is killed (default 15 minutes)
  """
  @spec run(Workspace.t(), keyword()) :: outcome()
  def run(%Workspace{} = ws, opts \\ []) do
    object = "#{ws.base_sha}:#{@script}"

    with {:ok, _} <- Git.cmd(ws.repo, ["cat-file", "-e", object]),
         {:ok, script} <- Git.cmd(ws.repo, ["show", object]) do
      run_script(ws, script, Keyword.get(opts, :timeout, @timeout_ms))
    else
      {:error, _} -> :skipped
    end
  end

  defp run_script(ws, script, timeout) do
    file = Path.join(System.tmp_dir!(), "smelt-setup-#{System.unique_integer([:positive])}.sh")
    File.write!(file, script)

    try do
      # The script decides its own Mix environment, not Smelt's.
      case Command.run("/bin/sh", [file],
             cd: ws.path,
             env: [{"MIX_ENV", false}],
             timeout: timeout
           ) do
        {:ok, %{exit_status: 0}} ->
          :ok

        {:ok, %{exit_status: status, output: output}} ->
          {:error, %{reason: :failed, exit_status: status, output: output}}

        {:error, {:timeout, output}} ->
          {:error, %{reason: :timeout, output: output}}

        {:error, :executable_not_found} ->
          {:error, %{reason: :shell_not_found, output: ""}}
      end
    after
      File.rm(file)
    end
  end
end
