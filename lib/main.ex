defmodule Server do
  use Application

  @port 4221

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: Server.ConnectionHandlerSupervisor, strategy: :one_for_one},
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
    require Logger

    {:ok, socket} = :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true])

    Logger.info("Server listening on port #{port}")

    accept_loop(socket)
  end

  defp accept_loop(socket) do
    {:ok, client} = :gen_tcp.accept(socket)
    handle(client)
    accept_loop(socket)
  end

  defp handle(socket) do
    DynamicSupervisor.start_child(
      Server.ConnectionHandlerSupervisor,
      {Server.ConnectionHandler, socket}
    )
  end
end

defmodule Server.HTTPRequest do
  # TODO: combine all headers into one `headers` keyword list
  @enforce_keys ~w[raw_request]a
  defstruct [
    :accept,
    :content_type,
    :host,
    :http_version,
    :method,
    :raw_headers,
    :raw_request,
    :raw_request_line,
    :url,
    :user_agent,
    accept_encoding: "",
    body: "",
    content_length: 0,
    connection: "Keep-Alive"
  ]

  def parse_headers(%__MODULE__{raw_headers: raw_headers} = req) do
    raw_headers
    |> Enum.reduce(req, fn header, acc_req ->
      parse_header(acc_req, header)
    end)
  end

  # TODO: Fix - this is brittle. Header keys are case-insensitive. A possible fix is to downcase before calling and have parse_header/2 accept only lowercase strings
  defp parse_header(%__MODULE__{raw_headers: _raw_headers} = req, "Accept: " <> accept) do
    %__MODULE__{req | accept: accept}
  end

  defp parse_header(
         %__MODULE__{raw_headers: _raw_headers} = req,
         "Accept-Encoding: " <> accept_encoding
       ) do
    %__MODULE__{req | accept_encoding: accept_encoding}
  end

  defp parse_header(
         %__MODULE__{raw_headers: _raw_headers} = req,
         "Connection: " <> connection
       ) do
    %__MODULE__{req | connection: connection}
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

  def parse_request_line(%__MODULE__{raw_request: raw_request} = req) do
    [head, body] = String.split(raw_request, "\r\n\r\n")

    [raw_request_line | raw_headers] = String.split(head, "\r\n", trim: true)

    [method, url, http_version] = String.split(raw_request_line, " ", trim: true)

    method = String.upcase(method)
    http_version = String.upcase(http_version)

    req
    |> then(&%__MODULE__{&1 | raw_request_line: raw_request_line})
    |> then(&%__MODULE__{&1 | raw_headers: raw_headers})
    |> then(&%__MODULE__{&1 | body: body})
    |> then(&%__MODULE__{&1 | method: method})
    |> then(&%__MODULE__{&1 | url: url})
    |> then(&%__MODULE__{&1 | http_version: http_version})
  end
end

defmodule Server.HTTPResponse do
  @enforce_keys ~w[status_code status_text]a
  defstruct [
    :status_code,
    :status_text,
    body: "",
    headers: [content_length: 0, connection: "Keep-Alive"],
    protocol: "HTTP/1.1"
  ]

  def put_header(%__MODULE__{} = res, :connection, value) do
    do_put_header(res, :connection, value)
  end

  def put_header(%__MODULE__{} = res, :content_encoding, value) do
    do_put_header(res, :content_encoding, value)
  end

  def put_header(%__MODULE__{} = res, :content_length, value) do
    do_put_header(res, :content_length, value)
  end

  def put_header(%__MODULE__{} = res, :content_type, value) do
    do_put_header(res, :content_type, value)
  end

  def put_header(%__MODULE__{} = res, :date, value) do
    do_put_header(res, :date, value)
  end

  defp do_put_header(%__MODULE__{headers: headers} = res, key, value) do
    new_headers = Keyword.put(headers, key, value)
    %__MODULE__{res | headers: new_headers}
  end

  def to_string(%__MODULE__{
        body: body,
        headers: headers,
        protocol: protocol,
        status_code: status_code,
        status_text: status_text
      }) do
    status_line = "#{protocol} #{status_code} #{status_text}"

    head =
      if headers == [] do
        status_line
      else
        headers_string = Enum.map_join(headers, "\r\n", &header_to_string/1)

        """
        #{status_line}\r
        #{headers_string}\
        """
      end

    """
    #{head}\r
    \r
    #{body}\
    """
  end

  defp header_to_string({:connection, value}) do
    "Connection: #{value}"
  end

  defp header_to_string({:content_encoding, value}) do
    "Content-Encoding: #{value}"
  end

  defp header_to_string({:content_length, value}) do
    "Content-Length: #{value}"
  end

  defp header_to_string({:content_type, value}) do
    "Content-Type: #{value}"
  end

  defp header_to_string({:date, value}) do
    "Date: #{value}"
  end
