defmodule Smelt.TaskRun.PromptVerificationTest do
  use ExUnit.Case, async: true

  alias Smelt.TaskRun.Prompt

  describe "Requirement: Keep the agent's verification short" do
    setup do
      %{prompt: Prompt.task("add-x", %{id: "1.1", description: "Do it"})}
    end

    test "Scenario: Prompt limits check runs", %{prompt: prompt} do
      assert prompt =~ "run only the tests you touched"
      assert prompt =~ "run `sh .smelt/checks.sh` once"
      assert prompt =~ "Run it again only after fixing a failure"
      assert prompt =~ "Do not run other full-suite commands"
      assert prompt =~ "Smelt's gate runs the checks and the OpenSpec validation"
    end

    test "Scenario: Prompt says not to retry denied commands", %{prompt: prompt} do
      assert prompt =~ "If a command is denied, do not retry it or work around it"
      assert prompt =~ "say so in your final message"
    end
  end
end
