defmodule Smelt.GitRepoTest do
  use ExUnit.Case, async: true

  alias Smelt.GitRepo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{repo: GitRepo.init!(tmp_dir)}
  end

  test "init!/1 creates a clean repository on main", %{repo: repo} do
    assert GitRepo.current_branch(repo) == "main"
    assert GitRepo.status(repo) == ""
    assert File.read!(Path.join(repo, "README.md")) == "# Test repo\n"
  end

  test "commit!/3 commits files and returns the new HEAD", %{repo: repo} do
    before = GitRepo.sha!(repo, "HEAD")
    sha = GitRepo.commit!(repo, "add lib", %{"lib/a.ex" => "a"})

    assert sha != before
    assert sha == GitRepo.sha!(repo, "HEAD")
    assert GitRepo.status(repo) == ""
  end

  test "branch!/3 and checkout!/2 switch branches", %{repo: repo} do
    :ok = GitRepo.branch!(repo, "feature")
    :ok = GitRepo.checkout!(repo, "feature")

    assert GitRepo.current_branch(repo) == "feature"
    assert GitRepo.sha!(repo, "feature") == GitRepo.sha!(repo, "main")
  end

  test "write!/3 leaves modified and untracked files", %{repo: repo} do
    :ok = GitRepo.write!(repo, "README.md", "changed\n")
    :ok = GitRepo.write!(repo, "notes/todo.txt", "todo\n")

    assert GitRepo.status(repo) == " M README.md\n?? notes/\n"
  end

  test "failing git commands raise with git's output", %{repo: repo} do
    assert_raise RuntimeError, ~r/git checkout .* exited with/, fn ->
      GitRepo.checkout!(repo, "no-such-branch")
    end
  end
end
