defmodule PromEx.Plugins.AbsintheTest do
  use ExUnit.Case, async: false

  alias PromEx.Test.Support.Metrics

  defmodule TestSchema do
    use Absinthe.Schema

    query do
      field :hello, :string do
        resolve(fn _, _ -> {:ok, "world"} end)
      end
    end
  end

  defmodule WebApp.PromEx do
    use PromEx, otp_app: :web_app

    @impl true
    def plugins do
      [PromEx.Plugins.Absinthe]
    end
  end

  test "operations not supported by the schema do not detach the metric handlers" do
    start_supervised!(WebApp.PromEx)

    {:ok, %{errors: _}} = Absinthe.run("mutation { hello }", TestSchema)
    {:ok, %{data: _}} = Absinthe.run("{ hello }", TestSchema)

    collected_metrics = Metrics.read_collected(WebApp.PromEx)
    schema = inspect(TestSchema)

    assert Enum.any?(
             collected_metrics,
             &String.contains?(&1, ~s(operation_type="mutation",schema="#{schema}"))
           )

    assert Enum.any?(collected_metrics, &String.contains?(&1, ~s(entrypoint="hello")))
    assert Enum.any?(collected_metrics, &String.contains?(&1, ~s(invalid_request_count{schema="#{schema}"} 1)))
  end
end
