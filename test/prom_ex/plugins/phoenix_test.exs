defmodule TestApp.PollingEndpoint do
  @moduledoc false

  use Phoenix.Endpoint, otp_app: :prom_ex
end

defmodule PromEx.Plugins.PhoenixTest do
  use ExUnit.Case, async: false

  alias PromEx.Plugins.Phoenix
  alias PromEx.Test.Support.{Events, Metrics}

  defmodule WebApp.PromExPollingEndpoints do
    use PromEx, otp_app: :web_app

    @impl true
    def plugins do
      [
        {Phoenix,
         endpoints: [
           {TestApp.PollingEndpoint, routers: [TestApp.Router]},
           {TestApp.StoppedEndpoint, routers: [TestApp.Router]}
         ],
         poll_rate: :timer.hours(1)}
      ]
    end
  end

  defmodule WebApp.PromExMultipleEndpoint do
    use PromEx, otp_app: :web_app

    @additional_routes [
      special_label: "/really-cool-route",
      another_label: ~r(\/another-cool-route)
    ]

    @impl true
    def plugins do
      [
        {Phoenix, endpoints: [{TestApp.Endpoint, routers: [TestApp.Router], additional_routes: @additional_routes}]}
      ]
    end
  end

  defmodule WebApp.PromExSingleEndpoint do
    use PromEx, otp_app: :web_app

    @additional_routes [
      special_label: "/really-cool-route",
      another_label: ~r(\/another-cool-route)
    ]

    @impl true
    def plugins do
      [
        {Phoenix, router: TestApp.Router, additional_routes: @additional_routes, endpoint: TestApp.Endpoint}
      ]
    end
  end

  defmodule WebApp.PromExSingleEndpointNormalizedChannelEvents do
    use PromEx, otp_app: :web_app

    @additional_routes [
      special_label: "/really-cool-route",
      another_label: ~r(\/another-cool-route)
    ]

    @impl true
    def plugins do
      [
        {Phoenix,
         router: TestApp.Router,
         additional_routes: @additional_routes,
         endpoint: TestApp.Endpoint,
         normalize_event_name: fn
           "test_event" -> "test_event"
           _ -> "unknown"
         end}
      ]
    end
  end

  defmodule WebApp.PromExSingleEndpointAdditionalTags do
    use PromEx, otp_app: :web_app

    @additional_routes [
      special_label: "/really-cool-route",
      another_label: ~r(\/another-cool-route)
    ]

    @impl true
    def plugins do
      [
        {Phoenix,
         router: TestApp.Router,
         additional_routes: @additional_routes,
         endpoint: TestApp.Endpoint,
         additional_tags: [:my_metadata]}
      ]
    end
  end

  test "telemetry events are accumulated for single endpoint configuration" do
    start_supervised!(WebApp.PromExSingleEndpoint)
    Events.execute_all(:phoenix)

    Metrics.assert_prom_ex_metrics(WebApp.PromExSingleEndpoint, :phoenix)
  end

  test "telemetry events are accumulated for multiple endpoint configuration" do
    start_supervised!(WebApp.PromExMultipleEndpoint)
    Events.execute_all(:phoenix)

    Metrics.assert_prom_ex_metrics(WebApp.PromExMultipleEndpoint, :phoenix)
  end

  test "channel events normalize according to normalize_event_name" do
    start_supervised!(WebApp.PromExSingleEndpointNormalizedChannelEvents)
    Events.execute_all(:phoenix)

    collected_metrics = Metrics.read_collected(WebApp.PromExSingleEndpointNormalizedChannelEvents)

    assert collected_metrics |> Enum.any?(&String.contains?(&1, "unknown"))
  end

  test "telemetry events include additional tags" do
    start_supervised!(WebApp.PromExSingleEndpointAdditionalTags)
    Events.execute_all(:phoenix)

    collected_metrics = Metrics.read_collected(WebApp.PromExSingleEndpointAdditionalTags)

    assert collected_metrics |> Enum.any?(&String.contains?(&1, "my_metadata=\"test\""))
    refute collected_metrics |> Enum.any?(&String.contains?(&1, "non_collected_metadata=\"test\""))
  end

  describe "event_metrics/1" do
    test "should return the correct number of metrics" do
      assert length(Phoenix.event_metrics(otp_app: :prom_ex, router: Some.Module)) == 3
    end
  end

  describe "polling_metrics/1" do
    test "should return the correct number of metrics" do
      assert Phoenix.polling_metrics([]) == []
    end

    test "should return the endpoint metrics when endpoints are configured" do
      assert [%{group_name: :phoenix_endpoint_metrics, metrics: [_url_info, _port_info]}] =
               Phoenix.polling_metrics(otp_app: :prom_ex, router: Some.Module, endpoint: Some.Endpoint)

      assert [%{group_name: :phoenix_endpoint_metrics}] =
               Phoenix.polling_metrics(otp_app: :prom_ex, endpoints: [{Some.Endpoint, routers: [Some.Module]}])
    end
  end

  describe "additional tags" do
    test "should not fail when the private key atom does not exist yet" do
      [http_metrics | _] =
        Phoenix.event_metrics(
          otp_app: :prom_ex,
          router: TestApp.Router,
          endpoint: TestApp.Endpoint,
          additional_tags: [:tag_never_put_in_conn_private]
        )

      tag_values_fn = http_metrics.metrics |> List.first() |> Map.get(:tag_values)
      conn = %Plug.Conn{method: "GET", request_path: "/users", host: "localhost", status: 200}

      assert %{tag_never_put_in_conn_private: nil} = tag_values_fn.(%{conn: conn})
    end
  end

  describe "router options order preservation" do
    defp http_tag_values_fn(opts) do
      [http_metrics | _] =
        Phoenix.event_metrics(Keyword.merge([otp_app: :prom_ex], opts))

      http_metrics.metrics
      |> List.first()
      |> Map.get(:tag_values)
    end

    defp resolve_action(tag_values_fn, path) do
      conn = %Plug.Conn{method: "GET", request_path: path, host: "localhost", status: 200}
      tag_values_fn.(%{conn: conn}).action
    end

    test "first router wins for overlapping routes" do
      tag_values_fn =
        http_tag_values_fn(endpoints: [{TestApp.Endpoint, routers: [TestApp.Router, TestApp.OverlapRouter]}])

      assert resolve_action(tag_values_fn, "/users") == :index
    end

    test "preserves insertion order when deduplicating routers" do
      # [Router, OverlapRouter, Router] should deduplicate to [Router, OverlapRouter]
      tag_values_fn =
        http_tag_values_fn(
          endpoints: [
            {TestApp.Endpoint, routers: [TestApp.Router, TestApp.OverlapRouter, TestApp.Router]}
          ]
        )

      # TestApp.Router is first, so its action wins for the overlapping route
      assert resolve_action(tag_values_fn, "/users") == :index
    end

    test "keeps first occurrence when deduplicating, not last" do
      # [OverlapRouter, Router, OverlapRouter] should deduplicate to [OverlapRouter, Router]
      tag_values_fn =
        http_tag_values_fn(
          endpoints: [
            {TestApp.Endpoint, routers: [TestApp.OverlapRouter, TestApp.Router, TestApp.OverlapRouter]}
          ]
        )

      # TestApp.OverlapRouter is first, so its action wins for the overlapping route
      assert resolve_action(tag_values_fn, "/users") == :overlap_index
    end
  end

  describe "endpoint tag" do
    test "is the endpoint that served the request" do
      tag_values_fn = http_tag_values_fn(router: TestApp.Router, endpoint: TestApp.Endpoint)
      conn = %Plug.Conn{method: "GET", request_path: "/users", host: "localhost", status: 200}

      # A proxy endpoint dispatching the request to another endpoint
      assert %{endpoint: "TestApp.Endpoint2"} =
               tag_values_fn.(%{conn: Plug.Conn.put_private(conn, :phoenix_endpoint, TestApp.Endpoint2)})

      assert %{endpoint: "Unknown"} = tag_values_fn.(%{conn: conn})
    end
  end

  describe "routes of multiple endpoints" do
    setup do
      tag_values_fn =
        http_tag_values_fn(
          endpoints: [
            {TestApp.Endpoint, routers: [TestApp.Router]},
            {TestApp.Endpoint2, routers: [TestApp.OverlapRouter]},
            {TestApp.ProxyEndpoint, routers: [], additional_routes: [health: "/health"]}
          ]
        )

      %{tag_values_fn: tag_values_fn}
    end

    defp resolve_route(tag_values_fn, path, endpoint) do
      conn = %Plug.Conn{method: "GET", request_path: path, host: "localhost", status: 200}
      conn = if endpoint, do: Plug.Conn.put_private(conn, :phoenix_endpoint, endpoint), else: conn

      %{conn: conn}
      |> tag_values_fn.()
      |> Map.take([:path, :controller, :action])
    end

    test "are resolved with the routers of the endpoint that served the request", %{tag_values_fn: tag_values_fn} do
      assert %{path: "/users", action: :index} = resolve_route(tag_values_fn, "/users", TestApp.Endpoint)
      assert %{path: "/users", action: :overlap_index} = resolve_route(tag_values_fn, "/users", TestApp.Endpoint2)
    end

    test "include the additional routes of the endpoint that served the request", %{tag_values_fn: tag_values_fn} do
      assert %{path: :health, controller: "NA"} = resolve_route(tag_values_fn, "/health", TestApp.ProxyEndpoint)
      assert %{path: "Unknown"} = resolve_route(tag_values_fn, "/health", TestApp.Endpoint)
    end

    test "are unknown when the endpoint that served the request has no matching route", %{
      tag_values_fn: tag_values_fn
    } do
      assert %{path: "Unknown", controller: "Unknown", action: "Unknown"} =
               resolve_route(tag_values_fn, "/users", TestApp.ProxyEndpoint)
    end

    test "are resolved with the routers of all the endpoints when the endpoint is not configured", %{
      tag_values_fn: tag_values_fn
    } do
      assert %{path: "/users", action: :index} = resolve_route(tag_values_fn, "/users", TestApp.OtherEndpoint)
      assert %{path: "/users", action: :index} = resolve_route(tag_values_fn, "/users", nil)
      assert %{path: :health} = resolve_route(tag_values_fn, "/health", nil)
    end
  end

  describe "endpoint info" do
    setup do
      Application.put_env(:prom_ex, TestApp.PollingEndpoint,
        url: [host: "example.com"],
        http: [port: 4321],
        server: false
      )

      on_exit(fn -> Application.delete_env(:prom_ex, TestApp.PollingEndpoint) end)
    end

    test "is exported for the running endpoints, including the ones that started after PromEx" do
      start_supervised!(WebApp.PromExPollingEndpoints)
      start_supervised!(TestApp.PollingEndpoint)

      Phoenix.execute_endpoint_info([TestApp.PollingEndpoint, TestApp.StoppedEndpoint])

      collected_metrics = Metrics.read_collected(WebApp.PromExPollingEndpoints)

      assert ~s(web_app_prom_ex_phoenix_endpoint_url_info{endpoint="TestApp.PollingEndpoint",url="http://example.com:4321"} 1) in collected_metrics

      assert ~s(web_app_prom_ex_phoenix_endpoint_port_info{endpoint="TestApp.PollingEndpoint",port="4321"} 1) in collected_metrics

      refute Enum.any?(collected_metrics, &String.contains?(&1, "TestApp.StoppedEndpoint"))
    end

    test "has an unknown port when the endpoint has no HTTP listener" do
      Application.put_env(:prom_ex, TestApp.PollingEndpoint, url: [host: "example.com"], http: false, server: false)

      start_supervised!(WebApp.PromExPollingEndpoints)
      start_supervised!(TestApp.PollingEndpoint)

      Phoenix.execute_endpoint_info([TestApp.PollingEndpoint])

      assert ~s(web_app_prom_ex_phoenix_endpoint_port_info{endpoint="TestApp.PollingEndpoint",port="Unknown"} 1) in Metrics.read_collected(
               WebApp.PromExPollingEndpoints
             )
    end

    test "has the HTTPS port when the HTTP listener is disabled" do
      Application.put_env(:prom_ex, TestApp.PollingEndpoint,
        url: [host: "example.com"],
        http: false,
        https: [port: 4443],
        server: false
      )

      start_supervised!(WebApp.PromExPollingEndpoints)
      start_supervised!(TestApp.PollingEndpoint)

      Phoenix.execute_endpoint_info([TestApp.PollingEndpoint])

      assert ~s(web_app_prom_ex_phoenix_endpoint_port_info{endpoint="TestApp.PollingEndpoint",port="4443"} 1) in Metrics.read_collected(
               WebApp.PromExPollingEndpoints
             )
    end
  end
end
