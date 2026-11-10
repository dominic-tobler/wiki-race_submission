defmodule Player.Engine.Progress do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def register(pid, snapshot), do: GenServer.call(__MODULE__, {:register, pid, snapshot})
  def put(snapshot), do: :ets.insert(__MODULE__, {self(), snapshot})

  def get(pid) do
    case :ets.lookup(__MODULE__, pid) do
      [{^pid, snapshot}] -> snapshot
      [] -> WikiRace.Status.new(state: :exhausted)
    end
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, pid, snapshot}, _from, monitors) do
    ref = Process.monitor(pid)
    :ets.insert(__MODULE__, {pid, snapshot})
    {:reply, :ok, Map.put(monitors, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, monitors) do
    :ets.delete(__MODULE__, pid)
    {:noreply, Map.delete(monitors, ref)}
  end
end
