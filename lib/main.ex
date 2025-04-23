defmodule Server do
  use Application

  def start(_type, _args) do
    Supervisor.start_link([{Task, fn -> Server.listen() end}], strategy: :one_for_one)
  end

  def listen() do
    # You can use print statements as follows for debugging, they'll be visible when running tests.
    IO.puts("Logs from your program will appear here!")

    # Uncomment this block to pass the first stage
    #
    # Since the tester restarts your program quite often, setting SO_REUSEADDR
    # ensures that we don't run into 'Address already in use' errors
    {:ok, socket} = :gen_tcp.listen(4221, [:binary, active: false, reuseaddr: true])
    {:ok, client} = :gen_tcp.accept(socket)

    {:ok, line} = :gen_tcp.recv(client, 0)

    [_http_method, url, _http_version] =
      line
      |> String.split("\r\n")
      |> List.first()
      |> String.split(" ")

    response =
      case url do
        "/" ->
          "HTTP/1.1 200 OK\r\n\r\n"

        _ ->
          "HTTP/1.1 404 Not Found\r\n\r\n"
      end

    :gen_tcp.send(client, response)
  end
end

defmodule CLI do
  def main(_args) do
    # Start the Server application
    {:ok, _pid} = Application.ensure_all_started(:codecrafters_http_server)

    # Run forever
    Process.sleep(:infinity)
  end
end
