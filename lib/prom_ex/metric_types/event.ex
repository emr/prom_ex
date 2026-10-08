defmodule PromEx.MetricTypes.Event do
  @moduledoc """
  This struct defines the fields necessary to export a group of
  standard metrics from a plugin.
  """

  @typedoc """
  - `group_name`: A unique identifier for the collection of metrics.
  - `metrics`: A list of Telemetry Metrics structs that define the metrics.
  """

  alias Telemetry.Metrics.Distribution

  @type t :: %__MODULE__{
          group_name: atom(),
          metrics: list(PromEx.telemetry_metrics())
        }

  defstruct group_name: :default, metrics: []

  @doc """
  Create a struct that encompasses a group of event based metrics. The `group_name` should be unique and should follow
  the following convention: `<APPLICATION>_<SHORT DESCRIPTION>_event_metrics`. For example, Phoenix HTTP related metrics
  have a `group_name` of: `:phoenix_http_event_metrics`
  """
  @spec build(group_name :: atom(), metrics :: list(PromEx.telemetry_metrics())) :: __MODULE__.t()
  def build(group_name, metrics) do
    %__MODULE__{
      group_name: group_name,
      metrics: build_buckets(metrics)
    }
  end

  defp build_buckets(metrics) do
    if PromEx.storage_adapter() == PromEx.Storage.Peep do
      Enum.map(metrics, &build_bucket/1)
    else
      metrics
    end
  end

  defp build_bucket(%Distribution{} = dist) do
    reporter_options =
      Keyword.put_new_lazy(dist.reporter_options, :peep_bucket_calculator, fn ->
        dist.reporter_options
        |> Keyword.fetch!(:buckets)
        |> bucket_module()
      end)

    %Distribution{dist | reporter_options: reporter_options}
  end

  defp build_bucket(other), do: other

  # The bucket modules are named after their boundaries so that each one is only defined once, regardless
  # of how many metrics or PromEx modules use it and of how many times the supervision tree is restarted
  defp bucket_module(buckets) do
    module = Module.concat(__MODULE__.PeepBuckets, "Buckets#{:erlang.phash2(buckets, 4_294_967_296)}")

    unless Code.ensure_loaded?(module) do
      Module.create(
        module,
        quote do
          use Peep.Buckets.Custom, buckets: unquote(buckets)
        end,
        __ENV__
      )
    end

    module
  end
end
