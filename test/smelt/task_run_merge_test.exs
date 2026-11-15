defmodule Smelt.TaskRunMergeTest do
  use ExUnit.Case, async: true

  import Smelt.TaskRunFixtures

  alias Smelt.GitRepo
  alias Smelt.TaskRun
  alias Smelt.Workspace

  @moduletag :tmp_dir

  # Runs task 1.1 with the given fake agent action; it must pass the gate.
  defp passed_task(tmp_dir, action) do
    repo = project!(tmp_dir)
    opts = opts(tmp_dir, [{"FAKE_AGENT_FIRST", action}])
    {:ok, %TaskRun{status: :passed} = run} = TaskRun.run(repo, "add-x", "1.1", opts)
    {repo, run.workspace, opts}
  end

  defp workspace_exists?(repo, opts) do
    match?({:ok, _}, Workspace.fetch(repo, "add-x", "1.1", root: opts[:root]))
  end

  describe "Requirement: Merge an approved task" do
    test "Scenario: Approved task is merged", %{tmp_dir: tmp_dir} do
      {repo, ws, opts} = passed_task(tmp_dir, commit_app())
      task_sha = GitRepo.sha!(ws.path, "HEAD")

      assert TaskRun.merge(ws, opts) == {:ok, %{base: "main", sha: task_sha}}

      assert GitRepo.sha!(repo, "main") == task_sha
      assert GitRepo.current_branch(repo) == "main"
      assert File.read!(Path.join(repo, "lib/app.ex")) == "app\n"
      assert GitRepo.status(repo) == ""
      refute File.exists?(ws.path)
      refute workspace_exists?(repo, opts)
      assert GitRepo.branches(repo) == ["main"]
    end

    test "Scenario: Base branch not checked out", %{tmp_dir: tmp_dir} do
      {repo, ws, opts} = passed_task(tmp_dir, commit_app())
      :ok = GitRepo.branch!(repo, "other")
      :ok = GitRepo.checkout!(repo, "other")

      assert {:ok, %{sha: sha}} = TaskRun.merge(ws, opts)

      assert GitRepo.sha!(repo, "main") == sha
      assert GitRepo.current_branch(repo) == "other"
      refute File.exists?(Path.join(repo, "lib/app.ex"))
      assert GitRepo.branches(repo) == ["main", "other"]
    end

    test "Scenario: Uncommitted work is committed on merge", %{tmp_dir: tmp_dir} do
      {repo, ws, opts} = passed_task(tmp_dir, "mkdir -p lib && echo 'app' > lib/app.ex")

      assert {:ok, _} = TaskRun.merge(ws, opts)

      assert GitRepo.git!(repo, ["show", "main:lib/app.ex"]) == "app\n"

      assert GitRepo.git!(repo, ["log", "-1", "--format=%s", "main"]) ==
               "chore(smelt): commit remaining work of task 1.1\n"
    end
  end

  describe "Requirement: Rebase and gate again when the base moved" do
    test "Scenario: Base moved without conflicts", %{tmp_dir: tmp_dir} do
      {repo, ws, opts} = passed_task(tmp_dir, commit_app())
      other_sha = GitRepo.commit!(repo, "unrelated", %{"docs/notes.md" => "notes\n"})

      assert {:ok, %{sha: sha}} = TaskRun.merge(ws, opts)

      assert GitRepo.sha!(repo, "main") == sha
      assert GitRepo.git!(repo, ["merge-base", "--is-ancestor", other_sha, "main"]) == ""
      assert File.read!(Path.join(repo, "lib/app.ex")) == "app\n"
      assert File.read!(Path.join(repo, "docs/notes.md")) == "notes\n"
      # Linear history: no merge commits.
      assert GitRepo.git!(repo, ["rev-list", "--merges", "main"]) == ""
    end

    test "Scenario: Rebase conflict", %{tmp_dir: tmp_dir} do
      {repo, ws, opts} =
        passed_task(tmp_dir, "echo 'task' > README.md && git commit -qam 'docs: task readme'")

      main_sha = GitRepo.commit!(repo, "conflict", %{"README.md" => "main\n"})

      assert TaskRun.merge(ws, opts) == {:error, :rebase_conflict}

      assert GitRepo.sha!(repo, "main") == main_sha
      assert workspace_exists?(repo, opts)
      # The rebase was aborted: the workspace is clean and back on its branch.
      assert GitRepo.status(ws.path) == ""
      assert GitRepo.current_branch(ws.path) == ws.branch
    end

    test "a gate failure after the rebase stops the merge", %{tmp_dir: tmp_dir} do
      {repo, ws, opts} =
        passed_task(
          tmp_dir,
          "printf 'a\\nb\\n' > lib.txt && git add -A && git commit -qm 'feat: two lines'"
        )

      # The base now allows a single changed line; the task changes two.
      main_sha =
        GitRepo.commit!(repo, "tighten", %{".smelt/gate.json" => ~s({"max_changed_lines": 1})})

      assert {:error, {:gate_failed, gate}} = TaskRun.merge(ws, opts)

      assert %{status: :fail} = Smelt.Gate.Result.rule(gate, :diff_size)
      assert GitRepo.sha!(repo, "main") == main_sha
      assert workspace_exists?(repo, opts)
    end
  end

  describe "Requirement: Never overwrite the user's uncommitted work" do
    test "Scenario: Checkout with uncommitted changes", %{tmp_dir: tmp_dir} do
      {repo, ws, opts} = passed_task(tmp_dir, commit_app())
      main_sha = GitRepo.sha!(repo, "main")
      :ok = GitRepo.write!(repo, "README.md", "my local edit\n")

      assert TaskRun.merge(ws, opts) == {:error, {:dirty_checkout, repo}}

      assert GitRepo.sha!(repo, "main") == main_sha
      assert File.read!(Path.join(repo, "README.md")) == "my local edit\n"
      assert workspace_exists?(repo, opts)
    end

    test "untracked files in the checkout don't block the merge", %{tmp_dir: tmp_dir} do
      {repo, ws, opts} = passed_task(tmp_dir, commit_app())
      :ok = GitRepo.write!(repo, "scratch.txt", "mine\n")

      assert {:ok, _} = TaskRun.merge(ws, opts)
      assert File.read!(Path.join(repo, "scratch.txt")) == "mine\n"
    end
  end

  describe "Requirement: Discard a task" do
    test "Scenario: Task discarded", %{tmp_dir: tmp_dir} do
      repo = project!(tmp_dir)

      opts =
        opts(tmp_dir, [
          {"FAKE_AGENT_FIRST", break_test() <> " && git commit -qam 'test: weaken'"},
          {"FAKE_AGENT_RESUMED", "true"}
        ])

      {:ok, %TaskRun{status: :gate_failed}} = TaskRun.run(repo, "add-x", "1.1", opts)

      assert TaskRun.discard(repo, "add-x", "1.1", opts) == {:ok, :removed}

      refute workspace_exists?(repo, opts)
      assert GitRepo.branches(repo) == ["main"]
      assert TaskRun.discard(repo, "add-x", "1.1", opts) == {:ok, :absent}
    end
  end
end
