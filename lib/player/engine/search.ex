defmodule Player.Engine.Search do
  @moduledoc """
  Level-synchronous BFS with monitored, replaceable fetch workers.

  Each level gets up to 64 workers by default; remaining articles are queued.
  Set `:player, :max_concurrency` to tune the limit. Newly discovered
  URLs are held behind a depth barrier; a parent map both deduplicates discovery
  and reconstructs the shortest path. Status lives in ETS so a large merge cannot
  block the harness's progress polls.
  """
  use GenServer, restart: :temporary
  require Logger
  alias Player.Engine.{Page, Progress, Worker}

  def start_link({start, target, options}) do
    GenServer.start_link(__MODULE__, {start, target, options})
  end

  @impl true
  def init({start, target, options}) do
    max_concurrency =
      Keyword.get(
        options,
        :max_concurrency,
        Application.get_env(:player, :max_concurrency, 12)
      )

    if is_integer(max_concurrency) and max_concurrency > 0 do
      init_search(start, target, options, max_concurrency)
    else
      {:stop, :invalid_max_concurrency}
    end
  end

  defp init_search(start, target, options, max_concurrency) do
    Process.flag(:trap_exit, true)

    state = %{
      target: Page.key(target),
      guided: Keyword.get(options, :guided, false),
      priority: :gb_sets.empty(),
      improve: Keyword.get(options, :improve, false),
      bound: nil,
      depths: %{Page.key(start) => 0},
      sequence: 0,
      report_to: Keyword.get(options, :report_to),
      parents: %{Page.key(start) => nil},
      urls: %{Page.key(start) => start},
      queue: :queue.from_list([{start, 0}]),
      queued_count: 1,
      next: [],
      next_count: 0,
      workers: %{},
      active: 0,
      max_concurrency: max_concurrency,
      fetch: Keyword.get(options, :fetch, &Page.fetch/1),
      timeout: Keyword.get(options, :worker_timeout, 5_000),
      retries: Keyword.get(options, :retries, 2),
      snapshot: WikiRace.Status.new(frontier_size: 1)
    }

    Progress.register(self(), state.snapshot)
    send(self(), :start)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.snapshot, state}

  @impl true
  def handle_info(:start, state) do
    # The referee rejects a one-article path and repeated articles, so equal
    # endpoints have no admissible walk under this competition's rules.
    if Map.has_key?(state.parents, state.target) do
      {:noreply, finish(state, :exhausted)}
    else
      {:noreply,
       state |> resize_workers(if(state.guided, do: state.max_concurrency, else: 1)) |> schedule()}
    end
  end

  def handle_info({:result, pid, token, result}, state) do
    case state.workers[pid] do
      %{job: {url, attempt, ^token, timer}} = worker ->
        Process.cancel_timer(timer)
        state = put_in(state.workers[pid], %{worker | job: nil})
        state = %{state | active: state.active - 1}

        state =
          case result do
            {:ok, links} when is_list(links) -> accept(state, url, links)
            other -> retry(state, url, attempt, other)
          end

        {:noreply, schedule(state)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:timeout, pid, token}, state) do
    case state.workers[pid] do
      %{job: {_, _, ^token, _}} -> Process.exit(pid, :kill)
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.workers, pid) do
      {%{ref: ^ref, job: job}, workers} ->
        state = %{state | workers: workers}

        state =
          case job do
            {url, attempt, _, timer} ->
              Process.cancel_timer(timer)
              state = %{state | active: state.active - 1}
              retry(state, url, attempt, {:worker_exit, reason})

            nil ->
              state
          end

        {:noreply, state |> add_worker() |> schedule()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:bound, hops}, %{snapshot: %{state: :running}} = state) do
    if is_nil(state.bound) or hops < state.bound do
      {:noreply, state |> tighten(hops) |> schedule()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:bound, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_workers(state)

  defp add_worker(state) do
    {pid, ref} = Worker.start(self(), state.fetch)
    put_in(state.workers[pid], %{ref: ref, job: nil})
  end

  defp accept(state, url, links) do
    state = put_in(state.snapshot.visited_count, state.snapshot.visited_count + 1)
    parent = Page.key(url)
    depth = state.depths[parent] + 1
    links = if expandable?(state, url), do: links, else: []

    state =
      Enum.reduce(links, state, fn entry, acc ->
        {key, link, score} =
          case entry do
            {key, link} -> {key, link, 0}
            triple -> triple
          end

        if (not is_nil(acc.bound) and depth >= acc.bound) or
             (Map.has_key?(acc.parents, key) and
                not (acc.guided and acc.improve and depth < acc.depths[key])) do
          acc
        else
          acc = %{
            acc
            | parents: Map.put(acc.parents, key, parent),
              depths: Map.put(acc.depths, key, depth),
              sequence: acc.sequence + 1,
              urls: Map.put(acc.urls, key, link)
          }

          cond do
            key == acc.target or (not is_nil(acc.bound) and depth + 1 >= acc.bound) ->
              acc

            acc.guided ->
              %{
                acc
                | priority: :gb_sets.add({-score, acc.sequence, link, 0}, acc.priority),
                  queued_count: acc.queued_count + 1
              }

            true ->
              %{acc | next: [link | acc.next], next_count: acc.next_count + 1}
          end
        end
      end)

    cond do
      Map.has_key?(state.parents, state.target) ->
        path = path(state.target, state, [])

        hops = length(path) - 1

        if is_nil(state.bound) or hops < state.bound do
          if state.report_to,
            do: send(state.report_to, {:lane_found, self(), path}),
            else: WikiRace.Harness.report(path)

          state = put_in(state.snapshot.path, path)
          if state.improve, do: tighten(state, hops), else: finish(state, :found)
        else
          state
        end

      true ->
        state
    end
  end

  defp retry(state, url, attempt, reason) do
    if attempt < state.retries and expandable?(state, url) do
      if state.guided do
        %{
          state
          | priority: :gb_sets.add({-1.0e9, 0, url, attempt + 1}, state.priority),
            queued_count: state.queued_count + 1
        }
      else
        %{
          state
          | queue: :queue.in_r({url, attempt + 1}, state.queue),
            queued_count: state.queued_count + 1
        }
      end
    else
      Logger.warning("BFS skipped #{url} after #{attempt + 1} attempts: #{inspect(reason)}")
      state
    end
  end

  defp schedule(%{snapshot: %{state: status}} = state) when status != :running, do: state

  defp schedule(state) do
    state =
      Enum.reduce_while(state.workers, state, fn {pid, worker}, acc ->
        case {worker.job, dequeue(acc)} do
          {_, {:empty, _}} ->
            {:halt, acc}

          {nil, {{:value, {url, attempt}}, queue}} ->
            token = make_ref()
            timer = Process.send_after(self(), {:timeout, pid, token}, acc.timeout)
            send(pid, {:fetch, token, url})

            acc = %{
              acc
              | queue: queue.queue,
                priority: queue.priority,
                queued_count: acc.queued_count - 1,
                active: acc.active + 1
            }

            acc = put_in(acc.workers[pid].job, {url, attempt, token, timer})
            {:cont, put_in(acc.snapshot.current_url, url)}

          _ ->
            {:cont, acc}
        end
      end)

    busy = state.active

    cond do
      busy == 0 and state.queued_count == 0 and state.next == [] ->
        finish(state, :exhausted)

      busy == 0 and state.queued_count == 0 ->
        queue = state.next |> Enum.reverse() |> Enum.map(&{&1, 0}) |> :queue.from_list()
        state = resize_workers(state, min(state.next_count, state.max_concurrency))
        schedule(%{state | queue: queue, queued_count: state.next_count, next: [], next_count: 0})

      true ->
        state =
          put_in(state.snapshot.frontier_size, state.queued_count + state.next_count + busy)

        Progress.put(state.snapshot)
        state
    end
  end

  defp dequeue(state) do
    case :queue.out(state.queue) do
      {{:value, job}, queue} ->
        {{:value, job}, %{state | queue: queue}}

      {:empty, _} ->
        if :gb_sets.is_empty(state.priority) do
          {:empty, state}
        else
          {{_, _, url, attempt}, priority} = :gb_sets.take_smallest(state.priority)
          {{:value, {url, attempt}}, %{state | priority: priority}}
        end
    end
  end

  # Prune pending work when a shorter complete path establishes a new bound.
  # In-flight fetches may finish; accept/3 checks their current depth again.
  defp tighten(state, hops) do
    state = %{state | bound: hops}

    queue =
      state.queue |> :queue.to_list() |> Enum.filter(fn {url, _} -> expandable?(state, url) end)

    priority =
      state.priority
      |> :gb_sets.to_list()
      |> Enum.filter(fn {_, _, url, _} -> expandable?(state, url) end)

    next = Enum.filter(state.next, &expandable?(state, &1))

    %{
      state
      | queue: :queue.from_list(queue),
        priority: :gb_sets.from_list(priority),
        next: next,
        next_count: length(next),
        queued_count: length(queue) + length(priority)
    }
  end

  defp expandable?(state, url) do
    is_nil(state.bound) or state.depths[Page.key(url)] + 1 < state.bound
  end

  defp path(nil, _state, acc), do: acc
  defp path(key, state, acc), do: path(state.parents[key], state, [state.urls[key] | acc])

  # Called only at a depth barrier, when every existing worker is idle.
  defp resize_workers(state, count) do
    {keep, remove} = state.workers |> Enum.to_list() |> Enum.split(count)
    stop_workers(%{state | workers: Map.new(remove)})
    state = %{state | workers: Map.new(keep)}

    Enum.reduce(List.duplicate(nil, max(count - map_size(state.workers), 0)), state, fn _, acc ->
      add_worker(acc)
    end)
  end

  defp finish(state, status) do
    stop_workers(state)

    if status == :exhausted do
      if state.report_to,
        do: send(state.report_to, {:lane_exhausted, self()}),
        else: WikiRace.Harness.report_exhausted()
    end

    state = %{
      state
      | workers: %{},
        priority: :gb_sets.empty(),
        active: 0,
        queue: :queue.new(),
        queued_count: 0,
        next: [],
        next_count: 0,
        snapshot: %{
          state.snapshot
          | state: if(state.snapshot.path == [], do: status, else: :found),
            frontier_size: 0
        }
    }

    Progress.put(state.snapshot)
    state
  end

  defp stop_workers(state) do
    Enum.each(state.workers, fn {pid, worker} ->
      if worker.job != nil, do: Process.cancel_timer(elem(worker.job, 3))
      Process.demonitor(worker.ref, [:flush])
      Process.exit(pid, :kill)
    end)
  end
end
