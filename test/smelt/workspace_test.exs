defmodule Smelt.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Smelt.GitRepo
  alias Smelt.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo = GitRepo.init!(Path.join(tmp_dir, "repo"))
    root = Path.join(tmp_dir, "workspaces")

    %{repo: repo, root: root, opts: [root: root]}
  end

  describe "Requirement: Create a workspace for a task" do
    test "Scenario: Workspace is created from the base branch", ctx do
      main_sha = GitRepo.sha!(ctx.repo, "main")

      assert {:ok, ws} = Workspace.create(ctx.repo, "add-x", "2.1", ctx.opts)

      assert ws.repo == ctx.repo
      assert ws.change == "add-x"
      assert ws.task_id == "2.1"
      assert ws.branch == "smelt/add-x/2.1"
      assert ws.base == "main"
      assert ws.base_sha == main_sha

      refute String.starts_with?(ws.path, ctx.repo <> "/")
      assert String.starts_with?(ws.path, ctx.root <> "/")

      assert GitRepo.current_branch(ws.path) == "smelt/add-x/2.1"
      assert GitRepo.sha!(ws.path, "HEAD") == main_sha
      assert File.read!(Path.join(ws.path, "README.md")) == "# Test repo\n"
    end

    test "Scenario: Another base branch is used", ctx do
      :ok = GitRepo.branch!(ctx.repo, "release")
      :ok = GitRepo.checkout!(ctx.repo, "release")
      release_sha = GitRepo.commit!(ctx.repo, "release fix", %{"fix.txt" => "fix\n"})
      :ok = GitRepo.checkout!(ctx.repo, "main")

      assert {:ok, ws} =
               Workspace.create(ctx.repo, "add-x", "1", Keyword.put(ctx.opts, :base, "release"))

      assert ws.base == "release"
      assert ws.base_sha == release_sha
      assert GitRepo.sha!(ctx.repo, ws.branch) == release_sha
      assert File.exists?(Path.join(ws.path, "fix.txt"))
    end

    test "Scenario: Base branch does not exist", ctx do
      opts = Keyword.put(ctx.opts, :base, "no-such-branch")

      assert Workspace.create(ctx.repo, "add-x", "1", opts) ==
               {:error, {:unknown_base, "no-such-branch"}}

      assert_nothing_created(ctx)
    end

    test "Scenario: Not a git repository", ctx do
      # tmp_dir lives inside Smelt's own repository, so use the system tmp dir.
      dir = Path.join(System.tmp_dir!(), "smelt-not-a-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert Workspace.create(dir, "add-x", "1", ctx.opts) == {:error, :not_a_repository}

      assert Workspace.create(Path.join(dir, "missing"), "add-x", "1", ctx.opts) ==
               {:error, :not_a_repository}

      refute File.exists?(ctx.root)
    end
  end

  describe "Requirement: One workspace per task" do
    test "Scenario: Task already has a workspace", ctx do
      {:ok, ws} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)
      :ok = GitRepo.write!(ws.path, "work.txt", "in progress\n")
      branch_sha = GitRepo.sha!(ctx.repo, ws.branch)

      assert Workspace.create(ctx.repo, "add-x", "1", ctx.opts) == {:error, :already_exists}

      assert File.read!(Path.join(ws.path, "work.txt")) == "in progress\n"
      assert GitRepo.current_branch(ws.path) == ws.branch
      assert GitRepo.sha!(ctx.repo, ws.branch) == branch_sha
      assert Workspace.fetch(ctx.repo, "add-x", "1", ctx.opts) == {:ok, ws}
    end
  end

  describe "Requirement: Reject unsafe identifiers" do
    test "Scenario: Change name with a path separator", ctx do
      assert Workspace.create(ctx.repo, "../escape", "1", ctx.opts) ==
               {:error, {:invalid_identifier, :change}}

      assert_nothing_created(ctx)
      refute File.exists?(Path.join(ctx.root, "../escape"))
    end

    test "Scenario: Malformed task id", ctx do
      for task_id <- ["1..2", "main"] do
        assert Workspace.create(ctx.repo, "add-x", task_id, ctx.opts) ==
                 {:error, {:invalid_identifier, :task_id}}
      end

      assert_nothing_created(ctx)
    end
  end

  describe "Requirement: Look up an existing workspace" do
    test "Scenario: Workspace is found again", ctx do
      {:ok, ws} = Workspace.create(ctx.repo, "add-x", "2.1", ctx.opts)

      assert Workspace.fetch(ctx.repo, "add-x", "2.1", ctx.opts) == {:ok, ws}
      # From a subdirectory or from the workspace itself, it is the same workspace.
      assert Workspace.fetch(Path.join(ws.path, "."), "add-x", "2.1", ctx.opts) == {:ok, ws}
    end

    test "Scenario: Workspace does not exist", ctx do
      {:ok, _} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)

      assert Workspace.fetch(ctx.repo, "add-x", "2", ctx.opts) == {:error, :not_found}
      assert Workspace.fetch(ctx.repo, "add-y", "1", ctx.opts) == {:error, :not_found}
    end
  end

  describe "create/4 rollback" do
    test "removes the worktree and branch when writing the metadata fails", ctx do
      # A directory where the metadata file should go makes File.write/2 fail
      # after `git worktree add` has already succeeded.
      meta = Workspace.metadata_path(ctx.root, ctx.repo, "add-x", "1")
      File.mkdir_p!(meta)

      assert Workspace.create(ctx.repo, "add-x", "1", ctx.opts) == {:error, {:metadata, :eisdir}}

      refute File.exists?(Workspace.workspace_path(ctx.root, ctx.repo, "add-x", "1"))
      assert GitRepo.branches(ctx.repo) == ["main"]
      assert File.dir?(meta)
      assert Workspace.fetch(ctx.repo, "add-x", "1", ctx.opts) == {:error, :not_found}

      # Nothing is left that blocks a later attempt.
      File.rm_rf!(meta)
      assert {:ok, _} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)
    end
  end

  defp assert_nothing_created(ctx) do
    assert GitRepo.branches(ctx.repo) == ["main"]
    assert GitRepo.status(ctx.repo) == ""
    refute File.exists?(ctx.root)
  end
end
