defmodule Player.Hybrid.Cache do
  @moduledoc false
  alias Player.Engine.Page

  # The race owns this table. Workers perform HTTP and wait for identical
  # in-flight requests themselves, so there is no serial fetch bottleneck.
  def fetch(table, url, fetcher) do
    key = Page.key(url)

    case :ets.lookup(table, key) do
      [{^key, {:done, result}}] ->
        result

      [{^key, {:busy, owner}}] ->
        if Process.alive?(owner) do
          Process.sleep(10)
        else
          :ets.delete_object(table, {key, {:busy, owner}})
        end

        fetch(table, url, fetcher)

      [] ->
        if :ets.insert_new(table, {key, {:busy, self()}}) do
          try do
            result = fetcher.(url)

            if match?({:ok, _}, result) do
              :ets.update_counter(table, :fetch_count, {2, 1}, {:fetch_count, 0})

              if :ets.info(table, :memory) * :erlang.system_info(:wordsize) < 128 * 1_048_576 do
                :ets.insert(table, {key, {:done, result}})
              end
            end

            result
          after
            :ets.delete_object(table, {key, {:busy, self()}})
          end
        else
          fetch(table, url, fetcher)
        end
    end
  end
end
