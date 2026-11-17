defmodule Smelt.Runner.ClaudeCodeUsageLimitTest do
  # Every run goes through the fake CLI in test/support/fake_claude.
  use ExUnit.Case, async: true

  alias Smelt.Runner
  alias Smelt.Runner.ClaudeCode
  alias Smelt.Runner.Event
  alias Smelt.Runner.Result

  @moduletag :tmp_dir

  @fixture Path.expand("../../support/fixtures/claude/usage_limit.jsonl", __DIR__)

  defp run(ctx, env, opts \\ []) do
    ClaudeCode.run("prompt", Keyword.merge([cwd: ctx.tmp_dir, env: env], opts))
  end

  describe "Requirement: Fail with a descriptive error" do
    test "Scenario: Usage limit reached", ctx do
      run_id = Runner.new_run_id()
      :ok = Runner.subscribe(run_id)

      env = [{"FAKE_CLAUDE_FIXTURE", @fixture}, {"FAKE_CLAUDE_EXIT", "1"}]

      assert {:error, {:usage_limit, %Result{text: text, cost_usd: cost}}} =
               run(ctx, env, run_id: run_id)

      assert text =~ "requires usage credits"
      assert cost == 0.91

      assert_receive {Runner, ^run_id, %Event{type: :finished, data: {:error, {:usage_limit, _}}}}
    end

    test "an error result with a 429 is a usage limit even without a rate-limit event", ctx do
      line =
        ~s({"type":"result","subtype":"success","is_error":true,"api_error_status":429,) <>
          ~s("result":"You've hit your limit","total_cost_usd":0.2,"num_turns":2})

      fixture = Path.join(ctx.tmp_dir, "limit.jsonl")
      File.write!(fixture, line <> "\n")

      assert {:error, {:usage_limit, %Result{text: "You've hit your limit"}}} =
               run(ctx, [{"FAKE_CLAUDE_FIXTURE", fixture}, {"FAKE_CLAUDE_EXIT", "1"}])
    end

    test "an error result without a usage limit keeps the exit status error", ctx do
      line =
        ~s({"type":"result","subtype":"error_during_execution","is_error":true,) <>
          ~s("result":"boom","total_cost_usd":0.1,"num_turns":1})

      fixture = Path.join(ctx.tmp_dir, "error.jsonl")
      File.write!(fixture, line <> "\n")

      assert {:error, {:exit_status, 1, _output}} =
               run(ctx, [{"FAKE_CLAUDE_FIXTURE", fixture}, {"FAKE_CLAUDE_EXIT", "1"}])
    end
  end
end
