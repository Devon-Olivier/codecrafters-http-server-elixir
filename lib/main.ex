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
    DynamicSupervisor.start_child(
      Server.RequestHandlerSupervisor,
      {Server.RequestHandler, socket}
    )
  end
end

defmodule Server.HTTPRequest do
  @enforce_keys ~w[raw_request]a
  defstruct ~w[
    accept
    body
    content_length
    content_type
    host
    http_version
    method
    raw_headers
    raw_request
    raw_request_line
    url
    user_agent
  ]a

  def parse_headers(%__MODULE__{raw_headers: raw_headers} = req) do
    raw_headers
    |> Enum.reduce(req, fn header, acc_req ->
      parse_header(acc_req, header)
    end)
  end

  defp parse_header(
         %__MODULE__{raw_headers: _raw_headers} = req,
         "Content-Length: " <> content_length
       ) do
    %__MODULE__{req | content_length: content_length}
  end

  defp parse_header(
         %__MODULE__{raw_headers: _raw_headers} = req,
         "Content-Type: " <> content_type
       ) do
    %__MODULE__{req | content_type: content_type}
  end

  defp parse_header(%__MODULE__{raw_headers: _raw_headers} = req, "Host: " <> host) do
    %__MODULE__{req | host: host}
  end

  defp parse_header(%__MODULE__{raw_headers: _raw_headers} = req, "User-Agent: " <> user_agent) do
    %__MODULE__{req | user_agent: user_agent}
  end

  defp parse_header(%__MODULE__{raw_headers: _raw_headers} = req, "Accept: " <> accept) do
    %__MODULE__{req | accept: accept}
  end

  def parse_request_line(%__MODULE__{raw_request: raw_request} = req) do
    [request_line_and_headers, body] =
      raw_request
      |> String.split("\r\n\r\n")

    [raw_request_line | raw_headers] =
      request_line_and_headers
      |> String.split("\r\n", trim: true)

    [method, url, raw_http_version] =
      raw_request_line
      |> String.split(" ", trim: true)

    [_http, http_version] =
      raw_http_version
      |> String.split("/", trim: true)

    req
    |> then(&%__MODULE__{&1 | raw_request_line: raw_request_line})
    |> then(&%__MODULE__{&1 | raw_headers: raw_headers})
    |> then(&%__MODULE__{&1 | body: body})
    |> then(&%__MODULE__{&1 | method: method})
    |> then(&%__MODULE__{&1 | url: url})
    |> then(&%__MODULE__{&1 | http_version: http_version})
  end
end

defmodule Server.RequestHandler do
  use Task

  alias Server.HTTPRequest

  def start_link(socket) do
    Task.start_link(__MODULE__, :handle, [socket])
  end

  def handle(socket) do
    # TODO: handle errors
    {:ok, raw_request} = :gen_tcp.recv(socket, 0)

    req =
      %HTTPRequest{raw_request: raw_request}
      |> HTTPRequest.parse_request_line()
      |> HTTPRequest.parse_headers()

    :gen_tcp.send(socket, response(req))
  end

  defp response(%HTTPRequest{body: _body, method: "GET", url: "/"}) do
    """
    HTTP/1.1 200 OK\r
    Content-Length: 0\r
    \r
    """
  end

  defp response(%HTTPRequest{
         method: "GET",
         url: "/user-agent",
         user_agent: user_agent
       }) do
    """
    HTTP/1.1 200 OK\r
    Content-Type: text/plain\r
    Content-Length: #{byte_size(user_agent)}\r
    \r
    #{user_agent}\
    """
  end

  defp response(%HTTPRequest{
         method: "GET",
         url: "/echo/" <> str
       }) do
    """
    HTTP/1.1 200 OK\r
    Content-Type: text/plain\r
    Content-Length: #{byte_size(str)}\r
    \r
    #{str}\
    """
  end

  defp response(%HTTPRequest{
         method: "GET",
         url: "/files/" <> filename
       }) do
    directory = Application.get_env(:codecrafters_http_server, :directory)
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
  end

  defp response(%HTTPRequest{
         body: body,
         method: "POST",
         url: "/files/" <> filename
       }) do
    directory = Application.get_env(:codecrafters_http_server, :directory)
    file_path = Path.join(directory, filename)

    # TODO: handle errors
    File.write(file_path, body)

    """
    HTTP/1.1 201 Created\r
    Content-Length: 0\r
    \r
    """
  end

  defp response(%HTTPRequest{}) do
    """
    HTTP/1.1 404 Not Found\r
    Content-Length: 0\r
    \r
    """
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
