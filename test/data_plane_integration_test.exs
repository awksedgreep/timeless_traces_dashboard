defmodule TimelessTracesDashboard.DataPlaneIntegrationTest do
  use ExUnit.Case, async: false

  alias Phoenix.LiveDashboard.PageBuilder
  alias Phoenix.LiveView.Socket
  alias TimelessTracesDashboard.DataPlane.Client
  alias TimelessTracesDashboard.DataPlane.Process, as: DataPlaneProcess
  alias TimelessTracesDashboard.Page

  @libsql Path.expand("../../timeless-libsql", __DIR__)
  @binary Path.join(@libsql, "servers/target/release/timeless-traces-api")
  @extension Path.join(@libsql, "target/release/libtimeless_ext.so")
  @rich_fixture Path.expand(
                  "../../timeless_traces/test/fixtures/data_plane/rich_trace.otlp.json",
                  __DIR__
                )

  if File.regular?(@binary) and File.regular?(@extension) and File.regular?(@rich_fixture) do
    test "dashboard survives SIGKILL and normal OTP shutdown flushes and reaps the child" do
      unique = System.unique_integer([:positive])
      name = :"traces_data_plane_#{unique}"
      database = Path.join(System.tmp_dir!(), "traces_data_plane_#{unique}.db")
      policy_path = Path.join(System.tmp_dir!(), "traces_data_plane_policy_#{unique}.json")
      port = free_port()
      {token, policy} = auth_fixture()
      File.write!(policy_path, Jason.encode!(policy), [:binary, :exclusive])
      auth_header = {"authorization", "Bearer " <> token}
      prior_source = Application.get_env(:timeless_traces_dashboard, :historical_source)

      on_exit(fn ->
        restore_source(prior_source)
        File.rm(database)
        File.rm(database <> "-shm")
        File.rm(database <> "-wal")
        File.rm(database <> ".timeless-traces-api.lock")
        File.rm(policy_path)
      end)

      process_opts = [
        name: name,
        binary: @binary,
        extension: @extension,
        database: database,
        listen: "127.0.0.1:#{port}",
        env: %{
          "TIMELESS_TRACES_FLUSH_INTERVAL_SECS" => "3600",
          "TIMELESS_TRACES_OPTIMIZE_INTERVAL_SECS" => "3600",
          "TIMELESS_TRACES_RETENTION_SECS" => "0",
          "TIMELESS_AUTH_MODE" => "required",
          "TIMELESS_AUTH_POLICY_FILE" => policy_path,
          "TIMELESS_TENANT" => "default"
        }
      ]

      started = System.monotonic_time(:microsecond)
      start_supervised!({DataPlaneProcess, process_opts})
      assert {:ok, endpoint} = DataPlaneProcess.await_ready(name)
      startup_us = System.monotonic_time(:microsecond) - started
      assert File.regular?(database <> ".timeless-traces-api.lock")

      assert %Req.Response{status: 200} = ingest(endpoint, File.read!(@rich_fixture), auth_header)

      assert %Req.Response{status: 200, body: flush} =
               Req.post!(endpoint <> "/api/v1/flush",
                 headers: [auth_header],
                 decode_body: true,
                 retry: false
               )

      assert flush["completed_spans"] == 2
      assert flush["queued_spans"] == 0
      assert flush["in_flight_spans"] == 0

      Application.put_env(
        :timeless_traces_dashboard,
        :historical_source,
        {TimelessTracesDashboard.HistoricalSource.DataPlane,
         client: Client, client_opts: [process: name, headers: [auth_header]]}
      )

      socket = mounted_socket()

      # The fixture spans carry fixed 2023 timestamps; pin the search window
      # around them so the default now-relative window never ages them out.
      search_params = %{
        "nav" => "search",
        "name" => "contract",
        "service" => "contract-svc",
        "kind" => "",
        "status" => "",
        "since" => "1699999999",
        "until" => "1700000001",
        "p" => "1",
        "per_page" => "25"
      }

      assert {:noreply, searched} = Page.handle_params(search_params, "", socket)
      assert length(searched.assigns.entries) == 2

      assert Enum.map(searched.assigns.entries, & &1.span_id) == [
               "1112131415161718",
               "0102030405060708"
             ]

      trace_id = "00112233445566778899aabbccddeeff"

      assert {:noreply, detailed} =
               Page.handle_params(%{"nav" => "traces", "trace_id" => trace_id}, "", searched)

      assert_exact_rich_trace(detailed.assigns.trace_spans)

      owner_memory = :erlang.process_info(Process.whereis(name), :memory) |> elem(1)
      assert startup_us < 2_000_000
      assert owner_memory < 1_000_000

      old_beam_pid = Process.whereis(name)
      old_ref = Process.monitor(old_beam_pid)
      old_os_pid = DataPlaneProcess.os_pid(name)
      assert is_integer(old_os_pid)
      assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(old_os_pid)])
      assert_receive {:DOWN, ^old_ref, :process, ^old_beam_pid, _reason}, 5_000

      new_beam_pid = await_restarted(name, old_beam_pid, 500)
      assert is_pid(new_beam_pid)
      assert {:ok, ^endpoint} = DataPlaneProcess.await_ready(name)

      assert {:ok, restarted_spans} =
               Client.trace(trace_id, process: name, headers: [auth_header])

      assert_exact_rich_trace(restarted_spans)
      assert Process.alive?(self())

      graceful_trace_id = "fedcba98765432100123456789abcdef"

      assert %Req.Response{status: 200} =
               ingest(endpoint, graceful_fixture(graceful_trace_id), auth_header)

      restarted_os_pid = DataPlaneProcess.os_pid(name)
      assert :ok = stop_supervised({DataPlaneProcess, name})
      assert :ok = await_os_process_down(restarted_os_pid, 500)

      start_supervised!({DataPlaneProcess, process_opts})
      assert {:ok, ^endpoint} = DataPlaneProcess.await_ready(name)

      assert {:ok, [graceful]} =
               Client.trace(graceful_trace_id, process: name, headers: [auth_header])

      assert graceful.name == "graceful tail"
      assert graceful.resource == %{"service.name" => "shutdown-svc", "replica" => 9}

      final_os_pid = DataPlaneProcess.os_pid(name)
      assert :ok = stop_supervised({DataPlaneProcess, name})
      assert :ok = await_os_process_down(final_os_pid, 500)
    end
  else
    @tag skip: "build timeless-libsql and timeless-traces-api release artifacts to run this gate"
    test "dashboard survives SIGKILL and normal OTP shutdown flushes and reaps the child", do: :ok
  end

  defp mounted_socket do
    page = %PageBuilder{params: %{}, route: :traces, node: nil}
    socket = %Socket{assigns: %{__changed__: %{}, page: page}}
    assert {:ok, socket} = Page.mount(%{}, %{}, socket)
    socket
  end

  defp ingest(endpoint, body, auth_header) do
    Req.post!(endpoint <> "/insert/opentelemetry/v1/traces",
      body: body,
      headers: [{"content-type", "application/json"}, auth_header],
      decode_body: true,
      retry: false
    )
  end

  defp auth_fixture do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    now = System.system_time(:second)
    limits = limits()

    policy = %{
      version: 1,
      issuer: "timeless-control-plane",
      audience: "timeless-data-plane",
      tenant: "default",
      minimum_auth_version: 1,
      max_token_seconds: 900,
      maximum_limits: limits,
      subjects: %{
        "dashboard-test" => %{
          auth_version: 1,
          scopes: ~w(traces:read traces:write traces:stats traces:maintenance),
          maximum_limits: limits,
          enabled: true
        }
      },
      keys: [
        %{
          kid: "dashboard-test-key",
          public_key: Base.url_encode64(public_key, padding: false),
          not_before: 0,
          expires_at: now + 900,
          revoked: false
        }
      ],
      revoked_jtis: []
    }

    claims = %{
      iss: "timeless-control-plane",
      aud: "timeless-data-plane",
      sub: "dashboard-test",
      jti: "dashboard-test-token",
      tenant: "default",
      signal: "traces",
      scopes: ~w(traces:read traces:write traces:stats traces:maintenance),
      auth_version: 1,
      iat: now,
      nbf: now - 1,
      exp: now + 300,
      limits: limits
    }

    encoded_header =
      %{alg: "EdDSA", kid: "dashboard-test-key", typ: "JWT"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    encoded_claims = claims |> Jason.encode!() |> Base.url_encode64(padding: false)
    signing_input = encoded_header <> "." <> encoded_claims
    signature = :crypto.sign(:eddsa, :none, signing_input, [private_key, :ed25519])
    token = signing_input <> "." <> Base.url_encode64(signature, padding: false)
    {token, policy}
  end

  defp limits do
    %{
      max_request_bytes: 16_777_216,
      max_decompressed_bytes: 33_554_432,
      max_response_bytes: 16_777_216,
      max_query_rows: 100_000,
      max_request_ms: 30_000,
      max_concurrent_requests: 8,
      max_queue_ms: 5_000
    }
  end

  defp assert_exact_rich_trace(spans) do
    assert Enum.map(spans, & &1.span_id) == ["0102030405060708", "1112131415161718"]
    [root, child] = spans
    assert root.parent_span_id == nil
    assert root.status_message == "contract failure"
    assert root.attributes["http.status_code"] == 503
    assert root.attributes["retryable"] == true

    assert root.events == [
             %{
               "name" => "exception",
               "timestamp" => 1_700_000_000_040_000_000,
               "attributes" => %{"exception.type" => "ContractError", "handled" => false},
               "dropped_attributes_count" => 0
             }
           ]

    assert root.resource == %{
             "service.name" => "contract-svc",
             "service.version" => "1.2.3",
             "replica" => 7,
             "debug" => false
           }

    assert root.instrumentation_scope == %{
             "name" => "contract-lib",
             "version" => "4.5.6",
             "attributes" => %{}
           }

    assert child.parent_span_id == root.span_id
    assert child.attributes == %{"db.system" => "libsql", "rows" => 3}
    assert child.status_message == nil
  end

  defp graceful_fixture(trace_id) do
    Jason.encode!(%{
      "resourceSpans" => [
        %{
          "resource" => %{
            "attributes" => [
              %{"key" => "service.name", "value" => %{"stringValue" => "shutdown-svc"}},
              %{"key" => "replica", "value" => %{"intValue" => 9}}
            ]
          },
          "scopeSpans" => [
            %{
              "scope" => %{"name" => "shutdown-lib", "version" => "1"},
              "spans" => [
                %{
                  "traceId" => trace_id,
                  "spanId" => "aaaaaaaaaaaaaaaa",
                  "parentSpanId" => "",
                  "name" => "graceful tail",
                  "kind" => "SPAN_KIND_INTERNAL",
                  "startTimeUnixNano" => "1700000002000000000",
                  "endTimeUnixNano" => "1700000002000000042",
                  "status" => %{"code" => "STATUS_CODE_OK"},
                  "attributes" => [],
                  "events" => []
                }
              ]
            }
          ]
        }
      ]
    })
  end

  defp free_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp await_restarted(_name, _old_pid, 0), do: nil

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

  defp await_os_process_down(_os_pid, 0), do: {:error, :still_running}

  defp await_os_process_down(os_pid, attempts) do
    case System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_output, status} when status != 0 ->
        :ok

      _ ->
        receive do
        after
          10 -> await_os_process_down(os_pid, attempts - 1)
        end
    end
  end

  defp restore_source(nil),
    do: Application.delete_env(:timeless_traces_dashboard, :historical_source)

  defp restore_source(previous) do
    Application.put_env(:timeless_traces_dashboard, :historical_source, previous)
  end
end
