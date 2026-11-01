# The server MyServer, on top of a model of GenServer, with the types of the library
# written once, as definitions with parameters (GRAMMAR.md, §5.3). Parameters are not
# type variables: every instance is expanded before checking. So GenServer's functions
# are checked at the instances that MyServer needs, and `call`, which needs one per
# reply type, is written twice. As in the paper, the type of the server is the
# intersection of one instance of GenServer.server per clause of handle_call.
# The state is {:current, n}, since the prototype has no maps.
# Expected: rejected on the line marked "error:", accepted otherwise.

defmodule GenServer do
  $type request(c, r)     = {c, pid(r)}
  $type server(c, r)      = pid(request(c, r))
  $type result(r, s)      = {:reply, r, s} or {:noreply, s}
  $type callback(c, r, s) = (c, pid(r), s -> result(r, s))@[none(), term()]
  $type module(a, h, s)   = {(a -> {:ok, s}), h}

  # MyServer's instances: one arrow and one kind of request per clause of handle_call.
  $type state       = MyServer.state
  $type get_handler = callback(:get_int, integer(), state)
  $type set_handler = callback({:set_int, integer()}, :ok, state)
  $type get_request = request(:get_int, integer())
  $type set_request = request({:set_int, integer()}, :ok)
  $type handler     = get_handler and set_handler
  $type requests    = get_request or set_request

  $ (get_handler, get_request, state -> state)
  and (set_handler, set_request, state -> state)
  def step(h, {c, w}, s) do
    case h.(c, w, s) do
      {:reply, r, s2} -> send(w, r); s2
      {:noreply, s2}  -> s2
    end
  end

  # Reads the mailbox of the server: one process, hence one interface.
  $ (handler, state -> none())@[none(), requests]
  def loop(h, s) do
    receive do
      {_, _} = y -> loop(h, step(h, y, s))
    end
  end

  $ handler, state -> MyServer.server
  def serve(h, s) do
    $interface requests
    spawn(fn -> loop(h, s) end)
  end

  $ module(integer(), handler, state), integer() -> {:ok, MyServer.server}
  def start_link(m, v) do
    {i, h} = m
    {:ok, s} = i.(v)
    {:ok, serve(h, s)}
  end
end

defmodule MyServer do
  $type state  = {:current, integer()}
  $type server = GenServer.server(:get_int, integer())
             and GenServer.server({:set_int, integer()}, :ok)

  $ integer() -> {:ok, state}
  def init(v), do: {:ok, {:current, v}}

  $ (:get_int, pid(), state -> {:reply, integer(), state})
  and ({:set_int, integer()}, pid(), state -> {:reply, :ok, state})
  def handle_call(:get_int, _from, {:current, n} = s), do: {:reply, n, s}
  def handle_call({:set_int, v}, _from, _s), do: {:reply, :ok, {:current, v}}

  # The module as a value.
  $ (-> GenServer.module(integer(), GenServer.handler, state))
  def module() do
    $ integer() -> {:ok, state}
    i = fn v -> init(v) end
    $ (:get_int, pid(), state -> {:reply, integer(), state})
    and ({:set_int, integer()}, pid(), state -> {:reply, :ok, state})
    h = fn c, w, s -> handle_call(c, w, s) end
    {i, h}
  end

  $ integer() -> {:ok, server}
  def start_link(v), do: GenServer.start_link(module(), v)

  $ server -> integer()
  def get_int(p), do: CallGet.call(p, :get_int)

  $ server, integer() -> :ok
  def set_int(p, v), do: CallSet.call(p, {:set_int, v})
end

# GenServer.call at r = integer(). new_alias and receive_on stand for the aliases of
# Erlang, which the prototype does not have: a program is checked, never run.
defmodule CallGet do
  $ GenServer.server(:get_int, integer()), :get_int -> integer()
  def call(p, c) do
    w = new_alias()
    send(p, {c, w})
    receive_on(w)
  end

  $ (-> none())
  defp absurd(), do: absurd()
  $ (-> pid(integer()))
  defp new_alias(), do: absurd()
  $ pid(integer()) -> integer()
  defp receive_on(_w), do: absurd()
end

# GenServer.call at r = :ok: the same code.
defmodule CallSet do
  $ GenServer.server({:set_int, integer()}, :ok), {:set_int, integer()} -> :ok
  def call(p, c) do
    w = new_alias()
    send(p, {c, w})
    receive_on(w)
  end

  $ (-> none())
  defp absurd(), do: absurd()
  $ (-> pid(:ok))
  defp new_alias(), do: absurd()
  $ pid(:ok) -> :ok
  defp receive_on(_w), do: absurd()
end

# The client. Its interface does not list the replies, which arrive on the aliases.
$self_interface :nothing

{:ok, p} = MyServer.start_link(42)
MyServer.get_int(p)
:ok = MyServer.set_int(p, 24)
MyServer.get_int(p) + 1

send(p, {:foo, self()})     # error: {:foo, _} is not in the interface of the server
