# SPDX-FileCopyrightText: 2026 Mariano Pictet and contributors
# SPDX-License-Identifier: AGPL-3.0-only

defmodule IdejoHubWeb.Accessibility do
  @moduledoc """
  Hub NF-07: checks a member page for what Idejo's AX-01 asks of every page: keyboard operation, landmarks
  and headings, and names for what can be focused. It reads the HTML only, so colour
  contrast, the visible focus ring and the real focus order are checked by hand (see
  Idejo's `docs/accessibility.md`). Ported from Idejo's `test/support/accessibility.ex`, so
  member pages meet the same standard as Idejo's own (Hub NF-07).

  `audit/2` returns a list of problems, empty when the page passes.
  """

  @interactive ~w(a button input select textarea summary details label option)
  @labelled ~w(input select textarea)
  @not_labelled_types ~w(hidden submit button reset image)

  @doc """
  Audits a whole HTML document, or with `page: false` a part of one (a LiveView's render),
  leaving out the checks of the whole page (language, landmarks, headings). Returns the
  problems found, as readable strings.
  """
  @spec audit(String.t(), keyword()) :: [String.t()]
  def audit(html, opts \\ []) do
    page? = Keyword.get(opts, :page, true)

    tree =
      if page?,
        do: html |> LazyHTML.from_document() |> LazyHTML.to_tree(),
        else: html |> LazyHTML.from_fragment() |> LazyHTML.to_tree()

    nodes = flatten(tree, [])
    ids = for {_tag, attrs, _} = node <- nodes, id = attr(node, "id"), do: {id, attrs}
    id_set = MapSet.new(ids, &elem(&1, 0))

    label_for =
      for {"label", _, _} = node <- nodes, f = attr(node, "for"), into: MapSet.new(), do: f

    page_checks =
      if page?,
        do:
          check_lang(nodes) ++
            check_landmarks(nodes) ++ check_skip_link(nodes) ++ check_headings(nodes),
        else: []

    Enum.concat([
      page_checks,
      check_ids(ids, nodes, id_set),
      Enum.flat_map(nodes, &check_node(&1, label_for, tree))
    ])
  end

  # Every element, with its ancestors' tags kept in a "_ancestors" pseudo-attribute so that
  # labels wrapping their control and hidden subtrees can be recognised.
  defp flatten(nodes, ancestors) when is_list(nodes),
    do: Enum.flat_map(nodes, &flatten(&1, ancestors))

  defp flatten({tag, attrs, children}, ancestors) do
    node = {tag, [{"_ancestors", ancestors} | attrs], children}
    [node | flatten(children, [{tag, attrs} | ancestors])]
  end

  defp flatten(_text_or_comment, _ancestors), do: []

  defp attr({_tag, attrs, _children}, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _ -> nil
    end)
  end

  defp ancestors({_tag, attrs, _}), do: attrs |> List.keyfind("_ancestors", 0) |> elem(1)

  ## Page-level checks

  defp check_lang(nodes) do
    case Enum.find(nodes, &match?({"html", _, _}, &1)) do
      nil -> []
      html -> if attr(html, "lang") in [nil, ""], do: ["<html> has no lang"], else: []
    end
  end

  defp check_landmarks(nodes) do
    mains = Enum.filter(nodes, &(elem(&1, 0) == "main" or attr(&1, "role") == "main"))
    navs = Enum.filter(nodes, &(elem(&1, 0) == "nav"))
    nav_names = Enum.map(navs, &(attr(&1, "aria-label") || attr(&1, "aria-labelledby")))

    List.flatten([
      if(length(mains) != 1, do: ["#{length(mains)} <main> landmarks, not one"], else: []),
      # At most one footer.
      if(Enum.count(nodes, &(elem(&1, 0) == "footer")) > 1, do: ["several <footer>s"], else: []),
      if(length(navs) > 1 and (nil in nav_names or Enum.uniq(nav_names) != nav_names),
        do: ["several <nav> landmarks without distinct aria-labels"],
        else: []
      )
    ])
  end

  # The first thing the keyboard reaches leads past the navigation, to <main>.
  defp check_skip_link(nodes) do
    main_id = Enum.find_value(nodes, &(elem(&1, 0) == "main" && attr(&1, "id")))
    first = Enum.find(nodes, &focusable?/1)

    if main_id && first && elem(first, 0) == "a" && attr(first, "href") == "#" <> main_id,
      do: [],
      else: ["the first focusable element is not a link to <main>'s id"]
  end

  defp focusable?({tag, _, _} = node) do
    (tag in ~w(a button input select textarea summary) and not hidden?(node) and
       attr(node, "type") != "hidden" and (tag != "a" or attr(node, "href") != nil)) or
      (attr(node, "tabindex") not in [nil, "-1"] and not hidden?(node))
  end

  defp check_headings(nodes) do
    levels =
      for {<<"h", d>>, _, _} = node <- nodes, d in ?1..?6, not hidden?(node), do: d - ?0

    h1s = Enum.count(levels, &(&1 == 1))

    skips =
      levels
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.filter(fn [a, b] -> b > a + 1 end)
      |> Enum.map(fn [a, b] -> "heading level skips from h#{a} to h#{b}" end)

    if(h1s == 1, do: [], else: ["#{h1s} <h1> headings, not one"]) ++ Enum.uniq(skips)
  end

  defp check_ids(ids, nodes, id_set) do
    duplicates =
      ids
      |> Enum.frequencies_by(&elem(&1, 0))
      |> Enum.filter(fn {_id, n} -> n > 1 end)
      |> Enum.map(fn {id, n} -> "id #{inspect(id)} is used #{n} times" end)

    broken =
      for node <- nodes,
          name <- ~w(for aria-labelledby aria-describedby aria-controls),
          value = attr(node, name),
          ref <- String.split(value),
          not MapSet.member?(id_set, ref),
          do: "#{name}=#{inspect(ref)} on <#{elem(node, 0)}> names no element"

    duplicates ++ Enum.uniq(broken)
  end

  ## Element checks

  defp check_node({tag, _, _} = node, label_for, tree) do
    if hidden?(node), do: [], else: check_element(tag, node, label_for, tree)
  end

  defp check_element(tag, node, label_for, tree) do
    List.flatten([
      check_tabindex(node),
      check_click(tag, node),
      check_name(tag, node, tree),
      check_label(tag, node, label_for),
      check_img(tag, node)
    ])
  end

  defp check_tabindex(node) do
    case Integer.parse(attr(node, "tabindex") || "") do
      {n, _} when n > 0 -> ["#{describe(node)} has tabindex #{n}: it breaks the focus order"]
      _ -> []
    end
  end

  # Something clicked must be reachable and usable from the keyboard.
  defp check_click(tag, node) do
    clickable? = attr(node, "phx-click") != nil
    keyboard? = tag in @interactive or (attr(node, "role") == "button" and attr(node, "tabindex"))

    cond do
      clickable? and not keyboard? ->
        ["#{describe(node)} reacts to clicks but not to keys"]

      tag == "a" and attr(node, "href") in [nil, ""] ->
        ["#{describe(node)} is a link with no href"]

      true ->
        []
    end
  end

  defp check_name(tag, node, tree) when tag in ~w(a button summary) do
    if accessible_name(node, tree) == "",
      do: ["#{describe(node)} has no accessible name"],
      else: []
  end

  defp check_name(_tag, _node, _tree), do: []

  defp check_label(tag, node, label_for) when tag in @labelled do
    labelled? =
      attr(node, "type") in @not_labelled_types or
        attr(node, "aria-label") not in [nil, ""] or
        attr(node, "aria-labelledby") != nil or
        attr(node, "title") not in [nil, ""] or
        MapSet.member?(label_for, attr(node, "id")) or
        Enum.any?(ancestors(node), &(elem(&1, 0) == "label"))

    if labelled?, do: [], else: ["#{describe(node)} has no label"]
  end

  defp check_label(_tag, _node, _label_for), do: []

  defp check_img("img", node) do
    if attr(node, "alt") == nil, do: ["#{describe(node)} has no alt"], else: []
  end

  defp check_img(_tag, _node), do: []

  ## Helpers

  # Hidden from everyone, so not checked: hidden, aria-hidden, Tailwind's `hidden` class
  # (display: none) with no breakpoint showing it again, or inside such an element or a
  # <template>.
  defp hidden?(node) do
    own = [{elem(node, 0), Enum.reject(elem(node, 1), &match?({"_ancestors", _}, &1))}]

    Enum.any?(own ++ ancestors(node), fn {tag, attrs} ->
      tag == "template" or List.keymember?(attrs, "hidden", 0) or
        List.keyfind(attrs, "aria-hidden", 0) == {"aria-hidden", "true"} or
        display_none?(List.keyfind(attrs, "class", 0))
    end)
  end

  defp display_none?({"class", class}) do
    classes = String.split(class)

    "hidden" in classes and
      not Enum.any?(classes, &(&1 =~ ~r/^[a-z0-9-]+:(block|flex|inline|grid|table)/))
  end

  defp display_none?(nil), do: false

  defp accessible_name(node, tree) do
    by_reference =
      case attr(node, "aria-labelledby") do
        nil -> ""
        refs -> refs |> String.split() |> Enum.map_join(" ", &text_of_id(tree, &1))
      end

    [attr(node, "aria-label"), by_reference, visible_text(elem(node, 2)), attr(node, "title")]
    |> Enum.map(&String.trim(&1 || ""))
    |> Enum.find("", &(&1 != ""))
  end

  defp text_of_id(tree, id) do
    tree
    |> flatten([])
    |> Enum.find_value("", fn node ->
      if attr(node, "id") == id, do: visible_text(elem(node, 2))
    end)
  end

  # Text a screen reader reads: text nodes and image alts, skipping aria-hidden parts.
  defp visible_text(children) do
    Enum.map_join(children, " ", fn
      text when is_binary(text) ->
        text

      {"img", attrs, _} ->
        alt(attrs)

      {_tag, attrs, kids} ->
        if {"aria-hidden", "true"} in attrs, do: "", else: visible_text(kids)

      _comment ->
        ""
    end)
  end

  defp alt(attrs) do
    case List.keyfind(attrs, "alt", 0) do
      {"alt", value} -> value
      nil -> ""
    end
  end

  defp describe({tag, _, _} = node) do
    id = attr(node, "id")
    class = attr(node, "class")

    cond do
      id -> "<#{tag} id=#{inspect(id)}>"
      class -> "<#{tag} class=#{inspect(class)}>"
      true -> "<#{tag}>"
    end
  end
end
