defmodule Smelt.Gate.UncountedPathsTest do
  use ExUnit.Case, async: true

  alias Smelt.Gate.Changes
  alias Smelt.Gate.Config
  alias Smelt.Gate.Rules
  alias Smelt.GitRepo
  alias Smelt.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo = GitRepo.gate_project!(Path.join(tmp_dir, "repo"))
    {:ok, ws} = Workspace.create(repo, "add-x", "1", root: Path.join(tmp_dir, "ws"))
    %{ws: ws}
  end

  defp diff_size(ws, config) do
    {:ok, changes} = Changes.measure(ws)
    Rules.diff_size(changes, config)
  end

  describe "uncounted paths" do
    test "generated files are left out of the line and file counts", %{ws: ws} do
      :ok = GitRepo.write!(ws.path, "lib/small.ex", "x\n")
      :ok = GitRepo.write!(ws.path, "frontend/src/routeTree.gen.ts", String.duplicate("r\n", 50))

      assert %{status: :fail, details: %{changed_lines: 51, changed_files: 2}} =
               diff_size(ws, %Config{max_changed_lines: 10})

      assert %{status: :pass, details: %{changed_lines: 1, changed_files: 1}} =
               diff_size(ws, %Config{
                 max_changed_lines: 10,
                 uncounted_paths: ["frontend/src/routeTree.gen.ts"]
               })
    end

    test "paths match by prefix", %{ws: ws} do
      :ok = GitRepo.write!(ws.path, "gen/a.ts", String.duplicate("a\n", 20))

      assert %{status: :pass, details: %{changed_lines: 0, changed_files: 0}} =
               diff_size(ws, %Config{max_changed_lines: 10, uncounted_paths: ["gen/"]})
    end

    test "the setting is parsed and validated" do
      assert {:ok, %Config{uncounted_paths: ["a/", "b.lock"]}} =
               Config.parse(~s({"uncounted_paths": ["a/", "b.lock"]}))

      assert {:ok, %Config{uncounted_paths: []}} = Config.parse(~s({"uncounted_paths": []}))

      assert {:error, {:invalid_config, message}} = Config.parse(~s({"uncounted_paths": [""]}))
      assert message =~ "uncounted_paths"
    end
  end
end
