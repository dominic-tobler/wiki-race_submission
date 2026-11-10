defmodule Player.ContractTest do
  @moduledoc """
  Checks that `Player.Crawler` follows the `WikiRace.Crawler` contract.

  `start/2` must return a live pid, and `status/1` must return a
  `WikiRace.Status`. They are not graded.
  """
  use ExUnit.Case, async: true

  alias WikiRace.Status

  # URLs in the same form the harness passes to `start/2`.
  @start_url "http://localhost:8080/content/wikipedia_en_all_nopic/Chess"
  @target_url "http://localhost:8080/content/wikipedia_en_all_nopic/Bee"

  test "start/2 returns a live pid" do
    assert {:ok, pid} = Player.Crawler.start(@start_url, @target_url)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "status/1 returns a WikiRace.Status" do
    {:ok, pid} = Player.Crawler.start(@start_url, @target_url)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert %Status{} = Player.Crawler.status(pid)
  end
end
