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
  # TODO: consider structuring HTTP request as described in the literature.
  # To do this include HTTPRequest.Head module

  @enforce_keys ~w[raw_request]a
  @http_request_keys [
    :body,
    :http_version,
    :method,
    :raw_headers,
    :raw_request,
    :raw_request_line,
    :url,
    headers: [
      "accept-encoding": "",
      connection: "Keep-Alive",
      "content-length": 0
    ]
  ]

  defstruct @http_request_keys

  @accepted_header_names ~w[
    accept
    accept-encoding
    connection
    content-length
    content-type
    host
    user-agent
  ]

  def get(%__MODULE__{} = req, :header, name) do
    req.headers[name]
  end

  def new(raw_request) do
    %__MODULE__{
      body: "",
      raw_request: raw_request
    }
  end

  def parse_headers(%__MODULE__{raw_headers: raw_headers} = req) do
    raw_headers
    |> Enum.reduce(req, fn raw_header, acc_req ->
      [name, value] =
        raw_header
        |> String.split(":", parts: 2)
        |> Enum.map(&String.trim/1)

      put(acc_req, :header, String.downcase(name), value)
    end)
  end

  def put(
        %__MODULE__{raw_headers: _raw_headers} = req,
        :header,
        name,
        value
      )
      when name in @accepted_header_names do
    atomized_name = String.to_atom(name)
    put(req, :header, atomized_name, value)
  end

  def put(
        %__MODULE__{raw_headers: _raw_headers, headers: headers} = req,
        :header,
        name,
        value
      )
      when is_atom(name) do
    new_headers = Keyword.put(headers, name, value)
    %__MODULE__{req | headers: new_headers}
  end

  def put(
        %__MODULE__{raw_headers: _raw_headers, headers: _headers},
        :header,
        name,
        _value
      )
      when is_binary(name) do
    require Logger
    Logger.debug("Unknown header name: #{name}")
  end

  def put(%__MODULE__{} = req, key, value) when key in @http_request_keys do
    struct(req, %{key => value})
  end

  def parse_request_line(%__MODULE__{raw_request: raw_request} = req) do
    [head, body] = String.split(raw_request, "\r\n\r\n")

    [raw_request_line | raw_headers] = String.split(head, "\r\n", trim: true)

    [method, url, http_version] = String.split(raw_request_line, " ", trim: true)

    method = String.upcase(method)
    http_version = String.upcase(http_version)

    req
    |> put(:raw_request_line, raw_request_line)
    |> put(:raw_headers, raw_headers)
    |> put(:body, body)
    |> put(:method, method)
    |> put(:url, url)
    |> put(:http_version, http_version)
  end
end

defmodule Server.HTTPResponse do
  @enforce_keys ~w[status_code status_text]a
  defstruct [
    :status_code,
    :status_text,
    body: "",
    headers: ["content-length": 0, connection: "Keep-Alive"],
    protocol: "HTTP/1.1"
  ]

  def put_body(%__MODULE__{} = res, body) when is_binary(body) do
    %__MODULE__{res | body: body}
  end

  def put_header(%__MODULE__{} = res, :connection, value) do
    do_put_header(res, :connection, value)
  end

  def put_header(%__MODULE__{} = res, :"content-encoding", value) do
    do_put_header(res, :"content-encoding", value)
  end

  def put_header(%__MODULE__{} = res, :"content-length", value) do
    do_put_header(res, :"content-length", value)
  end

  def put_header(%__MODULE__{} = res, :"content-type", value) do
    do_put_header(res, :"content-type", value)
  end

  def put_header(%__MODULE__{} = res, :date, value) do
    do_put_header(res, :date, value)
  end

  def new(status_code) when is_integer(status_code) do
    %__MODULE__{status_code: status_code, status_text: status_text(status_code)}
  end

  def status_text(status_code) when is_integer(status_code) do
    %{
      200 => "OK",
      201 => "Created",
      404 => "Not Found"
    }[status_code]
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

  defp header_to_string({:"content-encoding", value}) do
    "Content-Encoding: #{value}"
  end

  defp header_to_string({:"content-length", value}) do
    "Content-Length: #{value}"
  end

  defp header_to_string({:"content-type", value}) do
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

  defp response(%HTTPRequest{body: _body, method: "GET", url: "/"} = req) do
    connection = HTTPRequest.get(req, :header, :connection)

    HTTPResponse.new(200)
    |> HTTPResponse.put_header(:connection, connection)
  end

  defp response(
         %HTTPRequest{
           method: "GET",
           url: "/user-agent"
         } = req
       ) do
    connection = HTTPRequest.get(req, :header, :connection)
    user_agent = HTTPRequest.get(req, :header, :"user-agent")

    HTTPResponse.new(200)
    |> HTTPResponse.put_body(user_agent)
    |> HTTPResponse.put_header(:connection, connection)
    |> HTTPResponse.put_header(:"content-type", "text/plain")
    |> HTTPResponse.put_header(:"content-length", byte_size(user_agent))
  end

  defp response(
         %HTTPRequest{
           method: "GET",
           url: "/echo/" <> str
         } = req
       ) do
    connection = HTTPRequest.get(req, :header, :connection)

    accept_encoding =
      HTTPRequest.get(req, :header, :"accept-encoding")

    encodings =
      accept_encoding
      |> String.split(",", trim: true)
      |> MapSet.new(&String.trim/1)

    res =
      if MapSet.member?(encodings, "gzip") do
        str_gz = :zlib.gzip(str)

        HTTPResponse.new(200)
        |> HTTPResponse.put_body(str_gz)
        |> HTTPResponse.put_header(:"content-length", byte_size(str_gz))
        |> HTTPResponse.put_header(:"content-encoding", "gzip")
      else
        HTTPResponse.new(200)
        |> HTTPResponse.put_body(str)
        |> HTTPResponse.put_header(:"content-length", byte_size(str))
      end

    res
    |> HTTPResponse.put_header(:connection, connection)
    |> HTTPResponse.put_header(:"content-type", "text/plain")
  end

  defp response(
         %HTTPRequest{
           method: "GET",
           url: "/files/" <> filename
         } = req
       ) do
    connection = HTTPRequest.get(req, :header, :connection)

    directory = Application.get_env(:codecrafters_http_server, :directory)
    file_path = Path.join(directory, filename)

    res =
      case File.read(file_path) do
        {:ok, body} ->
          HTTPResponse.new(200)
          |> HTTPResponse.put_body(body)
          |> HTTPResponse.put_header(:"content-type", "application/octet-stream")
          |> HTTPResponse.put_header(:"content-length", byte_size(body))

        {:error, :enoent} ->
          HTTPResponse.new(404)
      end

    res
    |> HTTPResponse.put_header(:connection, connection)
  end

  defp response(
         %HTTPRequest{
           body: body,
           method: "POST",
           url: "/files/" <> filename
         } = req
       ) do
    connection = HTTPRequest.get(req, :header, :connection)

    directory = Application.get_env(:codecrafters_http_server, :directory)
    file_path = Path.join(directory, filename)

    # TODO: handle errors
    File.write(file_path, body)

    HTTPResponse.new(201)
    |> HTTPResponse.put_header(:connection, connection)
  end

  defp response(%HTTPRequest{} = req) do
    connection = HTTPRequest.get(req, :header, :connection)

    HTTPResponse.new(404)
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
