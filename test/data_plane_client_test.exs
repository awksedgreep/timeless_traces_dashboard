defmodule TimelessTracesDashboard.DataPlaneClientTest do
  use ExUnit.Case, async: true

  alias TimelessTracesDashboard.DataPlane.Client

  test "decodes one complete native rich-span search result" do
    endpoint = serve_once(Jason.encode!(search_body()))

    assert {:ok, %TimelessTraces.Result{entries: [span], has_more: false}} =
             Client.search([service: "contract-svc", limit: 25], base_url: endpoint)

    assert span.trace_id == "00112233445566778899aabbccddeeff"
    assert span.status_message == "contract failure"
    assert span.attributes == %{"retryable" => true, "count" => 7}
    assert span.events == [%{"name" => "exception", "attributes" => %{"handled" => false}}]
    assert span.resource == %{"service.name" => "contract-svc", "replica" => 7}
    assert span.instrumentation_scope == %{"name" => "contract-lib", "version" => "4.5.6"}
  end

  test "invalid JSON and a malformed later span fail the complete operation" do
    assert {:error, {:invalid_response, _reason}} =
             Client.search([], base_url: serve_once(~s({"entries":)))

    body = search_body()
    invalid = put_in(body, ["entries"], body["entries"] ++ [%{"trace_id" => "partial"}])

    assert {:error, {:invalid_span, :invalid_shape}} =
             Client.search([], base_url: serve_once(Jason.encode!(invalid)))
  end

  test "a connection closed before its declared body is complete is transport failure" do
    endpoint = serve_once(Jason.encode!(search_body()), 100_000)

    assert {:error, {:transport, _reason}} = Client.search([], base_url: endpoint)
  end

  test "trace lookup rejects mismatched IDs rather than publishing a partial waterfall" do
    endpoint = serve_once(Jason.encode!(%{"spans" => [span_body()]}))

    assert {:error, :trace_id_mismatch} =
             Client.trace("ffffffffffffffffffffffffffffffff", base_url: endpoint)
  end

  test "rejects non-loopback endpoints before opening a connection" do
    assert {:error, {:traces_data_plane_must_use_loopback, "http://192.0.2.1:19449"}} =
             Client.search([], base_url: "http://192.0.2.1:19449")
  end

  defp search_body do
    %{
      "entries" => [span_body()],
      "total" => 1,
      "limit" => 25,
      "offset" => 0,
      "has_more" => false
    }
  end

  defp span_body do
    %{
      "trace_id" => "00112233445566778899aabbccddeeff",
      "span_id" => "0102030405060708",
      "parent_span_id" => nil,
      "name" => "GET /contract",
      "kind" => "server",
      "start_time" => 1_700_000_000_000_000_000,
      "end_time" => 1_700_000_000_120_000_000,
      "duration_ns" => 120_000_000,
      "status" => "error",
      "status_message" => "contract failure",
      "attributes" => %{"retryable" => true, "count" => 7},
      "events" => [%{"name" => "exception", "attributes" => %{"handled" => false}}],
      "resource" => %{"service.name" => "contract-svc", "replica" => 7},
      "instrumentation_scope" => %{"name" => "contract-lib", "version" => "4.5.6"}
    }
  end

  defp serve_once(body, declared_length \\ nil) do
    declared_length = declared_length || byte_size(body)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(listener)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener)
         {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

         response = [
           "HTTP/1.1 200 OK\r\n",
           "content-type: application/json\r\n",
           "content-length: #{declared_length}\r\n",
           "connection: close\r\n\r\n",
           body
         ]

         :ok = :gen_tcp.send(socket, response)
         :gen_tcp.close(socket)
         :gen_tcp.close(listener)
       end}
    )

    "http://127.0.0.1:#{port}"
  end
end
