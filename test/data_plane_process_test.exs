defmodule TimelessTracesDashboard.DataPlaneProcessTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias TimelessTracesDashboard.DataPlane.Process, as: DataPlaneProcess

  test "an unterminated child output line is capped" do
    state = %{port: :fake_port, partial_line: String.duplicate("x", 65_500)}

    log =
      capture_log(fn ->
        assert {:noreply, state} =
                 DataPlaneProcess.handle_info(
                   {:fake_port, {:data, {:noeol, String.duplicate("y", 100)}}},
                   state
                 )

        assert state.partial_line == ""
      end)

    assert log =~ "discarded an unterminated output line"
  end

  test "an await_ready waiter owns a deadline and is removed when it expires" do
    tag = make_ref()
    state = %{ready?: false, waiters: %{}}

    assert {:noreply, waiting} =
             DataPlaneProcess.handle_call({:await_ready, 0}, {self(), tag}, state)

    assert map_size(waiting.waiters) == 1
    assert_receive {:waiter_timeout, ref}

    assert {:noreply, ready} =
             DataPlaneProcess.handle_info({:waiter_timeout, ref}, waiting)

    assert ready.waiters == %{}
    assert_receive {^tag, {:error, :ready_timeout}}
  end

  test "dead await_ready callers are pruned before readiness" do
    caller = spawn(fn -> receive do: (:stop -> :ok) end)
    state = %{ready?: false, waiters: %{}}

    assert {:noreply, waiting} =
             DataPlaneProcess.handle_call({:await_ready, :infinity}, {caller, make_ref()}, state)

    [{_ref, waiter}] = Map.to_list(waiting.waiters)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, monitor, :process, ^caller, :killed}
    assert monitor == waiter.monitor

    assert {:noreply, ready} =
             DataPlaneProcess.handle_info({:DOWN, monitor, :process, caller, :killed}, waiting)

    assert ready.waiters == %{}
  end
end
