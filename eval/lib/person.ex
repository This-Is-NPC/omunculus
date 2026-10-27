defmodule EquivalentExchange.Person do
  @moduledoc """
  The person of a task with `[person]`, played by the model of
  `eval/person.toml`: given the conversation so far, ending in what the
  agent last told them, it answers what the agent asks with only the
  task's `facts`, leaving to the agent what they do not cover and offering
  nothing that was not asked, or says the agent asked nothing. Saying so
  of a last message with a question mark, it is asked once more, told the
  message asks something.
  """

  @eval Path.expand("..", __DIR__)

  @instructions """
  You are a person talking with an assistant you asked for something. You know only the FACTS below; they are all you know, and they are true: never say otherwise.
  Read the assistant's last message. If it asks you something or asks you to decide, answer as yourself, in the first person, like a short chat message: give every fact that answers what it asked, with names, numbers and addresses exactly as the facts write them; for anything it asks that the facts do not cover, say you leave it to the assistant. Do not offer facts it did not ask about, and never describe or summarise the assistant's message.
  If its last message asks you nothing, reply exactly NOTHING.
  Write only the message you send, with nothing before or after it: no reasoning, no notes.
  """

  @doc "Restores the person's recorded messages, decisions and unsent follow-ups after an interruption."
  def restore(facts, task, last_words) do
    requests = Map.new(facts.requests, &{&1.id, &1})
    replied = facts.events |> Enum.filter(&(&1.type == "reply")) |> MapSet.new(& &1.request_id)

    initial = %{
      answers: [],
      conversation: [],
      follow_ups: (task.person && task.person["follow_ups"]) || []
    }

    facts.events
    |> Enum.with_index()
    |> Enum.reduce(initial, fn {event, index}, played ->
      case event do
        %{type: "prompt", actor_kind: "human", body: %{"message" => message}} ->
          conversation = played.conversation
          said = last_words.(facts, Enum.take(facts.events, index))

          conversation =
            if conversation != [] and String.trim(said) != "" and
                 {"agent", said} not in conversation,
               do: conversation ++ [{"agent", said}],
               else: conversation

          remaining =
            case {conversation, played.follow_ups} do
              {[_ | _], [^message | rest]} -> rest
              _ -> played.follow_ups
            end

          %{played | conversation: conversation ++ [{"person", message}], follow_ups: remaining}

        %{
          type: "tool",
          actor_kind: "human",
          body: %{"name" => "reply", "ok" => true, "args" => args}
        } ->
          if MapSet.member?(replied, args["request_id"]) do
            request = Map.fetch!(requests, args["request_id"])

            %{
              played
              | answers: played.answers ++ EquivalentExchange.Requests.answers(request, args),
                conversation:
                  played.conversation ++ [{"agent", request.reason}, {"person", args["body"]}]
            }
          else
            played
          end

        _ ->
          played
      end
    end)
  end

  @doc "The person's reply to the `conversation` ([{who, text}]), or :nothing when they were asked nothing."
  @spec reply(String.t(), [{String.t(), String.t()}]) ::
          {:ok, String.t() | :nothing} | {:error, term}
  def reply(facts, conversation) do
    transcript =
      Enum.map_join(conversation, "\n\n", fn {who, text} -> "#{String.upcase(who)}: #{text}" end)

    {_who, last} = List.last(conversation)

    case ask(facts, transcript) do
      {:ok, :nothing} ->
        if String.contains?(last, "?"),
          do:
            ask(
              facts,
              transcript <> "\n\n(The assistant's last message asks you something: answer it.)"
            ),
          else: {:ok, :nothing}

      other ->
        other
    end
  end

  defp ask(facts, transcript) do
    model = Toml.decode_file!(Path.join(@eval, "person.toml"))["model"]

    case Req.post(model["url"],
           json: %{
             model: model["model"],
             max_tokens: 2000,
             system: @instructions <> "\nFACTS:\n" <> facts,
             messages: [%{role: "user", content: transcript}]
           },
           headers: [
             {"x-api-key", System.fetch_env!(model["key_env"])},
             {"anthropic-version", "2023-06-01"}
           ],
           receive_timeout: 120_000,
           retry: :transient,
           max_retries: 4
         ) do
      {:ok, %Req.Response{status: 200, body: %{"content" => content}}} ->
        said = Omunculus.Tools.Record.said(%{"content" => content}) |> String.trim()
        {:ok, if(said in ["", "NOTHING"], do: :nothing, else: said)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:person, status, body}}

      {:error, reason} ->
        {:error, {:person, reason}}
    end
  end
end
