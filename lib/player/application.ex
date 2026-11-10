defmodule Player.Application do
  @moduledoc """
  Supervises independent race coordinators.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Player.Engine.Progress,

      {DynamicSupervisor, name: WikiRace.CrawlerSupervisor, strategy: :one_for_one},
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Player.Supervisor)
  end
end
