defmodule ProcessTypes.Web do
  @moduledoc """
  The playground: a page where programs are type-checked as they are written.

      GET  /          the page
      GET  /examples  the programs of examples/, as [{"name", "source"}]
      GET  /docs      README.md and GRAMMAR.md, as [{"name", "source"}]
      POST /check     {"source": ..., "mode": "infer" | "ground"}, answered by {"ok",
                      "diagnostics", "functions", "main"} or {"error"}; the mode is
                      inference by default (GRAMMAR.md, §9)

  `mix playground` serves it on localhost. A check runs with a time limit, and the
  answers carry CORS headers, so that the page may also be served from elsewhere,
  with its `PLAYGROUND_API` pointing here.
  """

  use Plug.Router

  @root Path.expand("../..", __DIR__)
  @examples Path.join(@root, "examples")
  @timeout 10_000

  plug :cors
  plug :match
  plug Plug.Parsers, parsers: [:json], pass: ["*/*"], json_decoder: JSON, length: 1_000_000
  plug :dispatch

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:process_types, "priv/playground/index.html"))
  end

  get "/examples" do
    json(conn, 200, examples())
  end

  get "/docs" do
    json(conn, 200, docs())
  end

  post "/check" do
    case conn.body_params do
      %{"source" => source, "mode" => "ground"} when is_binary(source) ->
        json(conn, 200, check(source, mode: :ground))

      %{"source" => source} when is_binary(source) ->
        json(conn, 200, check(source))

      _ ->
        json(conn, 400, %{error: ~s(expected {"source": "..."})})
    end
  end

  options _ do
    send_resp(conn, 204, "")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @doc "Checks a program within the time limit; the result is ready for JSON."
  def check(source, opts \\ []) do
    task =
      Task.async(fn ->
        try do
          {:ok, ProcessTypes.check_string(source, opts)}
        catch
          kind, reason -> {:crash, Exception.format_banner(kind, reason)}
        end
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> encode(result)
      {:ok, {:crash, message}} -> %{error: "the checker failed: " <> message}
      {:exit, reason} -> %{error: "the checker failed: #{inspect(reason)}"}
      nil -> %{error: "the check takes more than #{div(@timeout, 1000)} seconds"}
    end
  end

  defp encode(result) do
    %{
      ok: result.diagnostics == [],
      diagnostics: Enum.map(result.diagnostics, &%{line: &1.line, message: &1.message}),
      functions: Enum.map(result.functions, fn {name, type} -> %{name: name, type: type} end),
      main: result.main && ProcessTypes.Printer.to_string(result.main, result.names)
    }
  end

  # The examples, the running example of Section 2 first.
  defp examples do
    @examples
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.sort_by(&{not String.ends_with?(&1, "/dispatcher.exs"), &1})
    |> Enum.map(&%{name: Path.basename(&1, ".exs"), source: File.read!(&1)})
  end

  defp docs do
    for {name, file} <- [{"README", "README.md"}, {"GRAMMAR", "GRAMMAR.md"}] do
      %{name: name, source: File.read!(Path.join(@root, file))}
    end
  end

  defp cors(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "content-type")
  end

  defp json(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(data))
  end
end
