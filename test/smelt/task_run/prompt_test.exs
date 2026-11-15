defmodule Smelt.TaskRun.PromptTest do
  use ExUnit.Case, async: true

  alias Smelt.Gate.Result
  alias Smelt.TaskRun.Prompt

  test "the task prompt names the change, the task and tasks.md" do
    prompt = Prompt.task("add-game-logic", %{id: "1.1", description: "Implement new/1"})

    assert prompt =~ ~s(task 1.1 of the OpenSpec change "add-game-logic")
    assert prompt =~ "Task 1.1: Implement new/1"
    assert prompt =~ "openspec/changes/add-game-logic/tasks.md"
    assert prompt =~ "Implement only task 1.1"
    assert prompt =~ "sh .smelt/checks.sh"
  end

  test "the retry prompt lists only the failed rules with their details" do
    result = %Result{
      status: :fail,
      duration_ms: 1,
      rules: [
        %{
          name: :protected_files,
          status: :fail,
          details: %{violations: [%{path: "test/a_test.exs", change: :modified}]}
        },
        %{
          name: :diff_size,
          status: :pass,
          details: %{
            changed_lines: 10,
            changed_files: 1,
            max_changed_lines: 400,
            max_changed_files: 20
          }
        },
        %{name: :openspec, status: :skipped, details: %{reason: :no_openspec_dir}},
        %{
          name: :checks,
          status: :fail,
          details: %{exit_status: 2, output: Enum.map_join(1..100, "\n", &"line #{&1}")}
        }
      ]
    }

    prompt = Prompt.retry(result)

    assert prompt =~ "- protected_files: you changed protected files: test/a_test.exs (modified)"
    assert prompt =~ "- checks: `sh .smelt/checks.sh` exited with status 2"
    assert prompt =~ "line 100"
    refute prompt =~ "line 60\n"
    refute prompt =~ "diff_size"
    refute prompt =~ "openspec"
  end

  test "the retry prompt explains a diff that is too large and a timeout" do
    result = %Result{
      status: :fail,
      duration_ms: 1,
      rules: [
        %{
          name: :diff_size,
          status: :fail,
          details: %{
            changed_lines: 500,
            changed_files: 3,
            max_changed_lines: 400,
            max_changed_files: 20
          }
        },
        %{name: :checks, status: :fail, details: %{reason: :timeout, output: "slow test"}}
      ]
    }

    prompt = Prompt.retry(result)

    assert prompt =~ "500 changed lines (maximum 400)"
    assert prompt =~ "- checks: it did not finish within the time limit"
    assert prompt =~ "slow test"
  end
end
