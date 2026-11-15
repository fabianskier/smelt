defmodule Smelt.TaskRun.PromptNewTestsTest do
  use ExUnit.Case, async: true

  alias Smelt.TaskRun.Prompt

  describe "Requirement: Instruct the agent" do
    test "Scenario: Prompt says where new tests go" do
      prompt = Prompt.task("add-x", %{id: "1.1", description: "Do it"})

      assert prompt =~ "Put new tests in new test files."
      assert prompt =~ "Adding to an existing test file counts as modifying it"
    end
  end
end
