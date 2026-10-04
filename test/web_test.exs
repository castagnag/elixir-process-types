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
    [first | _] = examples = JSON.decode!(conn.resp_body)
    assert first["name"] == "dispatcher"
    assert "mixing_write" in Enum.map(examples, & &1["name"])
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
    conn = call(:post, "/check", %{source: File.read!("examples/dispatcher.exs")})
    assert %{"ok" => true, "main" => main} = JSON.decode!(conn.resp_body)
    assert main =~ "{:run, (-> Server.job_writes)"
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

  test "a request without source" do
    assert call(:post, "/check", %{program: "x"}).status == 400
  end
end
