defmodule Smelt.TaskRun.Prompt do
  @moduledoc """
  The prompts Smelt gives the agent: one to implement a task, and one to fix
  the gate's findings when resuming the same session.
  """

  alias Smelt.Gate.Result
  alias Smelt.TaskRun.TaskList

  @output_lines 40

  @doc "The prompt for implementing `task` of `change`."
  @spec task(String.t(), TaskList.task()) :: String.t()
  def task(change, %{id: id, description: description}) do
    dir = "openspec/changes/#{change}"

    """
    You are implementing task #{id} of the OpenSpec change "#{change}" in this repository.

    Task #{id}: #{description}

    Read #{dir}/proposal.md, #{dir}/design.md (if present), the specs under #{dir}/specs/ and #{TaskList.path(change)} before you start.

    Rules:
    - Implement only task #{id}. Do not start other tasks.
    - Do not modify or delete existing tests, and do not change anything under .smelt/.
    - When done, mark task #{id} as done in #{TaskList.path(change)}.
    - Run `sh .smelt/checks.sh` and fix every failure until it passes.
    - Commit your work with a Conventional Commit message.
    """
  end

  @doc """
  The prompt for fixing a failed gate, listing each failed rule with its
  details. Passed and skipped rules are left out.
  """
  @spec retry(Result.t()) :: String.t()
  def retry(%Result{rules: rules}) do
    findings =
      for %{status: :fail} = rule <- rules do
        "- #{rule.name}: #{finding(rule.name, rule.details)}"
      end

    """
    Smelt's gate rejected your work. Failed rules:

    #{Enum.join(findings, "\n\n")}

    Fix every failed rule without breaking the rules you were given, run `sh .smelt/checks.sh` until it passes, and commit your work.
    """
  end

  defp finding(:protected_files, %{violations: violations}) do
    paths = Enum.map_join(violations, ", ", &"#{&1.path} (#{&1.change})")

    "you changed protected files: #{paths}. Restore them exactly as they were; add new test files instead of changing existing ones."
  end

  defp finding(:diff_size, details) do
    "the change has #{details.changed_lines} changed lines (maximum #{details.max_changed_lines}) " <>
      "in #{details.changed_files} files (maximum #{details.max_changed_files}). Make it smaller."
  end

  defp finding(_rule, %{reason: :timeout} = details) do
    "it did not finish within the time limit. Last output:\n#{tail(details[:output])}"
  end

  defp finding(:checks, %{reason: :missing_script}) do
    "the project has no .smelt/checks.sh. This can't be fixed in the task; stop."
  end

  defp finding(:openspec, %{reason: :openspec_not_found}) do
    "the OpenSpec CLI is not installed. This can't be fixed in the task; stop."
  end

  defp finding(:checks, details) do
    "`sh .smelt/checks.sh` exited with status #{details.exit_status}. Last output:\n#{tail(details.output)}"
  end

  defp finding(:openspec, details) do
    "`openspec validate --all --strict` failed:\n#{tail(details.output)}"
  end

  defp finding(_rule, details), do: inspect(details)

  defp tail(nil), do: "(none)"

  defp tail(output) do
    output
    |> String.split("\n")
    |> Enum.take(-@output_lines)
    |> Enum.map_join("\n", &("    " <> &1))
  end
end
