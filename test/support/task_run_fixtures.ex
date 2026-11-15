defmodule Smelt.TaskRunFixtures do
  @moduledoc """
  Builds target projects and options for `Smelt.TaskRun` tests: a gated
  repository with an OpenSpec change `add-x` whose `tasks.md` has an open
  task `1.1`, a done task `1.2` and an open task `1.3`, plus options that run
  `test/support/fake_agent` instead of Claude Code.
  """

  alias Smelt.GitRepo

  @fake_agent Path.expand("fake_agent", __DIR__)

  @tasks """
  # Tasks

  - [ ] 1.1 Add the app module
  - [x] 1.2 Already done
  - [ ] 1.3 Another task
  """

  @doc "Creates the project in `tmp_dir/repo` and returns its path."
  @spec project!(Path.t()) :: Path.t()
  def project!(tmp_dir) do
    GitRepo.gate_project!(Path.join(tmp_dir, "repo"),
      files: %{"openspec/changes/add-x/tasks.md" => @tasks}
    )
  end

  @doc """
  Options for `Smelt.TaskRun.run/4` and `merge/2`: workspaces under
  `tmp_dir/ws`, the fake agent with `agent_env`, its calls logged under
  `tmp_dir/agent`, and a no-op OpenSpec validator (the fixture change has
  only a `tasks.md`).
  """
  @spec opts(Path.t(), [{String.t(), String.t()}]) :: keyword()
  def opts(tmp_dir, agent_env \\ []) do
    log_dir = Path.join(tmp_dir, "agent")
    File.mkdir_p!(log_dir)

    [
      root: Path.join(tmp_dir, "ws"),
      runner: [executable: @fake_agent, env: [{"FAKE_AGENT_LOG_DIR", log_dir} | agent_env]],
      gate: [openspec: "true"]
    ]
  end

  @doc "Returns the arguments of each fake agent call, in order."
  @spec agent_calls(Path.t()) :: [[String.t()]]
  def agent_calls(tmp_dir) do
    dir = Path.join(tmp_dir, "agent")

    dir
    |> File.ls!()
    |> Enum.sort_by(fn "call-" <> n -> String.to_integer(n) end)
    |> Enum.map(&(dir |> Path.join(&1) |> File.read!() |> String.split("\0", trim: true)))
  end

  @doc "A fake agent action that adds `lib/app.ex` and commits it."
  def commit_app,
    do: "mkdir -p lib && echo 'app' > lib/app.ex && git add -A && git commit -qm 'feat: add app'"

  @doc "A fake agent action that weakens the existing test (a protected file)."
  def break_test, do: "echo 'weakened' > test/app_test.exs"

  @doc "A fake agent action that restores the existing test."
  def restore_test, do: "git checkout -- test/app_test.exs"
end
