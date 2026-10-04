defmodule ProcessTypes.Web.Runner do
  @moduledoc """
  Runs the checks of the playground, so that no check can bring the server down.

  Each check runs in a process of its own, and it is interrupted, with an answer that
  says why, when

    - it takes more than `@timeout` milliseconds;
    - its heap exceeds `@max_heap` bytes (`max_heap_size`, which also counts its process
      dictionary, where Descr keeps its recursive nodes);
    - the whole VM exceeds `@max_memory` bytes (polled every `@poll` milliseconds: this
      covers the ETS tables of tallying, which are outside the heap);
    - the page that requested it requests a newer check (the page shows only the answer
      to its last request);
    - `@max_checks` checks are running and another one arrives (the oldest one stops).
  """

  use GenServer

  @timeout 90_000
  @max_heap 2 * 1024 ** 3
  @max_memory 4 * 1024 ** 3
  @poll 200
  @max_checks 4

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Runs `fun` with the limits above, on behalf of `client` (any term; nil for a client
  whose checks are never interrupted by its next one). Answers `{:ok, result}` or
  `{:error, message}`.
  """
  def run(fun, client \\ nil), do: GenServer.call(__MODULE__, {:run, fun, client}, :infinity)

  @impl true
  def init(:ok) do
    :timer.send_interval(@poll, :poll)
    {:ok, %{checks: %{}, count: 0}}
  end

  @impl true
  def handle_call({:run, fun, client}, from, state) do
    state =
      Enum.reduce(state.checks, state, fn {pid, check}, state ->
        if client != nil and check.client == client,
          do: stop(state, pid, "interrupted by a newer check"),
          else: state
      end)

    state =
      if map_size(state.checks) >= @max_checks do
        {pid, _} = Enum.min_by(state.checks, fn {_, check} -> check.number end)
        stop(state, pid, "interrupted: more than #{@max_checks} checks at once")
      else
        state
      end

    runner = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{
          size: div(@max_heap, :erlang.system_info(:wordsize)),
          kill: true,
          error_logger: false,
          include_shared_binaries: true
        })

        send(runner, {:done, self(), fun.()})
      end)

    timer = Process.send_after(self(), {:timeout, pid}, @timeout)
    check = %{from: from, client: client, ref: ref, timer: timer, number: state.count}
    {:noreply, %{state | checks: Map.put(state.checks, pid, check), count: state.count + 1}}
  end

  @impl true
  def handle_info({:done, pid, result}, state), do: {:noreply, finish(state, pid, {:ok, result})}

  def handle_info({:timeout, pid}, state) do
    {:noreply, stop(state, pid, "the check takes more than #{div(@timeout, 1000)} seconds")}
  end

  def handle_info({:DOWN, _, :process, pid, reason}, state) do
    message =
      case reason do
        :killed -> "the check exceeds #{gb(@max_heap)} of memory"
        reason -> "the checker failed: #{inspect(reason)}"
      end

    {:noreply, finish(state, pid, {:error, message})}
  end

  def handle_info(:poll, state) do
    if state.checks != %{} and :erlang.memory(:total) > @max_memory do
      message = "the server exceeds #{gb(@max_memory)} of memory"
      {:noreply, Enum.reduce(Map.keys(state.checks), state, &stop(&2, &1, message))}
    else
      {:noreply, state}
    end
  end

  # Kills the check `pid`, if it still runs, and answers `message` to its client.
  defp stop(state, pid, message) do
    if Map.has_key?(state.checks, pid), do: Process.exit(pid, :kill)
    finish(state, pid, {:error, message})
  end

  defp finish(state, pid, answer) do
    case Map.pop(state.checks, pid) do
      {nil, _} ->
        state

      {check, checks} ->
        Process.demonitor(check.ref, [:flush])
        Process.cancel_timer(check.timer)
        GenServer.reply(check.from, answer)
        %{state | checks: checks}
    end
  end

  defp gb(bytes), do: "#{div(bytes, 1024 ** 3)} GB"
end
