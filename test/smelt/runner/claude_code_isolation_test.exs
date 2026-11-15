defmodule Smelt.Runner.ClaudeCodeIsolationTest do
  # The environment scenarios change Smelt's own (global) OS environment.
  use ExUnit.Case, async: false

  alias Smelt.Runner.ClaudeCode

  doctest ClaudeCode, only: [isolated_env: 1]

  @moduletag :tmp_dir

  @fake_agent Path.expand("../../support/fake_agent", __DIR__)

  # Runs the fake agent in `tmp_dir`, writing its environment to
  # `tmp_dir/env`, and returns its arguments and environment.
  defp run_fake(tmp_dir, opts \\ []) do
    log_dir = Path.join(tmp_dir, "log")
    File.mkdir_p!(log_dir)

    env = [
      {"FAKE_AGENT_LOG_DIR", log_dir},
      {"FAKE_AGENT_FIRST", ~s(env > "#{tmp_dir}/env")} | Keyword.get(opts, :env, [])
    ]

    {:ok, _} =
      ClaudeCode.run("Do the task",
        cwd: tmp_dir,
        executable: @fake_agent,
        env: env,
        args: Keyword.get(opts, :args, [])
      )

    args = log_dir |> Path.join("call-1") |> File.read!() |> String.split("\0", trim: true)

    agent_env =
      tmp_dir
      |> Path.join("env")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(&List.to_tuple(String.split(&1, "=", parts: 2)))

    {args, agent_env}
  end

  defp with_env(vars, fun) do
    previous = for {name, _} <- vars, do: {name, System.get_env(name)}
    System.put_env(vars)

    try do
      fun.()
    after
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end
  end

  describe "Requirement: Isolate the agent from the user's setup" do
    test "Scenario: Only project settings are loaded", %{tmp_dir: tmp_dir} do
      {args, _env} = run_fake(tmp_dir, args: ["--model", "fake"])

      assert ["--setting-sources", "project,local" | _] =
               Enum.drop_while(args, &(&1 != "--setting-sources"))

      # The caller's arguments still follow.
      assert "--model" in args
    end
  end

  describe "Requirement: Do not pass the launching session's environment" do
    test "Scenario: Parent session variables are removed", %{tmp_dir: tmp_dir} do
      vars = %{
        "CLAUDECODE" => "1",
        "CLAUDE_CODE_SESSION_ID" => "parent-session",
        "AI_AGENT" => "claude-code",
        "REX_SESSION" => "session:parent",
        "ANTHROPIC_BASE_URL" => "https://example.invalid"
      }

      {_args, env} = with_env(vars, fn -> run_fake(tmp_dir) end)

      for name <- ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "AI_AGENT", "REX_SESSION"] do
        refute Map.has_key?(env, name), "#{name} reached the agent"
      end

      assert env["ANTHROPIC_BASE_URL"] == "https://example.invalid"
      assert env["PATH"] == System.get_env("PATH")
    end

    test "Scenario: Caller variables still apply", %{tmp_dir: tmp_dir} do
      {_args, env} =
        with_env(%{"CLAUDE_CODE_MAX_OUTPUT_TOKENS" => "1"}, fn ->
          run_fake(tmp_dir, env: [{"CLAUDE_CODE_MAX_OUTPUT_TOKENS", "4096"}])
        end)

      assert env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] == "4096"
    end
  end

  describe "isolated_env/1" do
    test "removes the parent session's and terminal integration's variables" do
      env = %{
        "CLAUDECODE" => "1",
        "CLAUDE_CODE_MESSAGING_SOCKET" => "/tmp/sock",
        "CLAUDE_EFFORT" => "high",
        "AI_AGENT" => "x",
        "REX_BLOCK" => "block:1",
        "PATH" => "/bin",
        "HOME" => "/home/me",
        "ANTHROPIC_API_KEY" => "sk-test",
        "MIX_ENV" => "test",
        "NOT_CLAUDE_X" => "kept"
      }

      assert env |> ClaudeCode.isolated_env() |> Enum.sort() == [
               {"AI_AGENT", false},
               {"CLAUDECODE", false},
               {"CLAUDE_CODE_MESSAGING_SOCKET", false},
               {"CLAUDE_EFFORT", false},
               {"REX_BLOCK", false}
             ]
    end

    test "an environment without such variables removes nothing" do
      assert ClaudeCode.isolated_env(%{"PATH" => "/bin"}) == []
    end
  end
end
