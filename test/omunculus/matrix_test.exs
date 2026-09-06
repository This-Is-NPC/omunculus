defmodule Omunculus.MatrixTest do
  use ExUnit.Case, async: true

  alias Omunculus.Matrix

  test "lane overlay skips interceptors that are not implemented yet" do
    # When ToolGate and TeamGate exist, this test must fail so the matrix starts loading them.
    assert Matrix.skipped_lane_modules() == [
             "Omunculus.Interceptors.TeamGate",
             "Omunculus.Interceptors.ToolGate"
           ]
  end

  test "medium without overlay" do
    ctx = Matrix.medium()
    assert ctx.result == "10"
    Matrix.invariants!(ctx)
  end

  test "medium with lane.toml overlay" do
    ctx = Matrix.medium("medium.toml", "lane.toml")
    assert ctx.result == "10"
    Matrix.invariants!(ctx)
  end

  test "complex without overlay" do
    ctx = Matrix.complex()
    assert ctx.result == "10"
    Matrix.invariants!(ctx)
  end

  test "complex with lane.toml overlay" do
    ctx = Matrix.complex("complex.toml", "lane.toml")
    assert ctx.result == "10"
    Matrix.invariants!(ctx)
  end

  test "medium chain types are identical with and without lane overlay" do
    without = Matrix.medium()
    with_lane = Matrix.medium("medium.toml", "lane.toml")
    assert without.types == with_lane.types
  end

  test "complex chain types are identical with and without lane overlay" do
    without = Matrix.complex()
    with_lane = Matrix.complex("complex.toml", "lane.toml")
    assert without.types == with_lane.types
  end
end
