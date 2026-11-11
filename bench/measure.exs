# mix run bench/measure.exs FILE MODE [KEY=VALUE ...]
#
# Checks FILE once, in mode MODE (infer or reconstruct), and prints one CSV line:
#
#   status,constraints,interfaces,total,generation,tally_calls,tallying,
#   bounds,derivation,dependencies,solving,checking
#
# Times are in milliseconds, measured inside the VM (its start is not counted), with
# every module of the application loaded beforehand.
#   total         the whole check (parsing included)
#   generation    total minus the solving phase (inference) or minus the last four
#                 steps of the reconstruction: parsing and constraint generation
#   tally_calls   number of calls to tallying; tallying: the time spent in them
#   bounds        reconstruction only: the stores of bounds and the mailbox-pure functions
#   derivation    reconstruction only: the receives run, demands and coverage
#   dependencies  reconstruction only: the dependency order
#   solving       reconstruction only: polarities, extrema and the equation x = F(x, x)
#   checking      the solving phase of inference; in reconstruction mode, the checking
#                 step, which is that phase on the constraints with their interfaces
# KEY=VALUE are options of ProcessTypes.check_string/2, for comparisons:
# eliminate=false, tally=all, split=true.

[path, mode | extra] = System.argv()
mode = String.to_atom(mode)

opts =
  for kv <- extra do
    [k, v] = String.split(kv, "=")
    {String.to_atom(k), String.to_atom(v)}
  end

alias ProcessTypes.Backend.Infer
alias ProcessTypes.Reconstruct
alias ProcessTypes.Reconstruct.{Derive, Solve}

{:ok, modules} = :application.get_key(:process_types, :modules)
:ok = :code.ensure_modules_loaded(modules)
source = File.read!(path)

targets = [
  {Infer, :finish, 2},
  {Infer, :tally, 2},
  {Infer, :finish_with, 4},
  {Reconstruct, :run, 5},
  {Reconstruct, :world, 4},
  {Derive, :derive, 2},
  {Solve, :dependencies, 3},
  {Solve, :interface, 4}
]

parent = self()

# Durations and numbers of calls of the traced functions. A call nested in a call of
# the same function is not counted twice.
tracer =
  spawn(fn ->
    loop = fn loop, stack, acc ->
      receive do
        {:trace_ts, _, :call, {m, f, a}, ts} ->
          loop.(loop, [{{m, f, length(a)}, ts} | stack], acc)

        {:trace_ts, _, :return_from, mfa, _, ts} ->
          [{^mfa, t0} | rest] = stack
          nested? = Enum.any?(rest, fn {other, _} -> other == mfa end)

          acc =
            if nested?,
              do: acc,
              else: Map.update(acc, mfa, {ts - t0, 1}, fn {d, n} -> {d + ts - t0, n + 1} end)

          loop.(loop, rest, acc)

        {:done, ref} ->
          send(parent, {ref, acc})
      end
    end

    loop.(loop, [], %{})
  end)

for mfa <- targets, do: :erlang.trace_pattern(mfa, [{:_, [], [{:return_trace}]}], [:local])
:erlang.trace(self(), true, [:call, :monotonic_timestamp, {:tracer, tracer}])
t0 = System.monotonic_time()
result = ProcessTypes.check_string(source, [mode: mode] ++ opts)
t1 = System.monotonic_time()
:erlang.trace(self(), false, [:call])
ref = make_ref()
Process.sleep(50)
send(tracer, {:done, ref})

acc =
  receive do
    {^ref, acc} -> acc
  end

ms = fn native -> System.convert_time_unit(native, :native, :microsecond) / 1000 end
time = fn mfa -> acc |> Map.get(mfa, {0, 0}) |> elem(0) |> ms.() end
calls = fn mfa -> acc |> Map.get(mfa, {0, 0}) |> elem(1) end
show = fn x -> :erlang.float_to_binary(x * 1.0, decimals: 1) end

total = ms.(t1 - t0)
checking = if mode == :reconstruct, do: time.({Infer, :finish_with, 4}), else: time.({Infer, :finish, 2})
after_generation = if mode == :reconstruct, do: time.({Reconstruct, :run, 5}), else: checking

status =
  case result.diagnostics do
    [] -> "accepted"
    errors -> "rejected:#{length(errors)}"
  end

interfaces = if mode == :reconstruct, do: length(result.interfaces), else: 0

IO.puts(
  Enum.join(
    [
      status,
      length(result.constraints),
      interfaces,
      show.(total),
      show.(total - after_generation),
      calls.({Infer, :tally, 2}),
      show.(time.({Infer, :tally, 2})),
      show.(time.({Reconstruct, :world, 4})),
      show.(time.({Derive, :derive, 2})),
      show.(time.({Solve, :dependencies, 3})),
      show.(time.({Solve, :interface, 4})),
      show.(checking)
    ],
    ","
  )
)
