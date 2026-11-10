defmodule Player.BFSTest do
  use ExUnit.Case, async: true
  alias Player.BFS.{Page, Search}

  @base "http://localhost:8080/content/test/"
  defp url(title), do: @base <> title

  defp search(options \\ []) do
    owner = self()

    fetch = fn url ->
      send(owner, {:fetch, self(), url})

      receive do
        :crash -> exit(:simulated_crash)
        result -> result
      end
    end

    pid =
      start_supervised!(
        {Search, {url("Start"), url("Target"), Keyword.put(options, :fetch, fetch)}}
      )

    pid
  end

  defp fetches(count) do
    Map.new(
      for _ <- 1..count do
        assert_receive {:fetch, worker, url}, 1_000
        {url, worker}
      end
    )
  end

  defp await_state(pid, expected, attempts \\ 100)
  defp await_state(_pid, expected, 0), do: flunk("never reached #{expected}")

  defp await_state(pid, expected, attempts) do
    status = Player.Crawler.status(pid)

    if status.state == expected do
      status
    else
      Process.sleep(10)
      await_state(pid, expected, attempts - 1)
    end
  end

  test "depth barriers, per-level concurrency, deduplication, cycles and shortest path" do
    pid = search()
    [seed] = fetches(1) |> Map.values()
    send(seed, {:ok, [url("A"), url("B"), url("A"), url("Start")]})
    level = fetches(2)
    assert map_size(:sys.get_state(pid).workers) == 2

    send(level[url("A")], {:ok, [url("C"), url("D"), url("Start")]})
    refute_receive {:fetch, _, _}, 30
    assert Player.Crawler.status(pid).state == :running
    send(level[url("B")], {:ok, [url("C"), url("E")]})
    level = fetches(3)
    assert Map.keys(level) |> Enum.sort() == Enum.map(["C", "D", "E"], &url/1)
    assert map_size(:sys.get_state(pid).workers) == 3

    # A deeper path cannot win just because its requests would finish first.
    send(level[url("C")], {:ok, [url("Longer")]})
    refute_receive {:fetch, _, _}, 30
    send(level[url("E")], {:ok, [url("Target")]})
    status = await_state(pid, :found)
    assert status.path == Enum.map(["Start", "B", "E", "Target"], &url/1)
    assert status.frontier_size == 0
    assert status.visited_count == 5
    assert Enum.all?(Map.values(level), &(not Process.alive?(&1)))
  end

  test "pool shrinks with the next level" do
    pid = search()
    [seed] = fetches(1) |> Map.values()
    send(seed, {:ok, [url("A"), url("B")]})
    level = fetches(2)
    Enum.each(Map.values(level), &send(&1, {:ok, [url("C")]}))
    [worker] = fetches(1) |> Map.values()
    assert map_size(:sys.get_state(pid).workers) == 1
    send(worker, {:ok, []})
    assert await_state(pid, :exhausted).visited_count == 4
  end

  test "a wide frontier queues URLs instead of creating unbounded workers" do
    pid = search()
    [seed] = fetches(1) |> Map.values()
    send(seed, {:ok, Enum.map(1..1_000, &url("Article_#{&1}"))})
    active = fetches(64)
    refute_receive {:fetch, _, _}, 30
    assert map_size(:sys.get_state(pid).workers) == 64
    assert Player.Crawler.status(pid).frontier_size == 1_000

    [worker | _] = Map.values(active)
    send(worker, {:ok, [url("Target")]})
    assert await_state(pid, :found).state == :found
  end

  test "queued URLs finish their level before deeper links, including after a worker crash" do
    pid = search(max_concurrency: 2)
    [seed] = fetches(1) |> Map.values()
    send(seed, {:ok, Enum.map(["A", "B", "C"], &url/1)})
    active = fetches(2)
    refute_receive {:fetch, _, _}, 30

    send(active[url("A")], {:ok, [url("Deep")]})
    assert_receive {:fetch, c_worker, c_url}
    assert c_url == url("C")
    send(active[url("B")], :crash)
    assert_receive {:fetch, replacement, b_url}
    assert b_url == url("B")
    assert map_size(:sys.get_state(pid).workers) == 2
    send(c_worker, {:ok, []})
    refute_receive {:fetch, _, _}, 30
    send(replacement, {:ok, []})

    assert_receive {:fetch, deep_worker, deep_url}
    assert deep_url == url("Deep")
    assert map_size(:sys.get_state(pid).workers) == 1
    send(deep_worker, {:ok, [url("Target")]})
    assert await_state(pid, :found).path == Enum.map(["Start", "A", "Deep", "Target"], &url/1)
  end

  test "worker crashes are monitored and the same page is retried" do
    pid = search()
    [worker] = fetches(1) |> Map.values()
    send(worker, :crash)
    assert_receive {:fetch, replacement, start}, 1_000
    assert start == url("Start")
    assert replacement != worker
    send(replacement, {:ok, [url("Target")]})
    assert await_state(pid, :found).path == [url("Start"), url("Target")]
  end

  test "hung requests time out and retries are bounded" do
    pid = search(worker_timeout: 30, retries: 1)
    [first] = fetches(1) |> Map.values()
    [second] = fetches(1) |> Map.values()
    assert first != second
    assert await_state(pid, :exhausted).visited_count == 0
    refute Process.alive?(first)
    refute Process.alive?(second)
    refute_receive {:fetch, _, _}, 50
  end

  test "HTTP errors retry and eventually exhaust without a false path" do
    pid = search(retries: 1)
    [worker] = fetches(1) |> Map.values()
    send(worker, {:error, :unavailable})
    [worker] = fetches(1) |> Map.values()
    send(worker, {:error, :unavailable})
    assert await_state(pid, :exhausted).path == []
  end

  test "killing the coordinator kills blocked workers and does not restart the race" do
    owner = self()

    fetch = fn _ ->
      send(owner, {:worker, self()})

      receive do
        :never -> {:ok, []}
      end
    end

    {:ok, pid} =
      DynamicSupervisor.start_child(
        WikiRace.CrawlerSupervisor,
        {Search, {url("Start"), url("Target"), [fetch: fetch]}}
      )

    assert_receive {:worker, worker}
    ref = Process.monitor(worker)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    refute_receive {:worker, _}, 50
  end

  test "status responds while a fetch is blocked" do
    pid = search()
    fetches(1)
    assert %WikiRace.Status{state: :running, frontier_size: 1} = Player.Crawler.status(pid)
  end

  test "status is independent of the coordinator mailbox" do
    pid = search()
    fetches(1)
    :sys.suspend(pid)

    try do
      assert %WikiRace.Status{state: :running} = Player.Crawler.status(pid)
    after
      :sys.resume(pid)
    end
  end

  test "equal endpoints do not report a one-article path rejected by the referee" do
    {:ok, pid} = Player.Crawler.start(url("Start"), url("Start"))
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    assert await_state(pid, :exhausted).path == []
  end

  test "outgoing links of the target are never treated as incoming edges" do
    pid = search()
    [worker] = fetches(1) |> Map.values()
    send(worker, {:ok, [url("Common")]})
    assert_receive {:fetch, worker, common}
    assert common == url("Common")
    send(worker, {:ok, []})
    assert await_state(pid, :exhausted).path == []
    refute_receive {:fetch, _, _}
  end

  test "HTML links stay in the same Kiwix origin and book and canonical duplicates collapse" do
    html = """
    <a href="A">a</a><a href="%41#section">same</a>
    <a href="B#part">b</a><a href="#part">self fragment</a>
    <a href="https://en.wikipedia.org/wiki/C">external</a>
    <a href="//evil.test/content/test/C">external</a>
    <a href="/content/other/C">other book</a><a href="/search?pattern=C">search</a>
    <a href="File:Photo.jpg">file</a><a href="Special:Search">special</a>
    <a href="x.css">asset</a><a href="C?query=yes">query</a>
    <a href="http://[bad">malformed</a><a href="D&amp;E">entity</a>
    """

    assert Page.links(html, url("Start")) == {:ok, Enum.map(["A", "B", "D&E"], &url/1)}
    refute Page.valid_pair?(url("Start"), "https://en.wikipedia.org/wiki/Target")
    assert {:error, :invalid_kiwix_urls} = Player.Crawler.start(url("Start"), "bad")
  end
end
