alias TimelessTracesDashboard.DataPlane.Client
alias TimelessTracesDashboard.DataPlane.Process, as: DataPlaneProcess

defmodule TracesDataPlaneBoundaryBench do
  @iterations 500
  @rounds 5
  @trace_id "00112233445566778899aabbccddeeff"

  def run do
    workspace = Path.expand("../..", __DIR__)
    libsql = Path.join(workspace, "timeless-libsql")

    binary =
      System.get_env("TIMELESS_TRACES_API_BINARY") ||
        Path.join(libsql, "servers/target/release/timeless-traces-api")

    extension =
      System.get_env("TIMELESS_LIBSQL_EXTENSION") ||
        Path.join(libsql, "target/release/libtimeless_ext.so")

    fixture =
      System.get_env("TIMELESS_TRACES_FIXTURE") ||
        Path.join(workspace, "timeless_traces/test/fixtures/data_plane/rich_trace.otlp.json")

    for path <- [binary, extension, fixture] do
      unless File.regular?(path), do: raise("missing release artifact or fixture: #{path}")
    end

    Application.ensure_all_started(:req)
    unique = System.unique_integer([:positive])
    name = :"traces_data_plane_bench_#{unique}"
    database = Path.join(System.tmp_dir!(), "traces_data_plane_bench_#{unique}.db")
    port = free_port()
    started = System.monotonic_time(:microsecond)

    {:ok, supervisor} =
      Supervisor.start_link(
        [
          {DataPlaneProcess,
           name: name,
           binary: binary,
           extension: extension,
           database: database,
           listen: "127.0.0.1:#{port}",
           env: %{
             "TIMELESS_TRACES_FLUSH_INTERVAL_SECS" => "3600",
             "TIMELESS_TRACES_OPTIMIZE_INTERVAL_SECS" => "3600",
             "TIMELESS_TRACES_RETENTION_SECS" => "0"
           }}
        ],
        strategy: :one_for_one
      )

    try do
      {:ok, endpoint} = DataPlaneProcess.await_ready(name)
      startup_us = System.monotonic_time(:microsecond) - started

      response =
        Req.post!(endpoint <> "/insert/opentelemetry/v1/traces",
          body: File.read!(fixture),
          headers: [{"content-type", "application/json"}],
          retry: false
        )

      200 = response.status
      200 = Req.post!(endpoint <> "/api/v1/flush", retry: false).status
      health = Req.get!(endpoint <> "/health", retry: false).body
      stats = Req.get!(endpoint <> "/select/traces/stats", retry: false).body

      query = fn opts ->
        {:ok, spans} = Client.trace(@trace_id, opts)
        2 = length(spans)
      end

      Enum.each(1..50, fn _ ->
        query.(base_url: endpoint)
        query.(process: name)
      end)

      {direct, supervised} =
        Enum.reduce(1..@rounds, {[], []}, fn _round, {direct, supervised} ->
          {round_direct, round_supervised} = paired_samples(query, endpoint, name)
          {round_direct ++ direct, round_supervised ++ supervised}
        end)

      owner_memory = :erlang.process_info(Process.whereis(name), :memory) |> elem(1)
      old_pid = Process.whereis(name)
      ref = Process.monitor(old_pid)
      os_pid = DataPlaneProcess.os_pid(name)
      rust_hwm_kib = proc_value(os_pid, "VmHWM")
      restart_started = System.monotonic_time(:microsecond)
      {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])

      receive do
        {:DOWN, ^ref, :process, ^old_pid, _reason} -> :ok
      after
        5_000 -> raise("timed out waiting for supervised process exit")
      end

      await_restarted(name, old_pid, 500)
      {:ok, ^endpoint} = DataPlaneProcess.await_ready(name)
      restart_us = System.monotonic_time(:microsecond) - restart_started
      query.(process: name)

      direct_p95 = percentile(direct, 0.95)
      supervised_p95 = percentile(supervised, 0.95)

      IO.puts(
        "rounds=#{@rounds} iterations_per_round=#{@iterations} " <>
          "samples_per_path=#{length(direct)} spans_per_response=2"
      )

      IO.puts("startup_to_ready_us=#{startup_us}")
      IO.puts("otp_owner_memory_bytes=#{owner_memory}")
      IO.puts("rust_vm_hwm_kib=#{rust_hwm_kib}")
      IO.puts("admitted_spans=#{health["data_plane"]["admitted_spans"]}")
      IO.puts("completed_spans=#{health["data_plane"]["completed_spans"]}")
      IO.puts("queued_spans=#{health["data_plane"]["queued_spans"]}")
      IO.puts("in_flight_spans=#{health["data_plane"]["in_flight_spans"]}")
      IO.puts("logical_payload_bytes=#{stats["bytes_on_disk"]}")
      IO.puts("sqlite_index_bytes=#{stats["sqlite_index_bytes"]}")
      IO.puts("database_bytes=#{file_size(database)}")
      IO.puts("wal_bytes=#{file_size(database <> "-wal")}")
      IO.puts("shm_bytes=#{file_size(database <> "-shm")}")
      IO.puts("base_url_client_p50_us=#{percentile(direct, 0.50)}")
      IO.puts("base_url_client_p95_us=#{direct_p95}")
      IO.puts("base_url_client_p99_us=#{percentile(direct, 0.99)}")
      IO.puts("supervised_client_p50_us=#{percentile(supervised, 0.50)}")
      IO.puts("supervised_client_p95_us=#{supervised_p95}")
      IO.puts("supervised_client_p99_us=#{percentile(supervised, 0.99)}")
      IO.puts("supervision_lookup_p95_delta_us=#{supervised_p95 - direct_p95}")
      IO.puts("sigkill_to_ready_us=#{restart_us}")
      IO.puts("reopen_query=exact")
    after
      Supervisor.stop(supervisor)

      for suffix <- ["", "-shm", "-wal", ".timeless-traces-api.lock"] do
        File.rm(database <> suffix)
      end
    end
  end

  defp paired_samples(query, endpoint, name) do
    Enum.reduce(1..@iterations, {[], []}, fn iteration, {direct, supervised} ->
      operations =
        if rem(iteration, 2) == 0 do
          [direct: [base_url: endpoint], supervised: [process: name]]
        else
          [supervised: [process: name], direct: [base_url: endpoint]]
        end

      timings =
        Enum.map(operations, fn {kind, opts} ->
          started = System.monotonic_time(:microsecond)
          query.(opts)
          {kind, System.monotonic_time(:microsecond) - started}
        end)

      {
        [Keyword.fetch!(timings, :direct) | direct],
        [Keyword.fetch!(timings, :supervised) | supervised]
      }
    end)
  end

  defp proc_value(pid, field) do
    case File.read("/proc/#{pid}/status") do
      {:ok, status} ->
        case Regex.run(~r/^#{field}:\s+(\d+)\s+kB$/m, status) do
          [_, value] -> String.to_integer(value)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      _ -> 0
    end
  end

  defp percentile(samples, quantile) do
    sorted = Enum.sort(samples)
    index = max(ceil(length(sorted) * quantile) - 1, 0)
    Enum.at(sorted, index)
  end

  defp free_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp await_restarted(_name, _old_pid, 0), do: raise("data plane did not restart")

  defp await_restarted(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        receive do
        after
          10 -> await_restarted(name, old_pid, attempts - 1)
        end
    end
  end
end

TracesDataPlaneBoundaryBench.run()
