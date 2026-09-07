defmodule Omunculus.MatrixTest do
  use ExUnit.Case, async: true

  alias Omunculus.Matrix

  test "lane overlay skips interceptors that are not implemented yet" do
    # ToolGate is loaded; this must fail when TeamGate exists so the matrix starts loading it.
    assert Matrix.skipped_lane_modules() == ["Omunculus.Interceptors.TeamGate"]
  end

  test "simple without overlay" do
    ctx = Matrix.simple()
    assert ctx.result == "10"
    Matrix.invariants!(ctx)
  end

  test "simple with lane.toml overlay" do
    ctx = Matrix.simple("simple.toml", "lane.toml")
    assert ctx.result == "10"
    Matrix.invariants!(ctx)
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

  test "simple chain types are identical with and without lane overlay" do
    without = Matrix.simple()
    with_lane = Matrix.simple("simple.toml", "lane.toml")
    assert without.types == with_lane.types
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
