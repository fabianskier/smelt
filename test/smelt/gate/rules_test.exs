defmodule Smelt.Gate.RulesTest do
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

  defp protected(ws, config \\ %Config{}) do
    {:ok, changes} = Changes.measure(ws)
    Rules.protected_files(changes, config)
  end

  defp diff_size(ws, config) do
    {:ok, changes} = Changes.measure(ws)
    Rules.diff_size(changes, config)
  end

  describe "Requirement: Protect existing tests and gate configuration" do
    test "Scenario: An existing test is modified", %{ws: ws} do
      :ok = GitRepo.write!(ws.path, "test/app_test.exs", "test 1 weakened\n")

      assert %{
               status: :fail,
               details: %{violations: [%{path: "test/app_test.exs", change: :modified}]}
             } =
               protected(ws)
    end

    test "Scenario: An existing test is deleted", %{ws: ws} do
      _ = GitRepo.git!(ws.path, ["rm", "--quiet", "test/app_test.exs"])

      assert %{
               status: :fail,
               details: %{violations: [%{path: "test/app_test.exs", change: :deleted}]}
             } =
               protected(ws)
    end

    test "Scenario: A new test is added", %{ws: ws} do
      _ = GitRepo.commit!(ws.path, "new test", %{"test/new_test.exs" => "test 2\n"})
      :ok = GitRepo.write!(ws.path, "lib/app.ex", "code\n")

      assert %{status: :pass, details: %{violations: []}} = protected(ws)
    end

    test "Scenario: Gate configuration is changed", %{ws: ws} do
      :ok = GitRepo.write!(ws.path, ".smelt/checks.sh", "exit 0 # always\n")
      :ok = GitRepo.write!(ws.path, ".smelt/gate.json", ~s({"max_changed_lines": 9999}))

      assert %{status: :fail, details: %{violations: violations}} = protected(ws)

      assert violations == [
               %{path: ".smelt/checks.sh", change: :modified},
               %{path: ".smelt/gate.json", change: :added}
             ]
    end

    test "a renamed existing test is reported as deleted", %{ws: ws} do
      File.rename!(Path.join(ws.path, "test/app_test.exs"), Path.join(ws.path, "test/b_test.exs"))

      assert %{
               status: :fail,
               details: %{violations: [%{path: "test/app_test.exs", change: :deleted}]}
             } =
               protected(ws)
    end

    test "test paths come from the configuration and match by prefix", %{ws: ws} do
      :ok = GitRepo.write!(ws.path, "test/app_test.exs", "changed\n")

      assert %{status: :pass} = protected(ws, %Config{test_paths: ["spec/"]})
    end
  end

  describe "Requirement: Limit the size of a change" do
    test "Scenario: Too many changed lines", %{ws: ws} do
      :ok = GitRepo.write!(ws.path, "lib/big.ex", String.duplicate("line\n", 11))

      assert %{
               status: :fail,
               details: %{changed_lines: 11, max_changed_lines: 10, changed_files: 1}
             } = diff_size(ws, %Config{max_changed_lines: 10})

      assert %{status: :pass} = diff_size(ws, %Config{max_changed_lines: 11})
    end

    test "Scenario: Too many changed files", %{ws: ws} do
      for i <- 1..3, do: :ok = GitRepo.write!(ws.path, "lib/f#{i}.ex", "x\n")

      assert %{
               status: :fail,
               details: %{changed_files: 3, max_changed_files: 2, changed_lines: 3}
             } = diff_size(ws, %Config{max_changed_files: 2})

      assert %{status: :pass} = diff_size(ws, %Config{max_changed_files: 3})
    end
  end
end
