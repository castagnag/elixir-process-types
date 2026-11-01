defmodule ProcessTypes.WebTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ProcessTypes.Web

  @opts Web.init([])

  defp call(method, path, body \\ nil) do
    conn = conn(method, path, body && JSON.encode!(body))
    conn = if body, do: put_req_header(conn, "content-type", "application/json"), else: conn
    Web.call(conn, @opts)
  end

  test "the page" do
    conn = call(:get, "/")
    assert conn.status == 200
    assert conn.resp_body =~ "<title>Process types playground</title>"
  end

  test "the examples, the running example first" do
    conn = call(:get, "/examples")
    assert conn.status == 200
    examples = JSON.decode!(conn.resp_body)

    assert ["Server", "Server (with decorations)", "Server (with errors)" | _] =
             Enum.map(examples, & &1["name"])

    assert "Remote Procedure Call" in Enum.map(examples, & &1["name"])
    assert "mixing_write" in Enum.map(examples, & &1["name"])
    assert ["server", "server_decorated", "server_errors" | _] = Enum.map(examples, & &1["file"])
    assert List.last(examples)["name"] == "MyServer (parametrized types)"
  end

  test "the documentation" do
    conn = call(:get, "/docs")
    assert conn.status == 200
    docs = JSON.decode!(conn.resp_body)
    assert Enum.map(docs, & &1["name"]) == ["README", "GRAMMAR"]
    assert Enum.all?(docs, &(&1["source"] != ""))
  end

  test "an accepted program" do
    conn = call(:post, "/check", %{source: "$self_interface :a\nsend(self(), :a)\n"})
    assert conn.status == 200
    assert %{"ok" => true, "diagnostics" => [], "main" => ":a"} = JSON.decode!(conn.resp_body)
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "an accepted program with recursive types, printed in the checking process" do
    conn = call(:post, "/check", %{source: File.read!("examples/server_decorated.exs")})
    assert %{"ok" => true, "main" => main} = JSON.decode!(conn.resp_body)
    assert main =~ "{:run, (-> Server.job_writes)"
  end

  test "an overloaded function shows each arrow with the decorations inferred for it" do
    # run_job_shared.exs without its rejected program
    source =
      "examples/run_job_shared.exs"
      |> File.read!()
      |> String.replace(
        ~r/^\$interface .*\n(?=spawn\(fn -> Single)|^spawn\(fn -> Single.*\n/m,
        ""
      )

    conn = call(:post, "/check", %{source: source})
    assert %{"ok" => true, "functions" => funs} = JSON.decode!(conn.resp_body)
    overloaded = Enum.find(funs, &(&1["name"] == "Overloaded.run_job/0"))
    assert overloaded["bare"] == "(-> term()) and (-> term())"
    assert [_, _] = String.split(overloaded["type"], ")@[none(), ", parts: 3) |> tl()
  end

  test "types are also sent without decorations" do
    conn =
      call(:post, "/check", %{source: File.read!("examples/server_decorated.exs"), mode: "ground"})

    assert %{"ok" => true, "main" => main, "main_bare" => bare, "functions" => funs} =
             JSON.decode!(conn.resp_body)

    assert main =~ "@" and not (bare =~ "@")
    assert Enum.any?(funs, &(&1["type"] =~ "@")) and Enum.all?(funs, &(not (&1["bare"] =~ "@")))
  end

  test "checking the same program twice gives the same result, whatever the VM did between" do
    source = File.read!("examples/server.exs")
    first = Web.check(source)
    for _ <- 1..3, do: {:erlang.unique_integer([:positive, :monotonic]), make_ref()}
    assert Web.check("$self_interface :a\nsend(self(), :a)\n").ok
    assert Web.check(source) == first
  end

  test "a rejected program, in ground mode" do
    source = "$self_interface :a\nsend(self(), :b)\n"
    conn = call(:post, "/check", %{source: source, mode: "ground"})

    assert %{"ok" => false, "diagnostics" => [%{"line" => 2, "message" => message}]} =
             JSON.decode!(conn.resp_body)

    assert message =~ "accepts :a, not :b"
  end

  test "a rejected program, in inference mode" do
    conn = call(:post, "/check", %{source: "$self_interface :a\nsend(self(), :b)\n"})
    assert %{"ok" => false, "diagnostics" => [%{"line" => 2}]} = JSON.decode!(conn.resp_body)
  end

  test "the experimental option split is off unless the request asks for it" do
    lines = fn body ->
      conn = call(:post, "/check", body)
      conn.resp_body |> JSON.decode!() |> Map.fetch!("diagnostics") |> Enum.map(& &1["line"])
    end

    source = """
    defmodule P do
      $ ({:a, pid(:r)} or {:b, pid(:s)} -> term())
      def f({c, w}), do: send(w, c)
    end
    """

    assert lines.(%{source: source}) == [3]
    assert lines.(%{source: source, split: false}) == [3]
    assert 3 in lines.(%{source: source, split: true})

    # The server of the example is accepted only with the option.
    example = File.read!("examples/reply_server.exs")
    server = Enum.find_index(String.split(example, "\n"), &(&1 =~ "defmodule ReplyServer")) + 1
    assert Enum.any?(lines.(%{source: example}), &(&1 < server + 10))
    refute Enum.any?(lines.(%{source: example, split: true}), &(&1 < server + 10))
  end

  test "a check interrupts the previous one of the same client, not those of others" do
    slow = File.read!("examples/server.exs")
    first = Task.async(fn -> Web.check(slow, client: "a") end)
    other = Task.async(fn -> Web.check(slow, client: "b") end)
    Process.sleep(200)
    assert %{ok: true} = Web.check("$self_interface :a\nsend(self(), :a)\n", client: "a")
    assert Task.await(first) == %{error: "interrupted by a newer check"}
    assert Task.yield(other, 100) == nil
    Task.shutdown(other, :brutal_kill)
  end

  test "the runner reports a check that dies, and goes on" do
    assert {:error, "the checker failed: " <> _} = Web.Runner.run(fn -> exit(:boom) end)
    assert {:ok, 42} = Web.Runner.run(fn -> 42 end)
  end

  test "a request without source" do
    assert call(:post, "/check", %{program: "x"}).status == 400
  end
end
