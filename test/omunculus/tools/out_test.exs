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

  test "unanswered names who asked, on which work, and the question, never an id" do
    worker = ~s({"kind":"agent","agent":"worker"})
    person = ~s({"kind":"human","issuer":"local","subject":"1000"})
    long = String.duplicate("word ", 40) <> "\nsecond line"

    assert Out.unanswered("lead", [%{requester: worker, reason: "Logo?", title: "Site"}], false) ==
             ~s(lead left worker's question on the work "Site" unanswered: "Logo?")

    assert Out.unanswered("sales", [%{requester: person, reason: long, title: nil}], true) ==
             ~s(sales left a person's question unanswered: ") <>
               String.trim(String.duplicate("word ", 32)) <> ~s(..." It is yours to answer now.)

    assert Out.unanswered(
             "root",
             [
               %{requester: worker, reason: "Logo?", title: "Site"},
               %{requester: worker, reason: nil, title: nil}
             ],
             false
           ) ==
             ~s(root left 2 questions unanswered: worker's on the work "Site": "Logo?"; worker's.)
  end
end
