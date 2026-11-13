defmodule Smelt.RunnerTest do
  use ExUnit.Case, async: true

  alias Smelt.Runner
  alias Smelt.Runner.Event

  describe "new_run_id/0" do
    test "returns a different id on each call" do
      assert Runner.new_run_id() != Runner.new_run_id()
    end
  end

  describe "subscribe/1" do
    test "delivers messages broadcast on the run's topic" do
      run_id = Runner.new_run_id()
      :ok = Runner.subscribe(run_id)

      event = %Event{type: :text, data: %{text: "hi"}}
      :ok = Phoenix.PubSub.broadcast(Smelt.PubSub, Runner.topic(run_id), {Runner, run_id, event})

      assert_receive {Runner, ^run_id, ^event}
    end

    test "does not deliver messages from other runs" do
      run_id = Runner.new_run_id()
      other_id = Runner.new_run_id()
      :ok = Runner.subscribe(run_id)

      :ok = Runner.broadcast(other_id, %Event{type: :text, data: %{text: "other"}})

      refute_receive {Runner, _, _}
    end
  end

  describe "broadcast/2" do
    test "sends the event tagged with the runner module and run id" do
      run_id = Runner.new_run_id()
      :ok = Runner.subscribe(run_id)

      event = %Event{type: :finished, data: {:error, :stopped}}
      :ok = Runner.broadcast(run_id, event)

      assert_receive {Runner, ^run_id, ^event}
    end
  end
end
