defmodule Omunculus.CLI.UI.Text do
  @moduledoc "Shared terminal wrapping; prefixes belong to the layout."

  def columns(io) do
    device = if io == :stderr, do: :standard_error, else: io

    case :io.columns(device) do
      {:ok, width} when width > 0 -> width
      _ -> terminal_columns(io)
    end
  end

  # Escript's non-interactive IO server can return :enotsup even when its
  # output is a TTY. Read that exact descriptor, not an unrelated /dev/tty.
  defp terminal_columns(io) when io in [:stdio, :standard_io, :stderr, :standard_error] do
    fd = if io in [:stderr, :standard_error], do: 2, else: 1

    with executable when is_binary(executable) <- System.find_executable("stty"),
         {size, 0} <-
           System.cmd(executable, ["-F", "/proc/#{System.pid()}/fd/#{fd}", "size"],
             stderr_to_stdout: true
           ),
         [_rows, columns] <- String.split(size),
         {width, ""} when width > 0 <- Integer.parse(columns) do
      width
    else
      _ -> 100
    end
  end

  defp terminal_columns(_io), do: 100

  def lines(text, width, prefix \\ "", continuation \\ nil) do
    continuation = continuation || prefix

    text
    |> String.replace("\t", "    ")
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      indent = Regex.run(~r/^ */, line) |> hd()

      wrap(
        String.graphemes(String.replace_prefix(line, indent, "")),
        width,
        prefix <> indent,
        continuation <> indent
      )
    end)
  end

  defp wrap([], _width, prefix, _continuation), do: [prefix]

  defp wrap(chars, width, prefix, continuation) do
    {fit, rest} = take(chars, max(width - cells(prefix), 1), [])
    {fit, rest} = word_boundary(fit, rest)

    [
      prefix <> Enum.join(fit)
      | if(rest == [], do: [], else: wrap(rest, width, continuation, continuation))
    ]
  end

  defp take([], _space, acc), do: {Enum.reverse(acc), []}

  defp take([c | rest] = chars, space, acc) do
    if cells(c) <= space or acc == [] do
      take(rest, space - cells(c), [c | acc])
    else
      {Enum.reverse(acc), chars}
    end
  end

  defp word_boundary(fit, []), do: {fit, []}

  defp word_boundary(fit, rest) do
    case fit |> Enum.with_index() |> Enum.filter(fn {c, _} -> c == " " end) |> List.last() do
      {_, index} when index > 0 ->
        {head, tail} = Enum.split(fit, index + 1)
        {head, tail ++ rest}

      _ ->
        {fit, rest}
    end
  end

  def cells(text) do
    text
    |> String.graphemes()
    |> Enum.reduce(0, fn g, n ->
      # Combining sequences occupy one cell; CJK and emoji occupy two.
      n +
        if Regex.match?(
             ~r/[\x{1100}-\x{115F}\x{2329}\x{232A}\x{2E80}-\x{A4CF}\x{AC00}-\x{D7A3}\x{F900}-\x{FAFF}\x{FE10}-\x{FE19}\x{FE30}-\x{FE6F}\x{FF01}-\x{FF60}\x{FFE0}-\x{FFE6}\x{1F000}-\x{1FAFF}\x{20000}-\x{3FFFF}\x{FE0F}]/u,
             g
           ),
           do: 2,
           else: 1
    end)
  end
end
