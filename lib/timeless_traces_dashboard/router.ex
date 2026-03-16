defmodule TimelessTracesDashboard.Router do
  @moduledoc """
  Router macro for one-line LiveDashboard setup with TimelessTraces pages.

  ## Usage

      defmodule MyAppWeb.Router do
        use Phoenix.Router
        import TimelessTracesDashboard.Router

        scope "/" do
          pipe_through :browser
          timeless_traces_dashboard "/dashboard"
        end
      end

  ## Options

    * `:live_dashboard` — extra opts merged into `live_dashboard` call
  """

  @doc """
  Mounts LiveDashboard with the TimelessTraces page.
  """
  defmacro timeless_traces_dashboard(path, opts \\ []) do
    quote bind_quoted: [path: path, opts: opts] do
      import Phoenix.LiveDashboard.Router

      extra = Keyword.get(opts, :live_dashboard, [])

      dashboard_opts =
        [
          live_session_name: :timeless_traces_dashboard,
          additional_pages: [traces: TimelessTracesDashboard.Page]
        ] ++ extra

      live_dashboard(path, dashboard_opts)
    end
  end
end
