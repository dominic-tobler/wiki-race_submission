defmodule Player.Hybrid.Guidance do
  @moduledoc "Target-derived link ranking; scores are preferences, not distances."
  alias Player.Engine.Page

  def profile(target, links) do
    frequencies =
      links
      |> Enum.flat_map(&tokens/1)
      |> Enum.frequencies()

    %{
      target: Page.key(target),
      neighbors: MapSet.new(links, &Page.key/1),
      words: frequencies,
      title: MapSet.new(tokens(target))
    }
  end

  def rank(links, profile) do
    indexed = Enum.map(links, &{Page.key(&1), &1})
    overlap = Enum.count(indexed, fn {key, _} -> MapSet.member?(profile.neighbors, key) end)
    # Prefer children of pages whose neighborhoods resemble the target's.
    context = overlap / :math.sqrt(max(length(links), 1))

    Enum.map(indexed, fn {key, url} ->
      words = tokens(url)
      title = Enum.count(words, &MapSet.member?(profile.title, &1))

      related =
        Enum.reduce(words, 0.0, fn word, sum ->
          sum + :math.log(1 + Map.get(profile.words, word, 0))
        end)

      neighbor = if MapSet.member?(profile.neighbors, key), do: 20, else: 0
      exact = if key == profile.target, do: 1_000_000, else: 0
      {key, url, exact + 30 * title + neighbor + related + 2 * context}
    end)
  end

  defp tokens(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:path)
    |> String.split("/")
    |> List.last()
    |> URI.decode()
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(
      &(String.length(&1) < 3 or &1 in ["the", "and", "for", "from", "with", "that"])
    )
    |> Enum.uniq()
  end
end
