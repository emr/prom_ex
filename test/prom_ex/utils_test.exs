defmodule PromEx.UtilsTest do
  use ExUnit.Case, async: true

  alias PromEx.Utils

  describe "normalize_exception/3" do
    test "should normalize errors to the exception module name" do
      assert Utils.normalize_exception(:error, %RuntimeError{message: "boom"}, []) == "RuntimeError"
      assert Utils.normalize_exception(:error, :badarg, []) == "ArgumentError"
    end

    test "should normalize exits with an atom reason" do
      assert Utils.normalize_exception(:exit, {:timeout, {GenServer, :call, []}}, []) == "Timeout"
    end

    test "should not fail on exits with a non-atom reason" do
      assert Utils.normalize_exception(:exit, {{:shutdown, :closed}, {GenServer, :call, []}}, []) == "UnknownExit"
      assert Utils.normalize_exception(:exit, {"reason", :details}, []) == "UnknownExit"
    end
  end
end
