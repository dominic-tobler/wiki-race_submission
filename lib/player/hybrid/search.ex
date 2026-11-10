defmodule Player.Hybrid.Search do
  @moduledoc "A shared fetch cache with independent BFS and target-guided search trees."
  use GenServer, restart: :temporary
  alias Player.Engine.{Page, Progress, Search}
  alias Player.Hybrid.{Cache, Guidance}

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({start, target, options}) do
    cap =
      Keyword.get(
        options,
        :max_concurrency,
        Application.get_env(:player, :max_concurrency, 12)
      )

    if is_integer(cap) and cap > 0 do
      init_search(start, target, Keyword.put(options, :max_concurrency, cap))
    else
      {:stop, :invalid_max_concurrency}
    end
  end

  defp init_search(start, target, options) do
    table = :ets.new(:race_cache, [:public, read_concurrency: true, write_concurrency: true])
    Progress.register(self(), WikiRace.Status.new(frontier_size: 1))
    send(self(), :start)

    {:ok,
     %{
       start: start,
       target: target,
       options: options,
       table: table,
       lanes: [],
       best: [],
       bootstrap: nil,
       done: MapSet.new(),
       finished: false
     }}
  end

  @impl true
  def handle_info(:start, state) do
    if Page.key(state.start) == Page.key(state.target) do
      WikiRace.Harness.report_exhausted()
      Progress.put(WikiRace.Status.new(state: :exhausted))
      {:noreply, %{state | finished: true}}
    else
      bootstrap(state)
    end
  end

  @impl true
  def handle_info(:profile_timeout, %{lanes: []} = state) do
    stop_bootstrap(state)
    handle_info({:profile, Guidance.profile(state.target, [])}, %{state | bootstrap: nil})
  end

  def handle_info({:profile, profile}, %{lanes: []} = state) do
    if state.bootstrap, do: Process.cancel_timer(elem(state.bootstrap, 1))
    owner = self()
    fetcher = Keyword.get(state.options, :fetch, &Page.fetch/1)
    fetch = fn url -> Cache.fetch(state.table, url, fetcher) end

    ranked = fn url ->
      case fetch.(url) do
        {:ok, links} -> {:ranked, Guidance.rank(links, profile)}
        error -> error
      end
    end

    cap =
      Keyword.get(
        state.options,
        :max_concurrency,
        Application.get_env(:player, :max_concurrency, 64)
      )

    guided = if cap > 1, do: max(div(cap, 4), 1), else: 0

    opts =
      Keyword.merge(state.options, report_to: owner, fetch: fetch, max_concurrency: cap - guided)

    {:ok, bfs} = Search.start_link({state.start, state.target, opts})

    lanes =
      if guided > 0 do
        opts =
          Keyword.merge(opts, guided: true, improve: true, fetch: ranked, max_concurrency: guided)

        {:ok, greedy} = Search.start_link({state.start, state.target, opts})
        [bfs, greedy]
      else
        [bfs]
      end

    send(self(), :poll)
    {:noreply, %{state | lanes: lanes, bootstrap: nil}}
  end

  def handle_info({:lane_found, pid, path}, %{finished: false} = state) do
    state =
      if state.best == [] or length(path) < length(state.best) do
        state = %{state | best: path}
        Progress.put(snapshot(state))
        WikiRace.Harness.report(path)
        Enum.each(state.lanes, &send(&1, {:bound, length(path) - 1}))
        state
      else
        state
      end

    # The BFS lane stops at its first path; guided search keeps improving.
    state =
      if pid == hd(state.lanes), do: %{state | done: MapSet.put(state.done, pid)}, else: state

    {:noreply, settle(state)}
  end

  def handle_info({:lane_exhausted, pid}, %{finished: false} = state) do
    {:noreply, settle(%{state | done: MapSet.put(state.done, pid)})}
  end

  def handle_info(:poll, %{finished: false} = state) do
    Progress.put(snapshot(state))
    Process.send_after(self(), :poll, 100)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: stop(state)

  defp settle(state) do
    if MapSet.size(state.done) == length(state.lanes) do
      if state.best == [], do: WikiRace.Harness.report_exhausted()
      status = if state.best == [], do: :exhausted, else: :found
      Progress.put(%{snapshot(state) | state: status, frontier_size: 0})
      stop(state)
      %{state | finished: true}
    else
      Progress.put(snapshot(state))
      state
    end
  end

  defp bootstrap(state) do
    # Bootstrap is linked so cancellation also cancels target profiling.
    owner = self()
    fetcher = Keyword.get(state.options, :fetch, &Page.fetch/1)

    pid =
      spawn_link(fn ->
        links =
          try do
            case Cache.fetch(state.table, state.target, fetcher) do
              {:ok, links} -> links
              _ -> []
            end
          rescue
            _ -> []
          catch
            :exit, _ -> []
          end

        send(owner, {:profile, Guidance.profile(state.target, links)})
      end)

    timer =
      Process.send_after(
        self(),
        :profile_timeout,
        Keyword.get(state.options, :worker_timeout, 5_000)
      )

    {:noreply, %{state | bootstrap: {pid, timer}}}
  end

  defp stop(state) do
    stop_bootstrap(state)

    Enum.each(state.lanes, fn pid ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)
  end

  defp stop_bootstrap(%{bootstrap: nil}), do: :ok

  defp stop_bootstrap(%{bootstrap: {pid, timer}}) do
    Process.cancel_timer(timer)
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  defp snapshot(state) do
    statuses = Enum.map(state.lanes, &Progress.get/1)

    WikiRace.Status.new(
      state: if(state.best == [], do: :running, else: :found),
      path: state.best,
      current_url: statuses |> Enum.map(& &1.current_url) |> List.last(),
      frontier_size: Enum.sum(Enum.map(statuses, & &1.frontier_size)),
      visited_count:
        case :ets.lookup(state.table, :fetch_count) do
          [{_, count}] -> count
          [] -> 0
        end
    )
  end
end
