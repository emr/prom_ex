defmodule PromEx.Plugins.BroadwayTest do
  use ExUnit.Case, async: true

  alias PromEx.MetricTypes.Event
  alias PromEx.Plugins.Broadway
  alias PromEx.Test.Support.{Events, Metrics}
  alias Telemetry.Metrics.Distribution

  @default_metadata %{
    processor_key: :default,
    topology_name: Elixir.SomeModule,
    message: %Elixir.Broadway.Message{acknowledger: {Elixir.SomeAcker}, data: %{}}
  }

  defmodule WebApp.PromEx do
    use PromEx, otp_app: :web_app

    @impl true
    def plugins do
      [Broadway]
    end
  end

  test "telemetry events are accumulated" do
    start_supervised!(WebApp.PromEx)
    Events.execute_all(:broadway)

    Metrics.assert_prom_ex_metrics(WebApp.PromEx, :broadway)
  end

  describe "event_metrics/1" do
    test "returns topology_name for message tags" do
      metric = assert_event_metric(:broadway_message_event_metrics, [:broadway, :processor, :message, :stop])
      assert %{name: "SomeModule", processor_key: :default} = metric.tag_values.(@default_metadata)
    end

    test "returns topology_name for message exception tags" do
      metric = assert_event_metric(:broadway_message_event_metrics, [:broadway, :processor, :message, :exception])
      exception_metadata = Map.merge(@default_metadata, %{kind: Error, reason: "notsure", stacktrace: []})
      assert %{name: "SomeModule", processor_key: :default} = metric.tag_values.(exception_metadata)
    end

    test "message duration buckets cover the same range for every duration unit" do
      millisecond_buckets =
        assert_event_metric(:broadway_message_event_metrics, [:broadway, :processor, :message, :stop])

      for {unit, convert} <- [
            nanosecond: &(&1 * 1_000_000),
            microsecond: &(&1 * 1_000),
            second: &(&1 / 1_000)
          ] do
        metric =
          assert_event_metric(:broadway_message_event_metrics, [:broadway, :processor, :message, :stop],
            duration_unit: unit
          )

        assert metric.reporter_options[:buckets] == Enum.map(millisecond_buckets.reporter_options[:buckets], convert)
      end
    end

    defp assert_event_metric(metric_group, event, opts \\ []) do
      assert event_metrics = Broadway.event_metrics(Keyword.merge([otp_app: :web_app], opts))

      assert %Event{metrics: message_metrics} =
               Enum.find(event_metrics, fn metrics -> metrics.group_name == metric_group end)

      assert %Distribution{} = metric = Enum.find(message_metrics, fn dist -> dist.event_name == event end)

      metric
    end
  end

  describe "init metrics" do
    test "configuration durations are converted to the configured duration unit" do
      assert %Event{metrics: init_metrics} =
               [otp_app: :web_app, duration_unit: :second]
               |> Broadway.event_metrics()
               |> Enum.find(&(&1.group_name == :broadway_init_event_metrics))

      batch_timeout_metric = Enum.find(init_metrics, &(:batch_timeout in &1.name))

      assert batch_timeout_metric.measurement.(%{}, %{batch_timeout: 1_000}) == 1.0
    end
  end
end
