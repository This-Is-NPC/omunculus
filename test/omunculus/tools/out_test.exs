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

  # Every reason the store can refuse a model's call with, by action.
  @refusals [
    {:reply, :review_option},
    {:interception, {:reviewer, "owner"}},
    {:hold, :invalid_emit},
    {:reopen, {:only_person, "x"}},
    {:reopen, {:cannot_grant, "x"}},
    {:reopen, {:blocked, "x"}},
    {:reopen, {:unknown_stage, "x"}},
    {:reopen, {:stage_ahead, "publish"}},
    {:reopen, {:invalid, "stage"}},
    {:reopen, :agent_with_workflow},
    {:reopen, {:agent_not_allowed, "x"}},
    {:reopen, :agent_and_stage},
    {:reopen, :no_workflow},
    {:reopen, {:unknown_workflow, "x"}},
    {:reopen, :no_body},
    {:reopen, :no_past_limit},
    {:reopen, :not_broken},
    {:reopen, :not_a_child},
    {:reopen, :no_work},
    {:reopen, {:missing, :works, "w"}},
    {:retire, :not_broken},
    {:retire, :no_body},
    {:retire, :not_a_child},
    {:work, :no_report},
    {:work, :no_delegate},
    {:work, :one_root},
    {:work, {:invalid, "works"}},
    {:work, {:agent_not_allowed, "x"}},
    {:work, :agent_with_workflow},
    {:work, {:workflow_required, ["a"]}},
    {:work, {:workflow_required, ["a", "b"]}},
    {:work, {:workflow_not_allowed, "x", ["a"]}},
    {:work, {:forbidden, "stage"}},
    {:delegate, :no_title},
    {:delegate, :no_goal},
    {:delegate, {:broken_child, "w"}},
    {:delegate, {:agent_not_allowed, "x"}},
    {:delegate, :agent_with_workflow},
    {:delegate, {:workflow_required, ["a"]}},
    {:delegate, {:workflow_not_allowed, "x", ["a"]}},
    {:delegate, {:forbidden, "stage"}},
    {:reply, :no_request},
    {:reply, :no_body},
    {:reply, :closed},
    {:reply, :escalated},
    {:reply, :not_arbiter},
    {:reply, :invalid_parts},
    {:reply, {:unknown_option, "x", ["a"]}},
    {:reply, {:unknown_option, "x", []}},
    {:request, :no_reason},
    {:request, :no_run},
    {:request, :no_route},
    {:request, :no_requester_run},
    {:request, :asked_again},
    {:request, :missing_participant},
    {:request, {:blocked, "x"}},
    {:request, {:already_have, "x"}},
    {:request, {:unknown_account, "x", ["a"]}},
    {:request, {:ask_self, "x"}},
    {:request, {:unreachable, "x"}},
    {:request, {:invalid, :options}},
    {:request, {:missing, :runs, "r"}},
    {:end, :no_run},
    {:end, :work_open},
    {:end, :root_open},
    {:end, {:broken_child, "w"}},
    {:break, :no_body},
    {:break, :waiting_children},
    {:break, :no_work},
    {:break, :waiting},
    {:break, {:not_open, "done"}},
    {:break, {:missing, :works, "w"}},
    {:continue, {:forbidden, "stage"}},
    {:continue, :off_sequence},
    {:continue, {:unknown_workflow, "x"}},
    {:continue, {:broken_child, "w"}},
    {:continue, :waiting},
    {:escalate, :no_reason},
    {:escalate, :asked_again},
    {:escalate, :invalid_origin},
    {:escalate, :invalid_origins},
    {:escalate, :no_request}
  ]

  test "every refusal is said in words, never as an Elixir term" do
    for reason <- @refusals do
      message = Out.refused(reason)

      assert String.starts_with?(message, "refused: ")
      refute message =~ "{:", "#{inspect(reason)} reads as a term: #{message}"
      refute message =~ "%{", "#{inspect(reason)} reads as a term: #{message}"
      refute message =~ "[:", "#{inspect(reason)} reads as a term: #{message}"
    end
  end

  test "a request with no option says to write the answer in body" do
    assert Out.refused({:reply, {:unknown_option, "yes", []}}) ==
             ~s(refused: "yes" is not an option: this request takes no option, write your answer in body)

    assert Out.refused({:reply, {:unknown_option, "yes", ["a", "b"]}}) =~
             "give option as one of: a, b"
  end

  test "a held action says what waits and who reviews it" do
    assert Out.held(~s(root wants to ask test:client: "Ship?"), "owner") ==
             ~s(not done yet: root wants to ask test:client: "Ship?". It was sent to owner for review, and their answer comes back to you; do not do it again)
  end

  test "a value the agent gave is quoted" do
    assert Out.refused({:work, {:workflow_not_allowed, "page", ["site"]}}) =~
             ~s("page" is not a workflow)

    assert Out.refused({:delegate, {:agent_not_allowed, "ghost"}}) =~ ~s("ghost" is not an agent)
    assert Out.refused({:request, {:blocked, "bash"}}) =~ ~s(grant "bash")
    assert Out.not_yours("bash") =~ ~s("bash" is not one of your tools)
  end
end
