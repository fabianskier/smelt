defmodule Smelt.Gate do
  @moduledoc """
  Decides deterministically, without AI, whether a task workspace's changes
  are acceptable.

  The gate measures the workspace's changes since its base commit and runs
  four rules, in order:

    1. `:protected_files` - existing tests and `.smelt/` are untouched
    2. `:diff_size` - the change is under the line and file maximums
    3. `:openspec` - `openspec validate --all --strict` passes (skipped when
       the project has no `openspec/` directory)
    4. `:checks` - the project's `.smelt/checks.sh` exits 0 within the timeout
       (skipped when any earlier rule failed)

  Configuration (`.smelt/gate.json`, see `Smelt.Gate.Config`) and the checks
  script are always taken from the workspace's base commit, so the task can't
  weaken its own gate. The gate only reports: it never changes the workspace.
  """

  alias Smelt.Gate.Changes
  alias Smelt.Gate.Command
  alias Smelt.Gate.Config
  alias Smelt.Gate.Result
  alias Smelt.Gate.Rules
  alias Smelt.Git
  alias Smelt.Workspace

  @checks_script ".smelt/checks.sh"

  @doc """
  Runs the gate on a workspace.

  Returns `{:ok, %Smelt.Gate.Result{}}` with a verdict, or an error that
  says nothing about the task's work:

    * `{:invalid_config, message}` - the base commit's `.smelt/gate.json` is invalid
    * `:workspace_missing` - the workspace directory doesn't exist
    * `{:git, args, status, output}` - an unexpected git failure

  Options:

    * `:openspec` - the OpenSpec executable, default from
      `config :smelt, Smelt.Gate, openspec: ...`, else `"openspec"`
  """
  @spec run(Workspace.t(), keyword()) ::
          {:ok, Result.t()}
          | {:error, {:invalid_config, String.t()} | :workspace_missing | Git.error()}
  def run(%Workspace{} = ws, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with :ok <- ensure_workspace(ws),
         {:ok, config} <- Config.load(ws.repo, ws.base_sha),
         {:ok, changes} <- Changes.measure(ws) do
      cheap = [
        Rules.protected_files(changes, config),
        Rules.diff_size(changes, config),
        openspec(ws, config, opts)
      ]

      checks =
        if Enum.any?(cheap, &(&1.status == :fail)),
          do: outcome(:checks, :skipped, %{reason: :earlier_rule_failed}),
          else: checks(ws, config)

      rules = cheap ++ [checks]

      {:ok,
       %Result{
         status: if(Enum.any?(rules, &(&1.status == :fail)), do: :fail, else: :pass),
         rules: rules,
         duration_ms: System.monotonic_time(:millisecond) - started
       }}
    end
  end

  @doc """
  Runs the base commit's `.smelt/checks.sh` in the workspace and returns the
  `:checks` rule outcome. `run/2` calls it only when the cheaper rules pass.

  The script is extracted from the base commit to a temporary file outside
  the workspace and run as `/bin/sh <file>`, with the workspace as working
  directory, so it needs no executable bit and the workspace's own copy is
  never used.
  """
  @spec checks(Workspace.t(), Config.t()) :: Result.rule()
  def checks(%Workspace{} = ws, %Config{} = config) do
    object = "#{ws.base_sha}:#{@checks_script}"

    with {:ok, _} <- Git.cmd(ws.repo, ["cat-file", "-e", object]),
         {:ok, script} <- Git.cmd(ws.repo, ["show", object]) do
      run_script(ws, script, config)
    else
      {:error, _} -> outcome(:checks, :fail, %{reason: :missing_script})
    end
  end

  defp run_script(ws, script, config) do
    file = Path.join(System.tmp_dir!(), "smelt-checks-#{System.unique_integer([:positive])}.sh")
    File.write!(file, script)

    try do
      # The script decides its own Mix environment, not Smelt's.
      case Command.run("/bin/sh", [file],
             cd: ws.path,
             env: [{"MIX_ENV", false}],
             timeout: config.timeout_seconds * 1_000
           ) do
        {:ok, %{exit_status: 0} = result} ->
          outcome(:checks, :pass, result)

        {:ok, result} ->
          outcome(:checks, :fail, result)

        {:error, {:timeout, output}} ->
          outcome(:checks, :fail, %{reason: :timeout, output: output})
      end
    after
      File.rm(file)
    end
  end

  defp openspec(ws, config, opts) do
    if File.dir?(Path.join(ws.path, "openspec")) do
      executable =
        Keyword.get_lazy(opts, :openspec, fn ->
          :smelt |> Application.get_env(__MODULE__, []) |> Keyword.get(:openspec, "openspec")
        end)

      case Command.run(executable, ["validate", "--all", "--strict", "--no-interactive"],
             cd: ws.path,
             env: [{"OPENSPEC_TELEMETRY", "0"}, {"NO_COLOR", "1"}],
             timeout: config.timeout_seconds * 1_000
           ) do
        {:ok, %{exit_status: 0, output: output}} ->
          outcome(:openspec, :pass, %{output: output})

        {:ok, %{output: output}} ->
          outcome(:openspec, :fail, %{output: output})

        {:error, {:timeout, output}} ->
          outcome(:openspec, :fail, %{reason: :timeout, output: output})

        {:error, :executable_not_found} ->
          outcome(:openspec, :fail, %{reason: :openspec_not_found})
      end
    else
      outcome(:openspec, :skipped, %{reason: :no_openspec_dir})
    end
  end

  defp ensure_workspace(ws) do
    if File.dir?(ws.path), do: :ok, else: {:error, :workspace_missing}
  end

  defp outcome(name, status, details), do: %{name: name, status: status, details: details}
end
