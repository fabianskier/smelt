defmodule Smelt.GateTest do
  use ExUnit.Case, async: true

  alias Smelt.Gate
  alias Smelt.Gate.Command
  alias Smelt.Gate.Config
  alias Smelt.Gate.Result
  alias Smelt.GitRepo
  alias Smelt.Workspace

  @moduletag :tmp_dir

  @valid_spec """
  # demo Specification

  ## Purpose
  Demo capability used to check that OpenSpec validation passes in tests.

  ## Requirements

  ### Requirement: Demo works
  The system SHALL work.

  #### Scenario: It works
  - **WHEN** used
  - **THEN** it works
  """

  # Same requirement without a scenario: strict validation rejects it.
  @invalid_spec """
  # demo Specification

  ## Purpose
  Demo capability used to check that OpenSpec validation fails in tests.

  ## Requirements

  ### Requirement: Demo works
  The system SHALL work.
  """

  # Creates a gated project and a workspace for task 1 of `add-x`.
  defp workspace(tmp_dir, project_opts \\ []) do
    repo = GitRepo.gate_project!(Path.join(tmp_dir, "repo"), project_opts)
    {:ok, ws} = Workspace.create(repo, "add-x", "1", root: Path.join(tmp_dir, "ws"))
    ws
  end

  defp statuses(%Result{rules: rules}), do: Enum.map(rules, &{&1.name, &1.status})

  describe "Requirement: Report a result per rule" do
    test "Scenario: Every rule passes", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir, checks: "echo checks ran\n")
      :ok = GitRepo.write!(ws.path, "lib/app.ex", "code\n")

      assert {:ok, %Result{status: :pass} = result} = Gate.run(ws)

      assert statuses(result) == [
               protected_files: :pass,
               diff_size: :pass,
               openspec: :skipped,
               checks: :pass
             ]

      assert Result.rule(result, :checks).details == %{exit_status: 0, output: "checks ran\n"}
      assert result.duration_ms >= 0
    end

    test "Scenario: One rule fails", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir, gate: %{"max_changed_files" => 1})
      for i <- 1..2, do: :ok = GitRepo.write!(ws.path, "lib/f#{i}.ex", "x\n")

      assert {:ok, %Result{status: :fail} = result} = Gate.run(ws)

      assert statuses(result) == [
               protected_files: :pass,
               diff_size: :fail,
               openspec: :skipped,
               checks: :skipped
             ]

      assert %{changed_files: 2, max_changed_files: 1} = Result.rule(result, :diff_size).details
    end
  end

  describe "Requirement: Validate OpenSpec artifacts" do
    test "Scenario: Invalid OpenSpec artifacts", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir, files: %{"openspec/specs/demo/spec.md" => @valid_spec})
      assert {:ok, %Result{status: :pass} = result} = Gate.run(ws)
      assert %{status: :pass} = Result.rule(result, :openspec)

      :ok = GitRepo.write!(ws.path, "openspec/specs/demo/spec.md", @invalid_spec)

      assert {:ok, %Result{status: :fail} = result} = Gate.run(ws)
      assert %{status: :fail, details: %{output: output}} = Result.rule(result, :openspec)
      assert output =~ "Requirement must have at least one scenario"
      assert %{status: :skipped} = Result.rule(result, :checks)
    end

    test "Scenario: Project without OpenSpec", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir)

      assert {:ok, result} = Gate.run(ws)

      assert Result.rule(result, :openspec) == %{
               name: :openspec,
               status: :skipped,
               details: %{reason: :no_openspec_dir}
             }
    end

    test "a project with OpenSpec fails when the CLI is missing", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir, files: %{"openspec/specs/demo/spec.md" => @valid_spec})

      assert {:ok, %Result{status: :fail} = result} = Gate.run(ws, openspec: "no-such-openspec")

      assert %{status: :fail, details: %{reason: :openspec_not_found}} =
               Result.rule(result, :openspec)
    end
  end

  describe "Requirement: Run the project's checks from the base commit" do
    test "Scenario: Checks pass", %{tmp_dir: tmp_dir} do
      # The script runs in the workspace and sees the task's files.
      ws = workspace(tmp_dir, checks: "test -f lib/app.ex\n")
      :ok = GitRepo.write!(ws.path, "lib/app.ex", "code\n")

      assert {:ok, %Result{status: :pass} = result} = Gate.run(ws)
      assert %{status: :pass, details: %{exit_status: 0}} = Result.rule(result, :checks)
    end

    test "Scenario: Checks fail", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir, checks: "echo '1 test, 1 failure'\nexit 3\n")

      assert {:ok, %Result{status: :fail} = result} = Gate.run(ws)

      assert Result.rule(result, :checks) == %{
               name: :checks,
               status: :fail,
               details: %{exit_status: 3, output: "1 test, 1 failure\n"}
             }
    end

    test "Scenario: The workspace's copy of the script is ignored", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir, checks: "echo base script\nexit 1\n")
      :ok = GitRepo.write!(ws.path, ".smelt/checks.sh", "echo workspace script\nexit 0\n")

      assert {:ok, %Result{status: :fail} = result} = Gate.run(ws)

      assert %{status: :fail, details: %{violations: [%{path: ".smelt/checks.sh"}]}} =
               Result.rule(result, :protected_files)

      assert %{status: :fail, details: %{exit_status: 1, output: "base script\n"}} =
               Gate.checks(ws, %Config{})
    end

    test "Scenario: No checks script", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir, checks: nil)

      assert {:ok, %Result{status: :fail} = result} = Gate.run(ws)

      assert Result.rule(result, :checks) == %{
               name: :checks,
               status: :fail,
               details: %{reason: :missing_script}
             }
    end
  end

  describe "Requirement: Stop checks that run too long" do
    test "Scenario: Checks exceed the timeout", %{tmp_dir: tmp_dir} do
      pids = Path.join(tmp_dir, "pids")
      File.mkdir_p!(pids)

      ws =
        workspace(tmp_dir,
          gate: %{"timeout_seconds" => 1},
          checks: """
          sleep 30 &
          echo $! > #{pids}/child
          echo $$ > #{pids}/script
          echo started
          wait
          """
        )

      assert {:ok, %Result{status: :fail} = result} = Gate.run(ws)

      assert Result.rule(result, :checks) == %{
               name: :checks,
               status: :fail,
               details: %{reason: :timeout, output: "started\n"}
             }

      for name <- ["child", "script"] do
        pid = pids |> Path.join(name) |> File.read!() |> String.trim() |> String.to_integer()
        refute Command.alive?(pid), "#{name} (#{pid}) is still running"
      end
    end
  end

  describe "Requirement: Skip checks after a cheaper rule fails" do
    test "Scenario: Protected test modified", %{tmp_dir: tmp_dir} do
      marker = Path.join(tmp_dir, "checks-ran")
      ws = workspace(tmp_dir, checks: "touch #{marker}\n")
      :ok = GitRepo.write!(ws.path, "test/app_test.exs", "weakened\n")

      assert {:ok, %Result{status: :fail} = result} = Gate.run(ws)

      assert Result.rule(result, :checks) == %{
               name: :checks,
               status: :skipped,
               details: %{reason: :earlier_rule_failed}
             }

      refute File.exists?(marker)
    end
  end

  describe "Requirement: Configure the gate per project" do
    test "Scenario: Settings from the base commit", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir, gate: %{"max_changed_lines" => 2})
      :ok = GitRepo.write!(ws.path, ".smelt/gate.json", ~s({"max_changed_lines": 9999}))
      :ok = GitRepo.write!(ws.path, "lib/app.ex", "a\nb\nc\n")

      assert {:ok, %Result{status: :fail} = result} = Gate.run(ws)
      assert %{status: :fail, details: %{max_changed_lines: 2}} = Result.rule(result, :diff_size)
    end

    test "Scenario: Invalid configuration", %{tmp_dir: tmp_dir} do
      ws = workspace(tmp_dir, files: %{".smelt/gate.json" => ~s({"max_lines": 1})})

      assert Gate.run(ws) == {:error, {:invalid_config, ~s(unknown setting "max_lines")}}
    end
  end

  test "a missing workspace directory is an error", %{tmp_dir: tmp_dir} do
    ws = workspace(tmp_dir)
    File.rm_rf!(ws.path)

    assert Gate.run(ws) == {:error, :workspace_missing}
  end
end
