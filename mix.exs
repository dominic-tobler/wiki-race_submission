defmodule Player.MixProject do
  use Mix.Project

  def project do
    [
      app: :player,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Player.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Req and Floki are the only dependencies allowed. Do not add others.
  # Everything else must use OTP: GenServer, DynamicSupervisor, ETS and
  # Erlang distribution.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:floki, "~> 0.38"}
    ]
  end
end
