Code.require_file("../../eval/lib/requests.ex", __DIR__)
Code.require_file("../../eval/lib/person.ex", __DIR__)

for file <- ~w(project task judge deploy score resources report selftest usage deadline runner),
    do: Code.require_file("../../eval/lib/#{file}.ex", __DIR__)

defmodule Omunculus.EvalResumeTest do
  use ExUnit.Case, async: true

  alias EquivalentExchange.Person

  test "resume refuses options that would change the saved comparison" do
    assert_raise ArgumentError, ~r/other run options are refused/, fn ->
      EquivalentExchange.Runner.run(resume: "/unused", model: "haiku")
    end
  end

  test "restores client replies and linked decisions without replaying tools" do
    leaf = %{id: "leaf", origins: %{}}
    request = %{id: "envelope", reason: "Approve the preview?", origins: %{"design" => leaf}}

    answer = %{
      "request_id" => "envelope",
      "body" => "Approved",
      "parts" => %{"design" => %{"option" => "approve", "body" => "Yes"}}
    }

    events = [
      event("prompt", %{"message" => "Build a site"}),
      # The person replies through the command line, whose --parts is JSON text.
      event("tool", %{
        "name" => "reply",
        "ok" => true,
        "args" => Map.update!(answer, "parts", &Jason.encode!/1)
      }),
      Map.put(event("reply", answer), :request_id, "envelope"),
      Map.put(event("reply", %{"body" => "Yes"}), :request_id, "leaf")
    ]

    assert %{
             conversation: [
               {"person", "Build a site"},
               {"agent", "Approve the preview?"},
               {"person", "Approved"}
             ],
             answers: [%{request: "envelope", option: nil}, %{request: "leaf", option: "approve"}],
             follow_ups: []
           } =
             Person.restore(%{events: events, requests: [request]}, %{person: nil}, fn _, _ ->
               ""
             end)
  end

  test "ignores rejected or uncommitted reply calls" do
    events = [
      event("tool", %{"name" => "reply", "ok" => false, "args" => %{"request_id" => "missing"}}),
      event("tool", %{"name" => "reply", "ok" => true, "args" => %{"request_id" => "missing"}})
    ]

    assert %{conversation: [], answers: []} =
             Person.restore(%{events: events, requests: []}, %{person: nil}, fn _, _ -> "" end)
  end

  test "keeps earlier agent words and consumes only follow-ups actually sent" do
    events = [
      event("prompt", %{"message" => "First"}),
      event("prompt", %{"message" => "Next"}),
      event("prompt", %{"message" => "An answer"})
    ]

    assert %{
             conversation: [
               {"person", "First"},
               {"agent", "Question?"},
               {"person", "Next"},
               {"person", "An answer"}
             ],
             follow_ups: ["Last"]
           } =
             Person.restore(
               %{events: events, requests: []},
               %{person: %{"follow_ups" => ["Next", "Last"]}},
               fn _, _ -> "Question?" end
             )
  end

  test "the initial instruction does not consume an identical follow-up" do
    assert %{follow_ups: ["Same"]} =
             Person.restore(
               %{events: [event("prompt", %{"message" => "Same"})], requests: []},
               %{person: %{"follow_ups" => ["Same"]}},
               fn _, _ -> "" end
             )
  end

  defp event(type, body), do: %{type: type, actor_kind: "human", request_id: nil, body: body}
end