end

defmodule Server.ConnectionHandler do
  use Task

  def start_link(socket) do
    Task.start_link(__MODULE__, :handle, [socket])
  end

  def handle(socket) do
    # TODO: handle errors and crashes
    case :gen_tcp.recv(socket, 0) do
      {:ok, raw_request} ->
        DynamicSupervisor.start_child(
          Server.RequestHandlerSupervisor,
          {Server.RequestHandler, %{raw_request: raw_request, socket: socket}}
        )

        handle(socket)

      {:error, :closed} ->
        :ok
    end
  end
end

defmodule Server.RequestHandler do
  use Task

  alias Server.{HTTPResponse, HTTPRequest}

  def start_link(%{raw_request: _raw_request, socket: _socket} = request) do
    Task.start_link(__MODULE__, :handle, [request])
  end

  def handle(%{raw_request: raw_request, socket: socket}) do
    # TODO: handle errors

    req =
      %HTTPRequest{raw_request: raw_request}
      |> HTTPRequest.parse_request_line()
      |> HTTPRequest.parse_headers()

    res = response(req)
    :gen_tcp.send(socket, HTTPResponse.to_string(res))

    if res.headers[:connection] == "close" do
      :gen_tcp.close(socket)
    end
  end

  defp response(%HTTPRequest{body: _body, connection: connection, method: "GET", url: "/"}) do
    %HTTPResponse{
      status_code: 200,
      status_text: "OK"
    }
    |> HTTPResponse.put_header(:connection, connection)
  end

  defp response(%HTTPRequest{
         connection: connection,
         method: "GET",
         url: "/user-agent",
         user_agent: user_agent
       }) do
    %HTTPResponse{
      body: user_agent,
      status_code: 200,
      status_text: "OK"
    }
    |> HTTPResponse.put_header(:connection, connection)
    |> HTTPResponse.put_header(:content_type, "text/plain")
    |> HTTPResponse.put_header(:content_length, byte_size(user_agent))
  end

  defp response(%HTTPRequest{
         accept_encoding: accept_encoding,
         connection: connection,
         method: "GET",
         url: "/echo/" <> str
       }) do
    encodings =
      accept_encoding
      |> String.split(",", trim: true)
      |> MapSet.new(&String.trim/1)

    res =
      if MapSet.member?(encodings, "gzip") do
        str_gz = :zlib.gzip(str)

        %HTTPResponse{
          body: str_gz,
          status_code: 200,
          status_text: "OK"
        }
        |> HTTPResponse.put_header(:content_length, byte_size(str_gz))
        |> HTTPResponse.put_header(:content_encoding, "gzip")
      else
        %HTTPResponse{
          body: str,
          status_code: 200,
          status_text: "OK"
        }
        |> HTTPResponse.put_header(:content_length, byte_size(str))
      end

    res
    |> HTTPResponse.put_header(:connection, connection)
    |> HTTPResponse.put_header(:content_type, "text/plain")
  end

  defp response(%HTTPRequest{
         connection: connection,
         method: "GET",
         url: "/files/" <> filename
       }) do
    directory = Application.get_env(:codecrafters_http_server, :directory)
    file_path = Path.join(directory, filename)

    res =
      case File.read(file_path) do
        {:ok, body} ->
          %HTTPResponse{
            body: body,
            status_code: 200,
            status_text: "OK"
          }
          |> HTTPResponse.put_header(:content_type, "application/octet-stream")
          |> HTTPResponse.put_header(:content_length, byte_size(body))

        {:error, :enoent} ->
          %HTTPResponse{
            status_code: 404,
            status_text: "Not Found"
          }
      end

    res
    |> HTTPResponse.put_header(:connection, connection)
  end

  defp response(%HTTPRequest{
         body: body,
         connection: connection,
         method: "POST",
         url: "/files/" <> filename
       }) do
    directory = Application.get_env(:codecrafters_http_server, :directory)
    file_path = Path.join(directory, filename)

    # TODO: handle errors
    File.write(file_path, body)

    %HTTPResponse{
      status_code: 201,
      status_text: "Created"
    }
    |> HTTPResponse.put_header(:connection, connection)
  end

  defp response(%HTTPRequest{connection: connection}) do
    %HTTPResponse{
      status_code: 404,
      status_text: "Not Found"
    }
    |> HTTPResponse.put_header(:connection, connection)
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
