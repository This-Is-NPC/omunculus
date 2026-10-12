defmodule Omunculus.Participant do
  @moduledoc "Authenticated request participants, stored as JSON identities."

  def agent(name), do: %{"kind" => "agent", "agent" => name}
  def human(issuer, subject), do: %{"kind" => "human", "issuer" => issuer, "subject" => subject}

  def from_context(%{author: "human", issuer: issuer, subject: subject})
      when is_binary(issuer) and issuer != "" and is_binary(subject) and subject != "",
      do: {:ok, human(issuer, subject)}

  def from_context(%{agent: agent}) when is_binary(agent) and agent != "", do: {:ok, agent(agent)}
  def from_context(_ctx), do: {:error, {:request, :missing_participant}}

  def valid?(%{"kind" => "agent", "agent" => name} = identity),
    do: map_size(identity) == 2 and is_binary(name) and name != ""

  def valid?(%{"kind" => "human", "issuer" => issuer, "subject" => subject} = identity),
    do:
      map_size(identity) == 3 and is_binary(issuer) and issuer != "" and is_binary(subject) and
        subject != ""

  def valid?(_identity), do: false

  def label(encoded) when is_binary(encoded), do: encoded |> Jason.decode!() |> label()
  def label(%{"kind" => "agent", "agent" => name}), do: name

  def label(%{"kind" => "human", "issuer" => issuer, "subject" => subject}),
    do: issuer <> ":" <> subject
end
