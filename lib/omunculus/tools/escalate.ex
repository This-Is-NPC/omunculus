defmodule Omunculus.Tools.Escalate do
  @moduledoc "Merges received requests into one question linked by distinct named origins, through a model or authenticated human command; optional to names a logical route."
  alias Omunculus.Tools.{Args, Out}

  def run(%{args: args}) do
    with nil <- Args.missing(args, ["reason"]),
         {:ok, origins} <- Args.object(args, "origins") do
      if map_size(origins) > 0,
        do:
          Out.ok("", [
            %{
              "type" => "escalate",
              "body" =>
                %{"reason" => args["reason"], "origins" => origins}
                |> Args.put_present("to", args)
            }
          ]),
        else: Out.fail("origins required: a map from distinct part names to received request IDs")
    else
      {:error, message} -> Out.fail(message)
      message -> Out.fail(message)
    end
  end
end
