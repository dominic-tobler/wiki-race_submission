defmodule Player.BFSHTTPTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()
    server = spawn(fn -> serve(listener, owner) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)

    {:ok, base: "http://127.0.0.1:#{port}/content/test/"}
  end

  test "real HTTP and HTML produce a directed path reported by the coordinator", %{base: base} do
    assert :yes == :global.register_name(WikiRace.Harness.registered_name(), self())
    on_exit(fn -> :global.unregister_name(WikiRace.Harness.registered_name()) end)
    {:ok, pid} = Player.Crawler.start(base <> "Start", base <> "Target")
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    expected = Enum.map(["Start", "Middle", "Target"], &(base <> &1))
    assert_receive {:path_found, ^pid, ^expected}, 2_000
    assert_receive {:request, "/content/test/Start"}
    assert_receive {:request, "/content/test/Middle"}
    refute_receive {:request, "/content/test/Target"}
    assert %WikiRace.Status{state: :found, path: ^expected} = Player.Crawler.status(pid)
  end

  test "redirects are not followed and HTTP failures are explicit", %{base: base} do
    assert {:error, {:http_status, 302}} = Player.BFS.Page.fetch(base <> "Redirect")
    assert_receive {:request, "/content/test/Redirect"}
    refute_receive {:request, "/content/test/Target"}
    assert {:error, {:http_status, 404}} = Player.BFS.Page.fetch(base <> "Missing")
  end

  defp serve(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, request} = read_headers(socket, "")
        [_, path | _] = String.split(request, " ", parts: 3)
        send(owner, {:request, path})
        {status, headers, body} = response(path)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status}\r\nContent-Type: text/html\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n#{headers}\r\n#{body}"
        )

        :gen_tcp.close(socket)
        serve(listener, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_headers(socket, data) do
    if String.contains?(data, "\r\n\r\n") do
      {:ok, data}
    else
      {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
      read_headers(socket, data <> chunk)
    end
  end

  defp response("/content/test/Start"), do: {"200 OK", "", ~s(<a href="Middle">middle</a>)}

  defp response("/content/test/Middle"),
    do: {"200 OK", "", ~s(<a href="Target#section">target</a>)}

  defp response("/content/test/Redirect"),
    do: {"302 Found", "Location: /content/test/Target\r\n", ""}

  defp response(_), do: {"404 Not Found", "", ""}
end
