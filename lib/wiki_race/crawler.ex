defmodule WikiRace.Crawler do
  @moduledoc """
  The contract every crawler implements.

  The harness only uses the two callbacks below. It starts your crawler with
  `c:start/2` and reads its progress with `c:status/1`.

      defmodule MyGroup.Crawler do
        @behaviour WikiRace.Crawler

        @impl true
        def start(start_url, target_url) do
          DynamicSupervisor.start_child(
            MyGroup.CrawlerSupervisor,
            {MyGroup.Search, {start_url, target_url}}
          )
        end

        @impl true
        def status(pid), do: GenServer.call(pid, :status)
      end

  ## Lifecycle

  The pid returned by `c:start/2` must be supervised by **your** application. The
  harness does not supervise it. It only monitors it with `Process.monitor/1`. If
  your crawler crashes, the race goes on without you.

  When the time limit ends, the harness calls `c:status/1` one last time and then
  kills the pid. There is no shutdown callback, so do not rely on any cleanup code.

  ## Reporting a path

  When you find a path, call `WikiRace.Harness.report/1`:

      WikiRace.Harness.report([start_url, ..., target_url])

  The harness records the time each report arrives. The crawler whose first valid
  path arrives first gets a bonus in the score. The arrival time of your shortest
  path is your time. Report a path as soon as you have one. If you find a shorter
  path later, report it too.

  Also set `path` and `state: :found` in your `c:status/1` result. The harness
  treats that status as a report too, so it must hold the same path.

  ## URLs

  Both arguments to `c:start/2` are full Kiwix article URLs. Pass them to
  `Req.get/1` as they are. Never request `wikipedia.org`.

  Links in a page are relative. Resolve them against the URL of that page. Follow
  only article links. Kiwix also serves search pages and static files from the same
  host, and fetching them wastes time.
  """

  @doc """
  Starts a crawl from `start_url` toward `target_url`.

  Returns `{:ok, pid}`. The harness monitors that pid and passes it to
  `c:status/1`. The process must be supervised by your application. Return
  `{:error, reason}` if the crawler cannot start. The dashboard shows `reason`.

  The harness calls this once per race and waits at most 15 seconds. Start your
  processes and return. Do not crawl inside this function.
  """
  @callback start(start_url :: String.t(), target_url :: String.t()) ::
              {:ok, pid()} | {:error, term()}

  @doc """
  Returns the current progress of the crawl.

  The harness calls this every 250 ms during the race and waits at most 250 ms for
  the answer. It must not block. Read the data from ETS, or from a process that is
  not doing the crawling. If the call does not answer in time, the dashboard shows
  nothing for that poll.
  """
  @callback status(pid :: pid()) :: WikiRace.Status.t()
end
