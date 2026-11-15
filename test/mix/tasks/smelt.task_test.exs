defmodule Mix.Tasks.Smelt.TaskTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Smelt.TaskRunFixtures

  alias Mix.Tasks.Smelt.Task, as: SmeltTask
  alias Smelt.GitRepo
  alias Smelt.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo = project!(tmp_dir)
    %{repo: repo, opts: opts(tmp_dir, [{"FAKE_AGENT_FIRST", commit_app()}])}
  end

  defp workspace_exists?(repo, opts) do
    match?({:ok, _}, Workspace.fetch(repo, "add-x", "1.1", root: opts[:root]))
  end

  describe "Requirement: Drive a task from the terminal" do
    test "Scenario: Approve from the terminal", %{repo: repo, opts: opts} do
      output = capture_io("y\n", fn -> SmeltTask.run([repo, "add-x", "1.1"], opts) end)

      assert output =~ "▶ Agent"
      assert output =~ "working on it"
      assert output =~ "✓ protected_files"
      assert output =~ "lib/app.ex"
      assert output =~ "Merge into main? [y/N]"
      assert output =~ "Merged into main at"

      assert File.read!(Path.join(repo, "lib/app.ex")) == "app\n"
      refute workspace_exists?(repo, opts)
    end

    test "Scenario: Decline keeps the workspace", %{repo: repo, opts: opts} do
      main_sha = GitRepo.sha!(repo, "main")

      output = capture_io("n\n", fn -> SmeltTask.run([repo, "add-x", "1.1"], opts) end)

      assert output =~ "Workspace kept at"
      assert output =~ "--discard"
      assert GitRepo.sha!(repo, "main") == main_sha
      assert workspace_exists?(repo, opts)
    end
  end

  test "--merge merges a kept workspace", %{repo: repo, opts: opts} do
    _ = capture_io("", fn -> SmeltTask.run([repo, "add-x", "1.1"], opts) end)
    assert workspace_exists?(repo, opts)

    output = capture_io(fn -> SmeltTask.run([repo, "add-x", "1.1", "--merge"], opts) end)

    assert output =~ "Merged into main"
    assert File.read!(Path.join(repo, "lib/app.ex")) == "app\n"
  end

  test "--discard removes a kept workspace", %{repo: repo, opts: opts} do
    _ = capture_io("n\n", fn -> SmeltTask.run([repo, "add-x", "1.1"], opts) end)

    output = capture_io(fn -> SmeltTask.run([repo, "add-x", "1.1", "--discard"], opts) end)

    assert output =~ "Discarded task 1.1 of add-x"
    refute workspace_exists?(repo, opts)
    assert GitRepo.branches(repo) == ["main"]
  end

  test "a task that fails the gate exits with a non-zero status", %{repo: repo, tmp_dir: tmp_dir} do
    opts = opts(tmp_dir, [{"FAKE_AGENT_FIRST", break_test()}, {"FAKE_AGENT_RESUMED", "true"}])

    output =
      capture_io(fn ->
        assert catch_exit(SmeltTask.run([repo, "add-x", "1.1"], opts)) == {:shutdown, 1}
      end)

    assert output =~ "▶ Agent, attempt 2"
    assert output =~ "✗ protected_files: test/app_test.exs modified"
    assert output =~ "Task gate failed"
    assert workspace_exists?(repo, opts)
  end

  test "wrong arguments print the usage" do
    assert_raise Mix.Error, ~r/Usage: mix smelt.task/, fn -> SmeltTask.run(["only-one"], []) end
  end
end
