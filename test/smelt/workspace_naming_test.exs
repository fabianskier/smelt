defmodule Smelt.WorkspaceNamingTest do
  use ExUnit.Case, async: true

  alias Smelt.Workspace

  doctest Smelt.Workspace, only: [validate_identifiers: 2, branch_name: 2]

  describe "validate_identifiers/2" do
    test "accepts kebab-case change names" do
      for change <- ["add-patients", "fix", "add-v2-api", "main"] do
        assert Workspace.validate_identifiers(change, "1") == :ok, change
      end
    end

    test "rejects change names that are not kebab-case" do
      for change <- ["../escape", "a/b", "Add_X", "add_x", "-add", "add-", "add--x", "", "a b"] do
        assert Workspace.validate_identifiers(change, "1") ==
                 {:error, {:invalid_identifier, :change}},
               inspect(change)
      end
    end

    test "accepts dot-separated numeric task ids" do
      for task_id <- ["1", "2.1", "10.2.3"] do
        assert Workspace.validate_identifiers("add-x", task_id) == :ok, task_id
      end
    end

    test "rejects malformed task ids" do
      for task_id <- ["1..2", "main", "2.", ".2", "../1", "1/2", "", "2.1\n"] do
        assert Workspace.validate_identifiers("add-x", task_id) ==
                 {:error, {:invalid_identifier, :task_id}},
               inspect(task_id)
      end
    end

    test "rejects values that are not strings" do
      assert Workspace.validate_identifiers(:add_x, "1") ==
               {:error, {:invalid_identifier, :change}}

      assert Workspace.validate_identifiers("add-x", 2.1) ==
               {:error, {:invalid_identifier, :task_id}}
    end
  end

  describe "paths" do
    @root "/data/worktrees"
    @repo "/code/shop"

    test "the workspace lives under <root>/<repo-name>-<hash>/<change>/<task-id>" do
      path = Workspace.workspace_path(@root, @repo, "add-x", "2.1")

      assert [_, "data", "worktrees", repo_dir, "add-x", "2.1"] = Path.split(path)
      assert repo_dir =~ ~r/\Ashop-[0-9a-f]{8}\z/
    end

    test "the metadata file is a sibling of the workspace directory" do
      assert Workspace.metadata_path(@root, @repo, "add-x", "2.1") ==
               Workspace.workspace_path(@root, @repo, "add-x", "2.1") <> ".json"
    end

    test "the same repository always maps to the same paths" do
      assert Workspace.workspace_path(@root, @repo, "add-x", "2.1") ==
               Workspace.workspace_path(@root, @repo, "add-x", "2.1")
    end

    test "two repositories with the same name get different directories" do
      refute Workspace.repo_dir(@root, "/code/shop") == Workspace.repo_dir(@root, "/old/shop")
    end

    test "a relative root is expanded" do
      assert Workspace.repo_dir("worktrees", @repo) |> Path.type() == :absolute
    end
  end

  describe "default_root/0" do
    test "is under the user's data directory" do
      assert Workspace.default_root() |> String.ends_with?("/smelt/worktrees")
      assert Workspace.default_root() |> Path.type() == :absolute
    end
  end
end
