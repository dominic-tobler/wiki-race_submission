defmodule Player.Crawler do
  @moduledoc """
  The supervised hybrid crawler combining breadth-first and guided search.
  """

  @behaviour WikiRace.Crawler

  @impl WikiRace.Crawler
  def start(start_url, target_url) do
    if Player.Engine.Page.valid_pair?(start_url, target_url) do
      DynamicSupervisor.start_child(
        WikiRace.CrawlerSupervisor,
        {Player.Hybrid.Search, {start_url, target_url, []}}
      )
    else
      {:error, :invalid_kiwix_urls}
    end
  end

  @impl WikiRace.Crawler
  def status(pid), do: Player.Engine.Progress.get(pid)

end
