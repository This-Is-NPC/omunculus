Code.require_file("../../eval/lib/task.ex", __DIR__)
Code.require_file("../../eval/lib/requests.ex", __DIR__)

defmodule Omunculus.EvalRequestsTest do
  use ExUnit.Case, async: true
  alias EquivalentExchange.Requests

  defp request(reason, options \\ %{}, origins \\ %{}),
    do: %{
      id: "request",
      status: "pending",
      reason: reason,
      options: Jason.encode!(options),
      origins: origins
    }

  test "a merged question asks the client once and returns text for distribution" do
    merged =
      request("Which logo and tone?", %{}, %{
        "logo" => request("Which logo?"),
        "tone" => request("Which tone?")
      })

    parent = self()

    reply = fn question ->
      send(parent, {:question, question})
      {:ok, "Blue logo, calm tone."}
    end

    assert {:ok, %{"body" => "Blue logo, calm tone."} = answer} =
             Requests.answer(%{human: %{}}, %{}, merged, "/tmp", reply)

    refute Map.has_key?(answer, "parts")
    assert_received {:question, "Which logo and tone?"}
    refute_received {:question, _}
    assert [%{option: nil}] = Requests.answers(merged, answer)
  end

  test "named decisions and grants keep automatic answers without calling the person model" do
    question = request("Which logo?")
    decision = request("Approve?", %{"approve" => [], "deny" => []})
    merged = request("Decide and answer", %{}, %{"decision" => decision, "question" => question})

    assert {:ok, answer} =
             Requests.answer(%{human: %{"decision" => "approve"}}, %{}, merged, "/tmp", fn _ ->
               flunk("automatic decision must not call the person model")
             end)

    assert answer["parts"]["decision"]["option"] == "approve"
    refute Map.has_key?(answer["parts"], "question")
  end

  test "retry requests stay unanswered and person failures propagate" do
    retry = request("Retry?", %{"retry" => [], "cancel" => []})

    assert {:ok, nil} =
             Requests.answer(%{human: %{}}, %{}, retry, "/tmp", fn _ ->
               flunk("retry is not a client question")
             end)

    assert {:error, :unavailable} =
             Requests.answer(%{human: %{}}, %{}, request("Logo?"), "/tmp", fn _ ->
               {:error, :unavailable}
             end)

    assert {:ok, nil} =
             Requests.answer(%{human: %{}}, %{}, request("Logo?"), "/tmp", fn _ ->
               {:ok, :nothing}
             end)
  end
end
