defmodule TimelessTracesDashboardTest do
  use ExUnit.Case

  alias Phoenix.LiveDashboard.NavBarComponent
  alias Phoenix.LiveDashboard.PageBuilder

  test "page module implements PageBuilder callbacks" do
    Code.ensure_loaded!(TimelessTracesDashboard.Page)
    assert function_exported?(TimelessTracesDashboard.Page, :menu_link, 2)
    assert function_exported?(TimelessTracesDashboard.Page, :render, 1)
    assert function_exported?(TimelessTracesDashboard.Page, :mount, 3)
    assert function_exported?(TimelessTracesDashboard.Page, :handle_params, 3)
    assert function_exported?(TimelessTracesDashboard.Page, :handle_event, 3)
    assert function_exported?(TimelessTracesDashboard.Page, :handle_info, 2)
  end

  test "menu_link returns ok with TimelessTraces label" do
    assert {:ok, "TimelessTraces"} = TimelessTracesDashboard.Page.menu_link(%{}, %{})
  end

  test "stats tab is active by default when nav param is missing" do
    assigns = %{
      page: %PageBuilder{params: %{}, route: :traces, node: nil},
      item: [
        %{name: "stats", label: "Stats"},
        %{name: "search", label: "Search"},
        %{name: "traces", label: "Traces"},
        %{name: "tail", label: "Live Tail"}
      ]
    }

    normalized = NavBarComponent.normalize_assigns(assigns)

    assert normalized.current.name == "stats"
  end

  test "explicit nav param still selects the requested tab" do
    assigns = %{
      page: %PageBuilder{params: %{"nav" => "traces"}, route: :traces, node: nil},
      item: [
        %{name: "stats", label: "Stats"},
        %{name: "search", label: "Search"},
        %{name: "traces", label: "Traces"},
        %{name: "tail", label: "Live Tail"}
      ]
    }

    normalized = NavBarComponent.normalize_assigns(assigns)

    assert normalized.current.name == "traces"
  end
end
