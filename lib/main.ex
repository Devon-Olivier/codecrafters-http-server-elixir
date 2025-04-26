defmodule Server do
  use Application

  @port 4221

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: Server.RequestHandlerSupervisor, strategy: :one_for_one},
      {Server.HTTPListener, @port}
    ]

    Supervisor.start_link(
      children,
      strategy: :one_for_one
    )
  end
end

defmodule Server.HTTPListener do
  use Task

  def start_link(port) when is_integer(port) do
    Task.start_link(__MODULE__, :listen, [port])
  end

  def listen(port \\ 4221) do
    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])
    IO.puts("Server listening on port #{port}")
    accept_loop(socket)
  end

  defp accept_loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    handle(client)
    accept_loop(socket)
  end

  defp handle(socket) do
    # TODO: handle errors
    DynamicSupervisor.start_child(
      Server.RequestHandlerSupervisor,
      {Server.RequestHandler, socket}
    )
  end
end

defmodule Server.RequestHandler do
  use Task

  def start_link(socket) do
    Task.start_link(__MODULE__, :handle, [socket])
  end

  def handle(socket) do
    directory = Application.get_env(:codecrafters_http_server, :directory)

    {:ok, raw_request} = :gen_tcp.recv(socket, 0)

    [request_line, headers, _request_body] = parse_request(raw_request)
    [_http_method, url, _http_version] = parse_request_line(request_line)

    response =
      case url do
        "/" ->
          """
          HTTP/1.1 200 OK\r
          Content-Length: 0\r
          \r
          """

        "/user-agent" ->
          user_agent = parse_user_agent(headers)

          """
          HTTP/1.1 200 OK\r
          Content-Type: text/plain\r
          Content-Length: #{byte_size(user_agent)}\r
          \r
          #{user_agent}\
          """

        "/echo/" <> str ->
          """
          HTTP/1.1 200 OK\r
          Content-Type: text/plain\r
          Content-Length: #{byte_size(str)}\r
          \r
          #{str}\
          """

        "/files/" <> filename ->
          file_path = Path.join(directory, filename)

          case File.read(file_path) do
            {:ok, body} ->
              """
              HTTP/1.1 200 OK\r
              Content-Type: application/octet-stream\r
              Content-Length: #{byte_size(body)}\r
              \r
              #{body}\
              """

            {:error, :enoent} ->
              """
              HTTP/1.1 404 Not Found\r
              Content-Length: 0\r
              \r
              """
          end

        _ ->
          """
          HTTP/1.1 404 Not Found\r
          Content-Length: 0\r
          \r
          """
      end

    :gen_tcp.send(socket, response)
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
  def main(args) do
    {parsed, _remaining, _invalid} = OptionParser.parse(args, strict: [directory: :string])

    Application.put_env(
      :codecrafters_http_server,
      :directory,
      parsed[:directory]
    )

    # Start the Server application
    {:ok, _pid} = Application.ensure_all_started(:codecrafters_http_server)

    # Run forever
    Process.sleep(:infinity)
  end
end
