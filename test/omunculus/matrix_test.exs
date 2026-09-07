defmodule Omunculus.MatrixTest do
  use ExUnit.Case, async: true

  alias Omunculus.Matrix

  test "lane overlay loads every configured interceptor" do
    # TeamGate is loaded; this must fail when a new unknown interceptor is added to lane.toml.
    assert Matrix.skipped_lane_modules() == []
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
