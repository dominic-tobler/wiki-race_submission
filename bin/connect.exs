# Used only by the local docker-compose setup. It is not part of the assignment.
# It connects this node to the platform node with Node.connect/1. It retries for
# 30 seconds, because the platform may still be starting.
#
# Invoked as: elixir --sname ... --cookie ... -S mix run --no-halt bin/connect.exs

platform_node = System.fetch_env!("PLATFORM_NODE") |> String.to_atom()

connected? =
  Enum.reduce_while(1..30, false, fn attempt, _acc ->
    case Node.connect(platform_node) do
      true ->
        {:halt, true}

      _ ->
        IO.puts("waiting for #{platform_node} (attempt #{attempt}/30)")
        Process.sleep(1_000)
        {:cont, false}
    end
  end)

if connected? do
  IO.puts("connected to #{platform_node}")
else
  IO.puts("could not connect to #{platform_node} after 30s, staying up anyway")
end
