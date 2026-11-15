defmodule Smelt.TaskRun.TaskListTest do
  use ExUnit.Case, async: true

  alias Smelt.GitRepo
  alias Smelt.TaskRun.TaskList

  doctest TaskList

  @moduletag :tmp_dir

  @tasks """
  # Tasks

  ## 1. Setup

  - [ ] 1.1 Create the module and verify it compiles
  - [x] 1.2 Already finished
  - [ X ] 1.3 Finished with spaces
  - [~] 1.4 Marked in progress
  - [ ] 1.10 The tenth task

  ## Workflow follow-up

  - Archive the change.
  """

  setup %{tmp_dir: tmp_dir} do
    repo = GitRepo.init!(tmp_dir)
    sha = GitRepo.commit!(repo, "tasks", %{TaskList.path("add-x") => @tasks})
    %{repo: repo, sha: sha}
  end

  test "an open task", %{repo: repo, sha: sha} do
    assert TaskList.fetch(repo, sha, "add-x", "1.1") ==
             {:ok, %{id: "1.1", description: "Create the module and verify it compiles"}}
  end

  test "a done task", %{repo: repo, sha: sha} do
    assert TaskList.fetch(repo, sha, "add-x", "1.2") == {:error, :task_done}
    assert TaskList.fetch(repo, sha, "add-x", "1.3") == {:error, :task_done}
  end

  test "any other marker is unfinished", %{repo: repo, sha: sha} do
    assert {:ok, %{id: "1.4"}} = TaskList.fetch(repo, sha, "add-x", "1.4")
  end

  test "an id is matched exactly, not as a prefix", %{repo: repo, sha: sha} do
    assert {:ok, %{description: "The tenth task"}} = TaskList.fetch(repo, sha, "add-x", "1.10")
    assert TaskList.fetch(repo, sha, "add-x", "1") == {:error, :task_not_found}
  end

  test "a missing task", %{repo: repo, sha: sha} do
    assert TaskList.fetch(repo, sha, "add-x", "9.9") == {:error, :task_not_found}
  end

  test "a missing change", %{repo: repo, sha: sha} do
    assert TaskList.fetch(repo, sha, "add-y", "1.1") == {:error, :change_not_found}
  end

  test "the task is read at the given commit", %{repo: repo, sha: sha} do
    _ = GitRepo.commit!(repo, "done", %{TaskList.path("add-x") => "- [x] 1.1 Create\n"})

    assert {:ok, _} = TaskList.fetch(repo, sha, "add-x", "1.1")
    assert TaskList.fetch(repo, "HEAD", "add-x", "1.1") == {:error, :task_done}
  end
end
