defmodule EquivalentExchange.Suite do
  @moduledoc """
  The checks of a long-horizon case, a task with `[suite]`, over what an
  execution left, with no model and no network of their own: the evidence is
  recorded data, so a score can be made again from it.

  ```toml
  [suite]
  cap_s = 5400          # seconds the case may take
  cap_usd = 1.5         # dollars the agents may spend
  promote = true        # the site is expected in production
  viewport = "390x844"  # the phone the visual check loads

  [suite.pages]         # page name = words its path holds, "/" for the index
  home = ["/"]
  menu = ["menu", "cardapio"]

  [suite.facts]         # fact name = regular expression the site shows
  whatsapp = '99876-?5432'
  ```

  `checks/2` returns one `%{id, passed, said}` per check; a check that does
  not apply (production when it is not expected and not reached) is left out,
  one that could not be measured has `passed: nil`.

  The evidence, string keys as in `execution.json`: `live`, what the runner
  saw of the deployed site before it was destroyed (`homologation` and
  `production`, each `%{app, status}` or nil; `visual`, the `browser_check`
  call: `ok`, `output`; and `site`, the folder its pages were copied to);
  `requests`; `duration_ms`; `cost`.
  """

  @doc "Whether the case expects the site in production."
  @spec promote?(map) :: boolean
  def promote?(suite), do: suite["promote"] == true

  @doc """
The page paths of a copied site, from its index.html files and named pages.
A folder's path ends in a slash: the server redirects one without, and the
redirect may drop the port the site is served on.
"""
  @spec paths(String.t()) :: [String.t()]
  def paths(site) do
    for file <- Path.wildcard(Path.join(site, "**/*.html")),
        relative = Path.relative_to(file, site),
        uniq: true,
        do: page_path(relative)
  end

  defp page_path("index.html"), do: "/"

  defp page_path(relative) do
    case Path.basename(relative) do
      "index.html" -> "/" <> Path.dirname(relative) <> "/"
      _named -> "/" <> relative
    end
  end

  @spec checks(map, map) :: [%{id: String.t(), passed: boolean | nil, said: String.t()}]
  def checks(suite, evidence) do
    live = evidence["live"] || %{}
    site = live["site"]
    html = site && html(site)

    [
      deployed("homologation", live["homologation"]),
      if(promote?(suite) or live["production"], do: deployed("production", live["production"])),
      pages(suite["pages"] || %{}, site && paths(site)),
      facts(suite["facts"] || %{}, html),
      answered(evidence["requests"] || []),
      visual(live["visual"], suite["viewport"]),
      cap("time", evidence["duration_ms"] && evidence["duration_ms"] / 1000, suite["cap_s"], "s"),
      cap("cost", evidence["cost"], suite["cap_usd"], " USD")
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc "Whether every measured check passed, and what the failed ones said."
  @spec verdict([map]) :: {boolean, String.t()}
  def verdict(checks) do
    failed = Enum.filter(checks, &(&1.passed == false))
    {failed == [], Enum.map_join(failed, "; ", &"#{&1.id}: #{&1.said}")}
  end

  defp check(id, passed, said), do: %{id: id, passed: passed, said: said}

  # The site answers 200 on its index where the case expects it.
  defp deployed(instance, nil), do: check("deployed_#{instance}", false, "never reached")

  defp deployed(instance, %{"status" => 200}),
    do: check("deployed_#{instance}", true, "answers 200")

  defp deployed(instance, %{"status" => status}),
    do: check("deployed_#{instance}", false, "answers #{inspect(status)}, not 200")

  defp pages(_wanted, nil), do: check("pages", false, "no site was copied")

  defp pages(wanted, found) do
    missing =
      for {name, words} <- wanted,
          not Enum.any?(found, &page?(&1, words)),
          do: name

    check(
      "pages",
      missing == [],
      if(missing == [], do: "all found", else: "missing " <> Enum.join(Enum.sort(missing), ", "))
    )
  end

  defp page?(path, words),
    do:
      Enum.any?(
        words,
        &if(&1 == "/", do: path == "/", else: String.contains?(String.downcase(path), &1))
      )

  defp facts(_wanted, nil), do: check("facts", false, "no site was copied")

  defp facts(wanted, html) do
    missing =
      for {name, pattern} <- wanted,
          not Regex.match?(Regex.compile!(pattern, "i"), html),
          do: name

    check(
      "facts",
      missing == [],
      if(missing == [],
        do: "all shown",
        else: "not shown: " <> Enum.join(Enum.sort(missing), ", ")
      )
    )
  end

  defp html(site) do
    site |> Path.join("**/*.html") |> Path.wildcard() |> Enum.map_join(" ", &File.read!/1)
  end

  # No request is still waiting for an answer when the conversation ends.
  defp answered(requests) do
    open = Enum.count(requests, &(&1["status"] == "pending"))
    check("answered", open == 0, if(open == 0, do: "none waiting", else: "#{open} still waiting"))
  end

  # browser_check at the phone's width: no console error, no horizontal overflow.
  defp visual(nil, _viewport), do: check("visual", false, "no deployed site to look at")

  defp visual(%{"output" => output} = look, viewport) do
    errors = String.contains?(output, "console errors:")
    overflow = String.contains?(output, "horizontal overflow")

    cond do
      errors ->
        check("visual", false, "console errors at #{viewport}")

      overflow ->
        check("visual", false, "horizontal overflow at #{viewport}")

      look["ok"] != true ->
        check("visual", false, "the look failed: #{String.slice(output, 0, 200)}")

      true ->
        check("visual", true, "no console errors, no overflow at #{viewport}")
    end
  end

  defp cap(_id, _value, nil, _unit), do: nil
  defp cap(id, nil, _cap, _unit), do: check(id <> "_cap", nil, "not measured")

  defp cap(id, value, cap, unit) do
    said = "#{Float.round(value * 1.0, 2)}#{unit} of #{cap}#{unit}"
    check(id <> "_cap", value <= cap, said)
  end
end
