defmodule Smelt.Gate.ConfigTest do
  use ExUnit.Case, async: true

  alias Smelt.Gate.Config
  alias Smelt.GitRepo

  doctest Smelt.Gate.Config

  @moduletag :tmp_dir

  describe "Requirement: Configure the gate per project" do
    test "Scenario: Defaults without a configuration file", %{tmp_dir: tmp_dir} do
      repo = GitRepo.gate_project!(tmp_dir)

      assert Config.load(repo, GitRepo.sha!(repo, "HEAD")) ==
               {:ok,
                %Config{
                  test_paths: ["test/"],
                  max_changed_lines: 400,
                  max_changed_files: 20,
                  timeout_seconds: 900
                }}
    end

    test "Scenario: Settings from the base commit", %{tmp_dir: tmp_dir} do
      repo =
        GitRepo.gate_project!(tmp_dir,
          gate: %{"max_changed_lines" => 10, "test_paths" => ["test/", "spec/"]}
        )

      base_sha = GitRepo.sha!(repo, "HEAD")
      # A later commit raises the limit; the base commit's value still applies.
      _ = GitRepo.commit!(repo, "raise", %{".smelt/gate.json" => ~s({"max_changed_lines": 9999})})

      assert {:ok, config} = Config.load(repo, base_sha)
      assert config.max_changed_lines == 10
      assert config.test_paths == ["test/", "spec/"]
      assert config.max_changed_files == 20
    end

    test "Scenario: Invalid configuration", %{tmp_dir: tmp_dir} do
      repo = GitRepo.gate_project!(tmp_dir)

      cases = [
        {"{not json", "not valid JSON"},
        {"[1, 2]", "must contain a JSON object"},
        {~s({"max_changed_lines": "400"}), ~s("max_changed_lines" must be a positive integer)},
        {~s({"max_changed_files": 0}), ~s("max_changed_files" must be a positive integer)},
        {~s({"timeout_seconds": 1.5}), ~s("timeout_seconds" must be a positive integer)},
        {~s({"test_paths": []}), ~s("test_paths" must be a non-empty list)},
        {~s({"test_paths": "test/"}), ~s("test_paths" must be a non-empty list)},
        {~s({"max_lines": 10}), ~s(unknown setting "max_lines")}
      ]

      for {json, message} <- cases do
        sha = GitRepo.commit!(repo, "config", %{".smelt/gate.json" => json})

        assert {:error, {:invalid_config, error}} = Config.load(repo, sha)
        assert error =~ message, "#{json}: #{error}"
      end
    end
  end
end
