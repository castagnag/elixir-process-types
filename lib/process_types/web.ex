defmodule ProcessTypes.Web do
  @moduledoc """
  The playground: a page where programs are type-checked as they are written.

      GET  /          the page
      GET  /examples  the programs of examples/, as [{"name", "source"}]
      GET  /docs      README.md and GRAMMAR.md, as [{"name", "source"}]
      POST /check     {"source": ..., "mode": "infer" | "ground", "client": ...},
                      answered by {"ok", "diagnostics", "functions", "main"} or
                      {"error"}; the mode is inference by default (GRAMMAR.md, §9), and
                      a check interrupts the previous one of the same "client"

  `mix playground` serves it on localhost. Checks run with limits of time and memory
  (`ProcessTypes.Web.Runner`), and the answers carry CORS headers, so that the page may
  also be served from elsewhere, with its `PLAYGROUND_API` pointing here.
  """

  use Plug.Router

  @root Path.expand("../..", __DIR__)
  @examples Path.join(@root, "examples")

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
      %{"source" => source} = params when is_binary(source) ->
        mode = if params["mode"] == "ground", do: :ground, else: :infer
        json(conn, 200, check(source, mode: mode, client: params["client"]))

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

  @doc """
  Checks a program within the limits of `ProcessTypes.Web.Runner`; the result is ready
  for JSON. The option `client` names the requester, whose previous check, if still
  running, is interrupted; the other options are those of `ProcessTypes.check_string/2`.
  """
  def check(source, opts \\ []) do
    {client, opts} = Keyword.pop(opts, :client)

    # Encoding prints types, so it runs in the checking process: recursive nodes are
    # local to the process that built them (lib/vendor/README.md, patch 07).
    run = fn ->
      try do
        {:ok, source |> ProcessTypes.check_string(opts) |> encode()}
      catch
        kind, reason -> {:crash, Exception.format_banner(kind, reason)}
      end
    end

    case ProcessTypes.Web.Runner.run(run, client) do
      {:ok, {:ok, json}} -> json
      {:ok, {:crash, message}} -> %{error: "the checker failed: " <> message}
      {:error, message} -> %{error: message}
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

  # The examples, named after their file unless @titles names them otherwise; the
  # running example of Section 2 first, then the files of @titles.
  @titles [
    {"dispatcher_undecorated", "dispatcher (w/o decorations)"},
    {"dispatcher_errors", "dispatcher (errors)"},
    {"rpc", "Remote Procedure Call"},
    {"rpc_errors", "Remote Procedure Call (errors)"},
    {"run_job", "run_job (no best decoration)"},
    {"run_job_shared", "run_job (shared, no decorations)"}
  ]

  defp examples do
    @examples
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&{Path.basename(&1, ".exs"), &1})
    |> Enum.sort_by(fn {base, _} ->
      {base != "dispatcher", Enum.find_index(@titles, &(elem(&1, 0) == base)) || length(@titles), base}
    end)
    |> Enum.map(fn {base, path} ->
      %{name: List.keyfind(@titles, base, 0, {base, base}) |> elem(1), source: File.read!(path)}
    end)
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
