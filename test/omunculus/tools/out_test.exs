defmodule Omunculus.Tools.OutTest do
  use ExUnit.Case, async: true

  alias Omunculus.Tools.Out

  test "model_failed says each adapter's failure in a sentence" do
    openai = %{"error" => %{"message" => "context too long"}}

    assert Out.model_failed({:openai, {:http, 400, openai}}) ==
             "the model's server answered 400: context too long"

    assert Out.model_failed({:anthropic, {:http, 502, "Bad Gateway"}}) ==
             "the model's server answered 502: Bad Gateway"

    assert Out.model_failed({:openai, %Req.TransportError{reason: :timeout}}) ==
             "the model did not answer in time"

    assert Out.model_failed({:anthropic, %Req.TransportError{reason: :econnrefused}}) ==
             "the model's server could not be reached: connection refused"

    assert Out.model_failed({:command, :timeout}) == "the model did not answer in time"
    assert Out.model_failed({:command, {:exit, 2}}) == "the model's program exited with status 2"
    assert Out.model_failed({:command, "no credit"}) == "no credit"

    assert Out.model_failed({:model_crashed, {:exit, :killed}}) ==
             "the model crashed: ** (exit) killed"
  end
end
