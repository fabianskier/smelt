defmodule Mix.Tasks.Smelt.Task do
  @shortdoc "Runs one task of an OpenSpec change with Claude Code, gates it and asks to merge it"

  @moduledoc """
  Runs one task of an OpenSpec change end to end from the terminal.

      mix smelt.task REPO CHANGE TASK_ID [--base BRANCH] [--model NAME]
      mix smelt.task REPO CHANGE TASK_ID --merge
      mix smelt.task REPO CHANGE TASK_ID --discard

  Without a flag, it creates the task's workspace, runs Claude Code on the
  task, runs the gate (resuming the agent once if it fails), and shows the
  agent's activity and the gate's result as they happen. When the task
  passes, it shows the diff and asks `Merge into <base>? [y/N]`: yes merges
  the task into the base branch, anything else keeps the workspace.

    * `--merge` merges a kept workspace (rebasing and gating again if the
      base moved), without running the agent
    * `--discard` removes a task's workspace and branch
    * `--base` is the branch to start from (default `main`)
    * `--model` is the model the agent runs on, for example `sonnet` for a
      documentation-only task (default: the Claude Code CLI's own default)

  Exits with a non-zero status when the task did not pass or a merge failed.
  See `Smelt.TaskRun` for the details.
  """

  use Mix.Task

  alias Smelt.Runner
  alias Smelt.Runner.Event
  alias Smelt.TaskRun
  alias Smelt.TaskRun.Usage
  alias Smelt.Workspace

  @requirements ["app.start"]
  @switches [base: :string, model: :string, merge: :boolean, discard: :boolean]

  @impl Mix.Task
  def run(args), do: run(args, [])

  @doc false
  # `extra` is passed to `Smelt.TaskRun` (tests use it for the fake agent and
  # the workspaces root).
  def run(args, extra) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [repo, change, task_id], []} ->
        repo = Path.expand(repo)
        extra = Keyword.merge(extra, Keyword.take(opts, [:base, :model]))

        cond do
          opts[:discard] -> discard(repo, change, task_id, extra)
          opts[:merge] -> merge_kept(repo, change, task_id, extra)
          true -> run_task(repo, change, task_id, extra)
        end

      _ ->
        Mix.raise(
          "Usage: mix smelt.task REPO CHANGE TASK_ID [--base BRANCH] [--model NAME] [--merge | --discard]"
        )
    end
  end

  ## Running

  defp run_task(repo, change, task_id, extra) do
    id = TaskRun.new_id()
    :ok = TaskRun.subscribe(id)
    for attempt <- 1..2, do: :ok = Runner.subscribe(TaskRun.agent_run_id(id, attempt))

    say("Running task #{task_id} of #{change} in #{repo}")
    task = Task.async(fn -> TaskRun.run(repo, change, task_id, [id: id] ++ extra) end)
    {result, usage} = follow(id, Usage.new())
    _ = Task.await(task, :infinity)
    report_usage(usage, result, {repo, change, task_id}, extra)

    case result do
      {:ok, %TaskRun{status: :passed} = run} ->
        review(run, extra)

      {:ok, %TaskRun{} = run} ->
        say("\nTask #{run.status |> to_string() |> String.replace("_", " ")} (#{cost(run)}).")
        keep(run.workspace)
        fail()

      {:error, reason} ->
        say("\nThe task could not run: #{inspect(reason)}")
        fail()
    end
  end

  # Prints events until the task run finishes, and returns its result with
  # what its agent consumed.
  defp follow(id, usage) do
    receive do
      {TaskRun, ^id, {:finished, result}} ->
        {result, usage}

      {TaskRun, ^id, event} ->
        print_step(event)
        follow(id, usage)

      {Runner, _run_id, %Event{} = event} ->
        print_agent(event)
        follow(id, Usage.record(usage, event))
    end
  end

  # A run that never started (no agent, no turns) has nothing to report.
  defp report_usage(%Usage{turns: 0, tools: tools}, _result, _task, _extra)
       when map_size(tools) == 0,
       do: :ok

  defp report_usage(usage, result, {repo, change, task_id}, extra) do
    say("")
    usage |> Usage.lines() |> Enum.each(&say/1)

    status =
      case result do
        {:ok, %TaskRun{status: status}} -> status
        {:error, _reason} -> :error
      end

    root = Keyword.get_lazy(extra, :root, &Workspace.default_root/0)
    entry = Usage.entry(usage, %{repo: repo, change: change, task_id: task_id, status: status})

    case Usage.append(Path.join(root, "usage.jsonl"), entry) do
      :ok -> :ok
      {:error, reason} -> say("  (usage not recorded: #{inspect(reason)})")
    end
  end

  defp print_step({:workspace_created, ws}), do: say("Workspace #{ws.path} (#{ws.branch})")
  defp print_step({:agent_started, 1, _}), do: say("\n▶ Agent")

  defp print_step({:agent_started, n, _}),
    do: say("\n▶ Agent, attempt #{n} (fixing the gate's findings)")

  defp print_step({:agent_finished, _n, {:ok, result}}),
    do: say("  done in #{result.num_turns || "?"} turns (#{money(result.cost_usd)})")

  defp print_step({:agent_finished, _n, {:error, reason}}),
    do: say("  agent failed: #{inspect(reason)}")

  defp print_step({:gate_started, _n}), do: say("\n▶ Gate")
  defp print_step({:gate_finished, _n, gate}), do: Enum.each(gate.rules, &print_rule/1)

  defp print_rule(%{status: :pass, name: name}), do: say("  ✓ #{name}")
  defp print_rule(%{status: :skipped, name: name}), do: say("  - #{name} (skipped)")

  defp print_rule(%{status: :fail, name: name, details: details}) do
    say("  ✗ #{name}: #{rule_details(details)}")
  end

  defp rule_details(%{violations: violations}),
    do: Enum.map_join(violations, ", ", &"#{&1.path} #{&1.change}")

  defp rule_details(%{changed_lines: lines} = d),
    do: "#{lines}/#{d.max_changed_lines} lines, #{d.changed_files}/#{d.max_changed_files} files"

  defp rule_details(%{output: output} = d),
    do: "#{d[:reason] || "exit #{d[:exit_status]}"}\n#{indent(tail(output, 15))}"

  defp rule_details(details), do: inspect(details)

  defp print_agent(%Event{type: :text, data: %{text: text}}), do: say(indent(String.trim(text)))

  defp print_agent(%Event{type: :tool_use, data: %{name: name, input: input}}),
    do: say("    → #{name} #{tool_summary(input)}")

  defp print_agent(_event), do: :ok

  defp tool_summary(%{"command" => command}), do: String.slice(command, 0, 100)
  defp tool_summary(%{"file_path" => path}), do: path
  defp tool_summary(%{"pattern" => pattern}), do: pattern
  defp tool_summary(_input), do: ""

  ## Approval

  defp review(run, extra) do
    ws = run.workspace

    say(
      "\nTask passed the gate (#{cost(run)}). Changes since #{String.slice(ws.base_sha, 0, 7)}:"
    )

    {:ok, stat} = Smelt.Git.cmd(ws.path, ["diff", "--stat", ws.base_sha])
    say(indent(String.trim_trailing(stat)))

    if yes?("\nMerge into #{ws.base}? [y/N] ") do
      merge(ws, extra)
    else
      keep(ws)
    end
  end

  defp merge_kept(repo, change, task_id, extra) do
    case Workspace.fetch(repo, change, task_id, Keyword.take(extra, [:root])) do
      {:ok, ws} ->
        merge(ws, extra)

      {:error, reason} ->
        say("No workspace to merge: #{inspect(reason)}")
        fail()
    end
  end

  defp merge(ws, extra) do
    case TaskRun.merge(ws, extra) do
      {:ok, %{base: base, sha: sha}} ->
        say("Merged into #{base} at #{String.slice(sha, 0, 7)}; workspace removed.")

      {:error, reason} ->
        say("Merge failed: #{merge_error(reason)}")
        keep(ws)
        fail()
    end
  end

  defp merge_error({:dirty_checkout, path}),
    do: "#{path} has uncommitted changes on the base branch; commit or stash them first"

  defp merge_error(:rebase_conflict), do: "the task conflicts with new commits on the base branch"
  defp merge_error({:gate_failed, _gate}), do: "the gate failed after rebasing onto the new base"
  defp merge_error(reason), do: inspect(reason)

  defp keep(ws) do
    command = "mix smelt.task #{ws.repo} #{ws.change} #{ws.task_id}"
    say("Workspace kept at #{ws.path}")
    say("  merge it:   #{command} --merge")
    say("  discard it: #{command} --discard")
  end

  defp discard(repo, change, task_id, extra) do
    case TaskRun.discard(repo, change, task_id, extra) do
      {:ok, :removed} ->
        say("Discarded task #{task_id} of #{change}.")

      {:ok, :absent} ->
        say("Task #{task_id} of #{change} has no workspace.")

      {:error, reason} ->
        say("Discard failed: #{inspect(reason)}")
        fail()
    end
  end

  ## Helpers

  defp yes?(question) do
    case IO.gets(question) do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      _eof -> false
    end
  end

  defp cost(run), do: money(run.cost_usd)
  defp money(nil), do: "$?"
  defp money(usd), do: "$" <> :erlang.float_to_binary(usd / 1, decimals: 2)

  defp tail(nil, _n), do: ""
  defp tail(text, n), do: text |> String.split("\n") |> Enum.take(-n) |> Enum.join("\n")

  defp indent(text), do: text |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))

  defp say(text), do: IO.puts(text)

  defp fail, do: exit({:shutdown, 1})
end
