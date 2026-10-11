defmodule Omunculus.Tools.Ask do
  @moduledoc """
  Builtin `ask` tool: emits a `request` whose reason is `question` and
  whose `options` are the names given, each calling nothing, so the answer
  is the option chosen and its comment; with `to = "person"` the request is
  the person's to answer. Its manifest's `then` appends `end`.
  """

  alias Omunculus.Tools.{Args, Out}

  @spec run(map) :: map
  def run(%{args: args}) do
    with nil <- Args.missing(args, ["question"]),
         {:ok, options} <- options(args["options"]) do
      body =
        %{"reason" => args["question"], "options" => Map.new(options, &{&1, []})}
        |> Args.put_present("to", args)

      Out.ok("", [%{"type" => "request", "body" => body}])
    else
      {:error, message} -> Out.fail(message)
      message -> Out.fail(message)
    end
  end

  defp options(options) when is_list(options) do
    names = Enum.map(options, &(is_binary(&1) && String.trim(&1)))

    if length(names) >= 2 and Enum.all?(names, &(is_binary(&1) and &1 != "")) and
         length(Enum.uniq(names)) == length(names),
       do: {:ok, names},
       else: {:error, "options takes two or more different answers, each a name"}
  end

  defp options(_options), do: {:error, "options takes two or more different answers, each a name"}
end
