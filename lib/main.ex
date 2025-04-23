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

    {:ok, http_request} = :gen_tcp.recv(client, 0)

    [request_line, headers, _request_body] = parse_request(http_request)
    [_http_method, url, _http_version] = parse_request_line(request_line)

    response =
      case url do
        "/" ->
          "HTTP/1.1 200 OK\r\n\r\n"

        "/user-agent" ->
          user_agent = parse_user_agent(headers)

          """
          HTTP/1.1 200 OK\r
          Content-Type: text/plain\r
          Content-Length: #{byte_size(user_agent)}\r
          \r
          #{user_agent}\r\n
          """

        "/echo/" <> str ->
          """
          HTTP/1.1 200 OK\r
          Content-Type: text/plain\r
          Content-Length: #{byte_size(str)}\r
          \r
          #{str}\r\n
          """

        _ ->
          "HTTP/1.1 404 Not Found\r\n\r\n"
      end

    :gen_tcp.send(client, response)
  end

  defp parse_request(http_request) do
    [request_line_and_headers, body] =
      http_request
      |> String.split("\r\n\r\n")

    [request_line | headers] =
      request_line_and_headers
      |> String.split("\r\n")

    [request_line, headers, body]
  end

  defp parse_user_agent(headers) do
    user_agent_line =
      headers
      |> Enum.find("", fn header ->
        String.starts_with?(header, "User-Agent:")
      end)

    user_agent_line
    |> String.replace_prefix("User-Agent: ", "")
    |> String.trim()
  end

  defp parse_request_line(request_line) do
    request_line
    |> String.split(" ")
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
