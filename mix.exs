defmodule TimelessTracesDashboard.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/awksedgreep/timeless_traces_dashboard"

  def project do
    [
      app: :timeless_traces_dashboard,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Phoenix LiveDashboard page for TimelessTraces span viewer.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:timeless_traces, path: "../timeless_traces"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_live_view, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.6"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Matt Cotner"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"]
    ]
  end
end
