defmodule Smelt.TaskRun do
  @moduledoc """
  Runs one task of an OpenSpec change end to end, then merges or discards it.

  `run/4` creates the task's workspace, runs Claude Code on the task, runs the
  gate and, if the gate fails, resumes the same agent session once with the
  gate's findings. It always keeps the workspace, so a human can review the
  work and then call `merge/2` or `discard/4`.

  Progress is broadcast on `topic/1` as `{Smelt.TaskRun, id, event}`:

    * `{:workspace_created, %Smelt.Workspace{}}`
    * `{:agent_started, attempt, runner_run_id}`
    * `{:agent_finished, attempt, {:ok, %Smelt.Runner.Result{}} | {:error, reason}}`
    * `{:gate_started, attempt}`
    * `{:gate_finished, attempt, %Smelt.Gate.Result{}}`
    * `{:finished, {:ok, %Smelt.TaskRun{}} | {:error, reason}}`

  The agent's own events go to `Smelt.Runner.topic(agent_run_id(id, attempt))`.
  Both ids are known before the run starts, so a subscriber misses nothing.
  """

  alias Smelt.Gate
  alias Smelt.Git
  alias Smelt.Runner.ClaudeCode
  alias Smelt.TaskRun.Prompt
  alias Smelt.TaskRun.TaskList
  alias Smelt.Workspace

  @pubsub Smelt.PubSub
  @max_attempts 2

  # In headless mode anything not allowed is denied, so this is the agent's
  # whole permission set inside the workspace.
  @agent_args [
    "--permission-mode",
    "acceptEdits",
    "--allowedTools",
    "Read",
    "Edit",
    "Write",
    "Glob",
    "Grep",
    "Bash(mix:*)",
    "Bash(MIX_ENV=test mix:*)",
    "Bash(elixir:*)",
    "Bash(erl:*)",
    "Bash(git:*)",
    "Bash(openspec validate:*)",
    "Bash(chmod:*)",
    "Bash(sh .smelt/checks.sh)",
    "--disallowedTools",
    "Bash(git push:*)"
  ]

  @enforce_keys [:id, :workspace, :task]
  defstruct [:id, :workspace, :task, :status, :gate, attempts: [], cost_usd: 0.0]

  @type attempt :: %{
          number: pos_integer(),
          run_id: String.t(),
          result: {:ok, Smelt.Runner.Result.t()} | {:error, term()}
        }

  @type t :: %__MODULE__{
          id: String.t(),
          workspace: Workspace.t(),
          task: TaskList.task(),
          status: :passed | :gate_failed | :agent_failed,
          gate: Gate.Result.t() | nil,
          attempts: [attempt()],
          cost_usd: float()
        }

  @doc "Returns a new task run id."
  @spec new_id() :: String.t()
  def new_id, do: Ecto.UUID.generate()

  @doc "The PubSub topic of a task run."
  @spec topic(String.t()) :: String.t()
  def topic(id), do: "task_run:" <> id

  @doc "Subscribes the calling process to a task run's events."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(id), do: Phoenix.PubSub.subscribe(@pubsub, topic(id))

  @doc "The runner run id of an agent attempt, for `Smelt.Runner.subscribe/1`."
  @spec agent_run_id(String.t(), pos_integer()) :: String.t()
  def agent_run_id(id, attempt), do: "#{id}:#{attempt}"

  @doc "The arguments that limit what the agent may do."
  @spec agent_args() :: [String.t()]
  def agent_args, do: @agent_args

  @doc """
  Runs task `task_id` of `change` in `repo`.

  Returns `{:ok, %Smelt.TaskRun{}}` with `status` `:passed`, `:gate_failed`
  or `:agent_failed`, keeping the workspace in every case. Returns
  `{:error, reason}` when the task never started (the workspace's errors,
  `:change_not_found`, `:task_not_found`, `:task_done`, leaving no workspace)
  or the gate could not run (`{:gate_error, reason}`, keeping the workspace).

  Options:

    * `:id` - the task run id, default `new_id/0`
    * `:base`, `:root` - passed to `Smelt.Workspace.create/4`
    * `:model` - the model for the agent, on every attempt (default: the
      Claude Code CLI's own default)
    * `:runner` - extra options for `Smelt.Runner.ClaudeCode.run/2`
    * `:gate` - options for `Smelt.Gate.run/2`
  """
  @spec run(Path.t(), String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def run(repo, change, task_id, opts \\ []) do
    id = Keyword.get_lazy(opts, :id, &new_id/0)
    ws_opts = Keyword.take(opts, [:base, :root])

    result =
      with {:ok, ws} <- Workspace.create(repo, change, task_id, ws_opts),
           {:ok, task} <- fetch_task(ws, ws_opts) do
        broadcast(id, {:workspace_created, ws})
        run = %__MODULE__{id: id, workspace: ws, task: task}
        attempt(run, 1, Prompt.task(change, task), nil, opts)
      end

    broadcast(id, {:finished, result})
    result
  end

  # The task is read at the workspace's exact base commit. If it can't be
  # used, the fresh workspace (no work in it yet) is removed again.
  defp fetch_task(ws, ws_opts) do
    case TaskList.fetch(ws.repo, ws.base_sha, ws.change, ws.task_id) do
      {:ok, task} ->
        {:ok, task}

      {:error, _} = error ->
        _ = Workspace.remove(ws.repo, ws.change, ws.task_id, [force: true] ++ ws_opts)
        error
    end
  end

  defp attempt(run, number, prompt, session_id, opts) do
    run_id = agent_run_id(run.id, number)
    broadcast(run.id, {:agent_started, number, run_id})

    resume = if session_id, do: ["--resume", session_id], else: []
    model = if opts[:model], do: ["--model", opts[:model]], else: []

    runner_opts =
      opts
      |> Keyword.get(:runner, [])
      |> Keyword.merge(
        cwd: run.workspace.path,
        run_id: run_id,
        args: @agent_args ++ model ++ resume
      )

    result = ClaudeCode.run(prompt, runner_opts)
    broadcast(run.id, {:agent_finished, number, result})

    run = %{
      run
      | attempts: run.attempts ++ [%{number: number, run_id: run_id, result: result}],
        cost_usd: run.cost_usd + cost(result)
    }

    case result do
      {:ok, agent} -> gate(run, number, agent.session_id, opts)
      {:error, _} -> {:ok, %{run | status: :agent_failed}}
    end
  end

  defp gate(run, number, session_id, opts) do
    broadcast(run.id, {:gate_started, number})

    case Gate.run(run.workspace, Keyword.get(opts, :gate, [])) do
      {:error, reason} ->
        {:error, {:gate_error, reason}}

      {:ok, gate} ->
        broadcast(run.id, {:gate_finished, number, gate})
        run = %{run | gate: gate}

        cond do
          gate.status == :pass ->
            {:ok, %{run | status: :passed}}

          number < @max_attempts ->
            attempt(run, number + 1, retry_prompt(run, gate, session_id), session_id, opts)

          true ->
            {:ok, %{run | status: :gate_failed}}
        end
    end
  end

  @doc """
  Merges an approved task into its base branch, then removes its workspace.

    1. Refuses (`{:dirty_checkout, path}`) when the base branch is checked
       out in a worktree with uncommitted changes to tracked files.
    2. Commits anything left uncommitted in the workspace.
    3. If the base branch moved since the workspace was created, rebases the
       task's branch onto it (`:rebase_conflict` on a conflict, after
       aborting) and runs the gate again against the new base
       (`{:gate_failed, %Smelt.Gate.Result{}}`).
    4. Fast-forwards the base branch: with `git merge --ff-only` in the
       worktree that has it checked out, so its files are updated, or with
       `git update-ref` when no worktree has it.
    5. Removes the workspace and its (now merged) branch.

  On any error the base branch is unchanged and the workspace is kept.
  Returns `{:ok, %{base: base, sha: sha}}` with the base branch's new commit.

  Options: `:root` (for the workspace) and `:gate` (for `Smelt.Gate.run/2`).
  """
  @spec merge(Workspace.t(), keyword()) ::
          {:ok, %{base: String.t(), sha: String.t()}} | {:error, term()}
  def merge(%Workspace{} = ws, opts \\ []) do
    with :ok <- ensure_branch(ws),
         {:ok, checkout} <- base_checkout(ws),
         :ok <- ensure_clean(checkout),
         :ok <- commit_leftovers(ws),
         {:ok, base_tip} <- rev_parse(ws.repo, "refs/heads/" <> ws.base),
         :ok <- rebase_if_moved(ws, base_tip, opts),
         {:ok, sha} <- rev_parse(ws.path, "HEAD"),
         :ok <- fast_forward(ws, checkout, sha, base_tip),
         {:ok, _} <- Workspace.remove(ws.repo, ws.change, ws.task_id, Keyword.take(opts, [:root])) do
      {:ok, %{base: ws.base, sha: sha}}
    end
  end

  @doc """
  Discards a task: removes its workspace and its branch, merged or not.
  Returns what `Smelt.Workspace.remove/4` returns.
  """
  @spec discard(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, :removed | :absent} | {:error, term()}
  def discard(repo, change, task_id, opts \\ []) do
    Workspace.remove(repo, change, task_id, [force: true] ++ Keyword.take(opts, [:root]))
  end

  defp ensure_branch(ws) do
    case Git.cmd(ws.repo, ["show-ref", "--verify", "--quiet", "refs/heads/" <> ws.base]) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:base_not_a_branch, ws.base}}
    end
  end

  # The worktree that has the base branch checked out, or nil.
  defp base_checkout(ws) do
    with {:ok, worktrees} <- Git.worktrees(ws.repo), do: {:ok, Map.get(worktrees, ws.base)}
  end

  # Untracked files don't matter: `merge --ff-only` refuses on its own when
  # it would overwrite one.
  defp ensure_clean(nil), do: :ok

  defp ensure_clean(checkout) do
    case Git.cmd(checkout, ["status", "--porcelain", "--untracked-files=no"]) do
      {:ok, ""} -> :ok
      {:ok, _} -> {:error, {:dirty_checkout, checkout}}
      error -> error
    end
  end

  defp commit_leftovers(ws) do
    with {:ok, status} <- Git.cmd(ws.path, ["status", "--porcelain"]) do
      if status == "" do
        :ok
      else
        message = "chore(smelt): commit remaining work of task #{ws.task_id}"

        with {:ok, _} <- Git.cmd(ws.path, ["add", "--all"]),
             {:ok, _} <- Git.cmd(ws.path, ["commit", "--quiet", "-m", message]),
             do: :ok
      end
    end
  end

  defp rebase_if_moved(%Workspace{base_sha: base_tip}, base_tip, _opts), do: :ok

  defp rebase_if_moved(ws, base_tip, opts) do
    case Git.cmd(ws.path, ["rebase", "--quiet", base_tip]) do
      {:ok, _} ->
        case Gate.run(%{ws | base_sha: base_tip}, Keyword.get(opts, :gate, [])) do
          {:ok, %{status: :pass}} -> :ok
          {:ok, gate} -> {:error, {:gate_failed, gate}}
          {:error, reason} -> {:error, {:gate_error, reason}}
        end

      {:error, _} ->
        _ = Git.cmd(ws.path, ["rebase", "--abort"])
        {:error, :rebase_conflict}
    end
  end

  defp fast_forward(_ws, checkout, sha, _base_tip) when is_binary(checkout) do
    with {:ok, _} <- Git.cmd(checkout, ["merge", "--ff-only", "--quiet", sha]), do: :ok
  end

  # `update-ref` with the old value fails if the base moved meanwhile.
  defp fast_forward(ws, nil, sha, base_tip) do
    with {:ok, _} <- Git.cmd(ws.repo, ["update-ref", "refs/heads/" <> ws.base, sha, base_tip]),
         do: :ok
  end

  defp rev_parse(dir, rev) do
    with {:ok, sha} <- Git.cmd(dir, ["rev-parse", "--verify", rev]), do: {:ok, String.trim(sha)}
  end

  # Without a session to resume, the agent needs the task again.
  defp retry_prompt(_run, gate, session_id) when is_binary(session_id), do: Prompt.retry(gate)

  defp retry_prompt(run, gate, nil) do
    Prompt.task(run.workspace.change, run.task) <> "\n" <> Prompt.retry(gate)
  end

  defp cost({:ok, %{cost_usd: cost}}) when is_number(cost), do: cost
  defp cost(_result), do: 0.0

  defp broadcast(id, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(id), {__MODULE__, id, event})
  end
end
