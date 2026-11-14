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

  describe "Requirement: List managed workspaces" do
    test "Scenario: Only managed workspaces are listed", ctx do
      {:ok, ws1} = Workspace.create(ctx.repo, "add-x", "2.1", ctx.opts)
      {:ok, ws2} = Workspace.create(ctx.repo, "add-x", "10", ctx.opts)

      # A worktree the user created by hand, and a look-alike branch with no
      # metadata: neither belongs to Smelt.
      :ok = GitRepo.add_worktree!(ctx.repo, Path.join(ctx.tmp_dir, "mine"), "mine")
      :ok = GitRepo.add_worktree!(ctx.repo, Path.join(ctx.tmp_dir, "fake"), "smelt/add-x/3")

      assert Workspace.list(ctx.repo, ctx.opts) == {:ok, [ws1, ws2]}
    end

    test "a repository without workspaces has an empty list", ctx do
      assert Workspace.list(ctx.repo, ctx.opts) == {:ok, []}
    end
  end

  describe "Requirement: Remove a workspace" do
    test "Scenario: Workspace without new commits is removed", ctx do
      {:ok, ws} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)
      # Uncommitted and untracked files don't block removal.
      :ok = GitRepo.write!(ws.path, "README.md", "changed\n")
      :ok = GitRepo.write!(ws.path, "_build/out.txt", "build output\n")

      assert Workspace.remove(ctx.repo, "add-x", "1", ctx.opts) == {:ok, :removed}

      refute File.exists?(ws.path)
      refute File.exists?(Workspace.metadata_path(ctx.root, ctx.repo, "add-x", "1"))
      assert GitRepo.branches(ctx.repo) == ["main"]
      assert Workspace.list(ctx.repo, ctx.opts) == {:ok, []}
    end

    test "Scenario: Unmerged branch is kept", ctx do
      {:ok, ws} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)
      work_sha = GitRepo.commit!(ws.path, "task work", %{"lib/x.ex" => "x"})

      assert Workspace.remove(ctx.repo, "add-x", "1", ctx.opts) == {:ok, :branch_kept}

      refute File.exists?(ws.path)
      assert GitRepo.sha!(ctx.repo, ws.branch) == work_sha
      assert Workspace.list(ctx.repo, ctx.opts) == {:ok, []}
      # The kept branch still blocks re-creating the task.
      assert Workspace.create(ctx.repo, "add-x", "1", ctx.opts) == {:error, :already_exists}
    end

    test "Scenario: Forced removal deletes an unmerged branch", ctx do
      {:ok, ws} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)
      _ = GitRepo.commit!(ws.path, "task work", %{"lib/x.ex" => "x"})

      assert Workspace.remove(ctx.repo, "add-x", "1", Keyword.put(ctx.opts, :force, true)) ==
               {:ok, :removed}

      refute File.exists?(ws.path)
      assert GitRepo.branches(ctx.repo) == ["main"]
    end

    test "Scenario: Removing a missing workspace", ctx do
      {:ok, other} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)

      assert Workspace.remove(ctx.repo, "add-x", "2", ctx.opts) == {:ok, :absent}

      assert Workspace.list(ctx.repo, ctx.opts) == {:ok, [other]}
      assert GitRepo.branches(ctx.repo) == ["main", other.branch]
    end

    test "a branch merged into the base after its work is deleted", ctx do
      {:ok, ws} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)
      _ = GitRepo.commit!(ws.path, "task work", %{"lib/x.ex" => "x"})
      :ok = GitRepo.merge!(ctx.repo, ws.branch)

      assert Workspace.remove(ctx.repo, "add-x", "1", ctx.opts) == {:ok, :removed}
      assert GitRepo.branches(ctx.repo) == ["main"]
    end

    test "a workspace whose directory was deleted by hand is cleaned up", ctx do
      {:ok, ws} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)
      File.rm_rf!(ws.path)

      assert Workspace.remove(ctx.repo, "add-x", "1", ctx.opts) == {:ok, :removed}

      assert GitRepo.branches(ctx.repo) == ["main"]
      refute GitRepo.worktree_paths(ctx.repo) |> Enum.any?(&String.ends_with?(&1, "/add-x/1"))
      assert {:ok, _} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)
    end
  end

  describe "Requirement: Leave the user's checkout untouched" do
    test "Scenario: Checkout with uncommitted work is preserved", ctx do
      :ok = GitRepo.branch!(ctx.repo, "wip")
      :ok = GitRepo.checkout!(ctx.repo, "wip")
      :ok = GitRepo.write!(ctx.repo, "README.md", "my local edit\n")
      :ok = GitRepo.write!(ctx.repo, "scratch/notes.txt", "untracked\n")
      status = GitRepo.status(ctx.repo)
      head = GitRepo.sha!(ctx.repo, "HEAD")

      {:ok, ws} = Workspace.create(ctx.repo, "add-x", "1", ctx.opts)
      _ = GitRepo.commit!(ws.path, "task work", %{"lib/x.ex" => "x"})
      {:ok, :branch_kept} = Workspace.remove(ctx.repo, "add-x", "1", ctx.opts)

      assert GitRepo.current_branch(ctx.repo) == "wip"
      assert GitRepo.sha!(ctx.repo, "HEAD") == head
      assert GitRepo.status(ctx.repo) == status
      assert status == " M README.md\n?? scratch/\n"
      assert File.read!(Path.join(ctx.repo, "README.md")) == "my local edit\n"
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
