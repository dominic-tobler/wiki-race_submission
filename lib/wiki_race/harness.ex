defmodule WikiRace.Harness do
  @moduledoc """
  Sends results to the harness.

  Always use this module to talk to the harness. Do not send messages to the
  harness yourself. Its address may change, and this module hides it.

  You can call `report/1` from any process, on any of your nodes.
  """

  @registered_name :wiki_race_harness

  @doc """
  Reports a path to the harness.

  `path` is the list of article URLs from the start article to the target, both
  included.

  Returns `:ok` at once and never blocks, even if the harness is down. The harness
  records the arrival time with its own clock. The clock of your node is not used.

  You can report more than once. Report a path as soon as you have one, and report
  again if you find a shorter one. The harness keeps your shortest path, with the
  arrival time of the report that sent it. If a reported path is wrong, your score
  for the race is -1.0, even if another report is correct.
  """
  @spec report(WikiRace.Status.path()) :: :ok
  def report(path) when is_list(path) do
    send_to_harness({:path_found, self(), path})
  end

  @doc """
  Tells the harness that your crawler searched everything and found no path.

  Optional. Your race ends at the time limit anyway. With this call the dashboard
  shows you as finished, and the race can end early once both crawlers are done.
  """
  @spec report_exhausted() :: :ok
  def report_exhausted do
    send_to_harness({:exhausted, self()})
  end

  @doc """
  The name the harness is registered under.

  Use `report/1` instead. This is only for checking the connection from IEx:

      iex> :global.whereis_name(WikiRace.Harness.registered_name())
      #PID<12345.678.0>
  """
  @spec registered_name() :: atom()
  def registered_name, do: @registered_name

  defp send_to_harness(message) do
    case :global.whereis_name(@registered_name) do
      :undefined -> :ok
      pid -> send(pid, message) && :ok
    end
  end
end
