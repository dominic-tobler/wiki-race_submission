defmodule Player.Engine.Worker do
  @moduledoc false

  # The coordinator traps exits; workers do not. Killing the coordinator kills
  # even a worker blocked in HTTP, without relying on a terminate callback.
  def start(owner, fetch) do
    :erlang.spawn_opt(fn -> loop(owner, fetch) end, [:link, :monitor])
  end

  defp loop(owner, fetch) do
    receive do
      {:fetch, token, url} ->
        send(owner, {:result, self(), token, index_links(fetch.(url))})
        loop(owner, fetch)
    end
  end

  # Page.fetch/1 already resolves, filters and deduplicates links. Compute the
  # visited-set keys here, in parallel, rather than parsing every URL again in
  # the serial coordinator. Injected test fetchers use the same absolute-URL
  # contract as Page.fetch/1.
  defp index_links({:ok, links}) when is_list(links) do
    {:ok, Enum.map(links, &{Player.Engine.Page.key(&1), &1})}
  end

  defp index_links({:ranked, links}), do: {:ok, links}

  defp index_links(other), do: other
end
