defmodule Smelt.GitTest do
  use ExUnit.Case, async: true

  alias Smelt.Git
  alias Smelt.GitRepo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{repo: GitRepo.init!(tmp_dir)}
  end

  describe "cmd/2" do
    test "returns the output of a successful command", %{repo: repo} do
      assert Git.cmd(repo, ["rev-parse", "--is-inside-work-tree"]) == {:ok, "true\n"}
    end

    test "returns the args, exit status and output of a failing command", %{repo: repo} do
      args = ["rev-parse", "--verify", "no-such-ref"]

      assert {:error, {:git, ^args, 128, output}} = Git.cmd(repo, args)
      assert output =~ "fatal:"
    end

    test "runs in the given repository, not the current directory", %{repo: repo} do
      {:ok, toplevel} = Git.cmd(repo, ["rev-parse", "--show-toplevel"])

      assert String.trim(toplevel) == repo
    end

    test "sees the repository's commits and branches", %{repo: repo} do
      sha = GitRepo.commit!(repo, "add lib", %{"lib/a.ex" => "a"})
      :ok = GitRepo.branch!(repo, "feature")

      assert Git.cmd(repo, ["rev-parse", "feature"]) == {:ok, sha <> "\n"}
    end

    test "ignores the user's global git config", %{repo: repo} do
      assert {:error, {:git, _, 1, ""}} =
               Git.cmd(repo, ["config", "--global", "--get", "user.name"])
    end
  end
end
