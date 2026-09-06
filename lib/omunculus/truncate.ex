defmodule Omunculus.Truncate do
  @moduledoc false

  @max_lines 2_000
  @max_bytes 50 * 1024

  def text(content, opts \\ []) when is_binary(content) do
    max_lines = Keyword.get(opts, :max_lines, @max_lines)
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    {body, truncated?} = clip(content, max_lines, max_bytes)

    if truncated? do
      body <> "\n\n[truncated: output limited to #{max_lines} lines or #{max_bytes} bytes]"
    else
      body
    end
  end

  defp clip(content, max_lines, max_bytes) do
    if byte_size(content) <= max_bytes do
      lines = String.split(content, "\n")

      if length(lines) <= max_lines do
        {content, false}
      else
        {Enum.join(Enum.take(lines, max_lines), "\n"), true}
      end
    else
      sliced = binary_part(content, 0, max_bytes)
      lines = String.split(sliced, "\n")

      body =
        if length(lines) > max_lines,
          do: Enum.join(Enum.take(lines, max_lines), "\n"),
          else: sliced

      {body, true}
    end
  end
end
