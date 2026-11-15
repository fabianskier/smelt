defmodule Smelt.Gate.ChangesTest do
  use ExUnit.Case, async: true

  alias Smelt.Gate.Changes
  alias Smelt.GitRepo
  alias Smelt.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo = GitRepo.gate_project!(Path.join(tmp_dir, "repo"))
    {:ok, ws} = Workspace.create(repo, "add-x", "1", root: Path.join(tmp_dir, "ws"))
    index_dir = Path.join(tmp_dir, "index")
    File.mkdir_p!(index_dir)

    %{ws: ws, opts: [tmp_dir: index_dir], index_dir: index_dir}
  end

  describe "Requirement: Measure changes against the base commit" do
    test "Scenario: Uncommitted and untracked work is measured", %{ws: ws, opts: opts} do
      _ = GitRepo.commit!(ws.path, "work", %{"lib/a.ex" => "a\nb\n"})
      :ok = GitRepo.write!(ws.path, "README.md", "# Test repo\nmore\n")
      :ok = GitRepo.write!(ws.path, "lib/new.ex", "new\n")

      assert Changes.measure(ws, opts) ==
               {:ok,
                [
                  %{path: "README.md", change: :modified, added: 1, deleted: 0},
                  %{path: "lib/a.ex", change: :added, added: 2, deleted: 0},
                  %{path: "lib/new.ex", change: :added, added: 1, deleted: 0}
                ]}
    end

    test "Scenario: Ignored files are not measured", %{ws: ws, opts: opts} do
      :ok = GitRepo.write!(ws.path, "_build/dev/out.beam", "binary")

      assert Changes.measure(ws, opts) == {:ok, []}
    end

    test "Scenario: The workspace is left as it was", %{ws: ws, opts: opts} = ctx do
      :ok = GitRepo.write!(ws.path, "staged.txt", "staged\n")
      GitRepo.git!(ws.path, ["add", "staged.txt"])
      :ok = GitRepo.write!(ws.path, "README.md", "unstaged\n")
      :ok = GitRepo.write!(ws.path, "untracked.txt", "untracked\n")

      before =
        {GitRepo.current_branch(ws.path), GitRepo.sha!(ws.path, "HEAD"), GitRepo.status(ws.path)}

      assert {:ok, [_, _, _]} = Changes.measure(ws, opts)

      after_ =
        {GitRepo.current_branch(ws.path), GitRepo.sha!(ws.path, "HEAD"), GitRepo.status(ws.path)}

      assert after_ == before
      assert elem(before, 2) == " M README.md\nA  staged.txt\n?? untracked.txt\n"
      assert File.ls!(ctx.index_dir) == []
    end
  end

  test "deletions and binary files", %{ws: ws, opts: opts} do
    File.rm!(Path.join(ws.path, "test/app_test.exs"))
    :ok = GitRepo.write!(ws.path, "logo.png", <<0, 1, 2, 0, 255>>)

    assert Changes.measure(ws, opts) ==
             {:ok,
              [
                %{path: "logo.png", change: :added, added: 0, deleted: 0},
                %{path: "test/app_test.exs", change: :deleted, added: 0, deleted: 1}
              ]}
  end

  test "a rename is a deletion plus an addition", %{ws: ws, opts: opts} do
    File.rename!(Path.join(ws.path, "test/app_test.exs"), Path.join(ws.path, "test/b_test.exs"))

    assert {:ok, changes} = Changes.measure(ws, opts)

    assert Enum.map(changes, &{&1.path, &1.change}) ==
             [{"test/app_test.exs", :deleted}, {"test/b_test.exs", :added}]
  end
end
