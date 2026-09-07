defmodule Omunculus.Policy do
  @moduledoc false

  @bands ~w(granted negotiable human forbidden)

  def normalize(entry, opts \\ []) when is_map(entry) do
    mode = entry["mode"] || "allow"
    catalog = Omunculus.Tools.names()
    catalog_version = opts[:catalog_version]

    with {:ok, granted} <- expand_band(entry["granted"] || []),
         {:ok, negotiable} <- expand_band(entry["negotiable"] || []),
         {:ok, human} <- expand_band(entry["human"] || []),
         {:ok, deny} <- expand_band(entry["deny"] || []) do
      bands =
        catalog
        |> Enum.map(fn name ->
          band =
            cond do
              name in deny -> "forbidden"
              name in human -> "human"
              name in negotiable -> "negotiable"
              name in granted -> "granted"
              mode == "allow" -> "granted"
              true -> "forbidden"
            end

          {name, band}
        end)
        |> maybe_forbid_new_catalog_tools(mode, catalog_version)
        |> Enum.group_by(fn {_name, band} -> band end, fn {name, _band} -> name end)
        |> Map.new(fn {band, names} -> {band, Enum.sort(names)} end)

      {:ok, ensure_all_bands(bands)}
    end
  end

  def intersect(a, b) do
    tools =
      @bands
      |> Enum.flat_map(fn band -> Map.get(a, band, []) end)
      |> Enum.uniq()
      |> Enum.concat(Enum.flat_map(@bands, &Map.get(b, &1, [])))
      |> Enum.uniq()

    tools
    |> Enum.map(fn tool ->
      band_a = band_of(a, tool)
      band_b = band_of(b, tool)
      {tool, intersect_bands(band_a, band_b)}
    end)
    |> Enum.group_by(fn {_tool, band} -> band end, fn {tool, _band} -> tool end)
    |> Map.new(fn {band, names} -> {band, Enum.sort(names)} end)
    |> ensure_all_bands()
  end

  def table(config) when is_map(config) do
    profiles = Map.keys(config.presets)
    depths = if config.policy == %{}, do: ["0", "1", "2"], else: Map.keys(config.policy)
    # "default" is a placeholder until phase 4 (workspaces as session members).
    workspaces = if config.workspaces == %{}, do: ["default"], else: Map.keys(config.workspaces)
    catalog_version = config.session[:tools_catalog]

    try do
      Enum.reduce(profiles, %{}, fn profile, acc ->
        Enum.reduce(depths, acc, fn depth, acc_depth ->
          Enum.reduce(workspaces, acc_depth, fn workspace, acc_ws ->
            profile_policy = preset_policy(config, profile)
            depth_policy = Map.get(config.policy, depth, %{})
            workspace_policy = workspace_policy(config, workspace)

            with {:ok, profile_bands} <-
                   normalize(profile_policy, catalog_version: catalog_version),
                 {:ok, depth_bands} <- normalize(depth_policy, catalog_version: catalog_version),
                 {:ok, workspace_bands} <-
                   normalize(workspace_policy, catalog_version: catalog_version) do
              bands = intersect(intersect(profile_bands, depth_bands), workspace_bands)
              Map.put(acc_ws, {profile, depth, workspace}, bands)
            else
              {:error, _} = error -> throw(error)
            end
          end)
        end)
      end)
    catch
      {:error, _} = error -> error
    end
  end

  def hash(table) when is_map(table) do
    sorted =
      table
      |> Enum.sort_by(fn {{profile, depth, workspace}, _bands} ->
        {profile, depth, workspace}
      end)
      |> Enum.map(fn {{profile, depth, workspace}, bands} ->
        %{
          "profile" => profile,
          "depth" => depth,
          "workspace" => workspace,
          "bands" => bands
        }
      end)

    :crypto.hash(:sha256, Jason.encode!(sorted))
    |> Base.encode16(case: :lower)
  end

  def line(table, profile, depth, workspace) do
    key = {profile, to_string(depth), workspace}

    case Map.fetch(table, key) do
      {:ok, bands} -> {:ok, bands}
      :error -> {:error, {:no_policy_line, profile, to_string(depth), workspace}}
    end
  end

  def fits_ceiling?(profile_bands, ceiling_bands) do
    Enum.all?(Map.get(profile_bands, "granted", []), fn name ->
      band_of(ceiling_bands, name) != "forbidden"
    end)
  end

  def authority(bands) do
    MapSet.new(Map.get(bands, "granted", []) ++ Map.get(bands, "negotiable", []))
  end

  @doc "Directory discovery scope for a depth policy entry (`subtree` or `session`)."
  def directory_scope(entry) when is_map(entry) do
    entry["directory"] || entry[:directory] || "subtree"
  end

  def directory_scope(_), do: "subtree"

  def narrow(bands, tool_names) when is_list(tool_names) do
    granted = Map.get(bands, "granted", [])

    case Enum.find(tool_names, &(&1 not in granted)) do
      nil ->
        moved =
          Map.get(bands, "granted", []) ++
            Map.get(bands, "negotiable", []) ++
            Map.get(bands, "human", [])

        {:ok,
         %{
           "granted" => Enum.sort(tool_names),
           "negotiable" => [],
           "human" => [],
           "forbidden" =>
             Enum.sort((Map.get(bands, "forbidden", []) ++ (moved -- tool_names)) |> Enum.uniq())
         }}

      name ->
        {:error, {:tools_flag_outside_granted, name}}
    end
  end

  defp expand_band(names) do
    Omunculus.Tools.expand_list(names)
  end

  defp preset_policy(config, profile) do
    case Map.fetch(config.presets, profile) do
      {:ok, preset} -> preset[:policy] || %{}
      :error -> %{}
    end
  end

  defp workspace_policy(config, workspace) do
    case Map.fetch(config.workspaces, workspace) do
      {:ok, ws} -> ws.policy || %{}
      :error -> %{}
    end
  end

  defp band_of(bands, tool) do
    Enum.find_value(@bands, "forbidden", fn band ->
      if tool in Map.get(bands, band, []), do: band
    end)
  end

  defp intersect_bands("forbidden", _), do: "forbidden"
  defp intersect_bands(_, "forbidden"), do: "forbidden"
  defp intersect_bands("human", _), do: "human"
  defp intersect_bands(_, "human"), do: "human"
  defp intersect_bands("granted", "granted"), do: "granted"
  defp intersect_bands("negotiable", _), do: "negotiable"
  defp intersect_bands(_, "negotiable"), do: "negotiable"
  defp intersect_bands(_, _), do: "forbidden"

  defp maybe_forbid_new_catalog_tools(assignments, "allow", catalog_version)
       when is_binary(catalog_version) and catalog_version != "" do
    if Omunculus.Tools.catalog_version() > catalog_version do
      pinned = catalog_at_version(catalog_version)

      Enum.map(assignments, fn {name, band} ->
        if name not in pinned and band == "granted", do: {name, "forbidden"}, else: {name, band}
      end)
    else
      assignments
    end
  end

  defp maybe_forbid_new_catalog_tools(assignments, _mode, _catalog_version), do: assignments

  defp catalog_at_version("1"), do: Omunculus.Tools.names()

  defp catalog_at_version(_version), do: []

  defp ensure_all_bands(bands) do
    Map.merge(
      %{"granted" => [], "negotiable" => [], "human" => [], "forbidden" => []},
      bands
    )
  end
end
