defmodule PromEx.Plugins.BeamTest do
  use ExUnit.Case, async: true

  alias PromEx.Plugins.Beam
  alias PromEx.Test.Support.{Events, Metrics}

  defmodule WebApp.PromEx do
    use PromEx, otp_app: :web_app

    @impl true
    def plugins do
      [Beam]
    end
  end

  test "telemetry events are accumulated" do
    start_supervised!(WebApp.PromEx)
    Events.execute_all(:beam)

    Metrics.assert_prom_ex_metrics(WebApp.PromEx, :beam)
  end

  describe "event_metrics/1" do
    test "should return the correct number of metrics" do
      assert Beam.event_metrics([]) == []
    end
  end

  describe "polling_metrics/1" do
    test "should return the correct number of metrics" do
      assert length(Beam.polling_metrics(otp_app: :prom_ex)) == 4
    end

    test "should convert the uptime to the configured duration unit" do
      uptime_metric =
        [otp_app: :prom_ex, duration_unit: :second]
        |> Beam.polling_metrics()
        |> Enum.flat_map(& &1.metrics)
        |> Enum.find(&(&1.name == [:prom_ex, :prom_ex, :beam, :stats, :uptime, :seconds, :count]))

      assert uptime_metric.measurement.(%{count: 5_000}) == 5.0
    end
  end

  describe "manual_metrics/1" do
    test "should return the correct number of metrics" do
      assert length(Beam.manual_metrics(otp_app: :prom_ex)) == 4
    end
  end
end
