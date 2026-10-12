defmodule Omunculus.Participant do
  @moduledoc "Authenticated request participants, stored as JSON identities."

  def agent(name), do: %{"kind" => "agent", "agent" => name}
  def human(issuer, subject), do: %{"kind" => "human", "issuer" => issuer, "subject" => subject}

  def label(encoded) when is_binary(encoded), do: encoded |> Jason.decode!() |> label()
  def label(%{"kind" => "agent", "agent" => name}), do: name

  def label(%{"kind" => "human", "issuer" => issuer, "subject" => subject}),
    do: issuer <> ":" <> subject
end
