defmodule Omunculus.Tools.Ask do
  @moduledoc """
  Builtin `ask` tool: emits a `request` whose reason is `question` and
  whose `options` are the names given — each a short name of lowercase
  letters, digits, dashes and underscores, what it means said in the
  question — each calling nothing, so the answer
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

  @refused "options takes two or more different answers, each a short name of lowercase letters, digits, dashes and underscores, such as approve or deny; say what each means in question"

  defp options(options) when is_list(options) do
    if length(options) >= 2 and Enum.all?(options, &name?/1) and
         length(Enum.uniq(options)) == length(options),
       do: {:ok, options},
       else: {:error, @refused}
  end

  defp options(_options), do: {:error, @refused}

  defp name?(option), do: is_binary(option) and option =~ ~r/^[a-z0-9][a-z0-9_-]*$/
end
