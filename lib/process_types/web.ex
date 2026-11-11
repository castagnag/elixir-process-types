defmodule ProcessTypes.Web do
  @moduledoc """
  The playground: a page where programs are type-checked as they are written.

      GET  /          the page
      GET  /examples  the programs of examples/, as [{"name", "file", "source"}], where
                      "file" is the file name without .exs
      GET  /docs      README.md and GRAMMAR.md, as [{"name", "source"}]
      POST /check     {"source": ..., "mode": "infer" | "ground" | "reconstruct", "split": true | false,
                      "client": ...},
                      answered by {"ok", "diagnostics", "functions", "main",
                      "main_bare"} or
                      {"error"}; the mode is inference by default (GRAMMAR.md, §9), "split"
                      is false by default (experimental, GRAMMAR.md, §10), and
                      a check interrupts the previous one of the same "client"

  `mix playground` serves it on localhost. Checks run with limits of time and memory
  (`ProcessTypes.Web.Runner`), and the answers carry CORS headers, so that the page may
  also be served from elsewhere, with its `PLAYGROUND_API` pointing here.
  """

  use Plug.Router

  alias ProcessTypes.{Printer, TypeSyntax}

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
        mode =
          case params["mode"] do
            "ground" -> :ground
            "reconstruct" -> :reconstruct
            _ -> :infer
          end

        opts = [mode: mode, split: params["split"] == true, client: params["client"]]
        json(conn, 200, check(source, opts))

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
      functions:
        Enum.map(result.functions, fn
          %{type: false} = f ->
            written = TypeSyntax.to_string(f.annotation)
            %{name: f.name, type: written, bare: written}

          f ->
            %{
              name: f.name,
              type: Printer.to_string(f.type, f.names),
              bare: Printer.to_string(f.type, f.names, decorations: false)
            }
        end),
      main: result.main && Printer.to_string(result.main, result.names),
      main_bare: result.main && Printer.to_string(result.main, result.names, decorations: false),
      mode: Atom.to_string(result.mode),
      # The interfaces reconstructed (reconstruction mode): line is null for the main process.
      interfaces:
        for %{line: line, type: type} <- result.interfaces, type do
          %{
            line: line,
            type: Printer.to_string(type, result.names),
            bare: Printer.to_string(type, result.names, decorations: false)
          }
        end
    }
  end

  # The examples, named after their file unless @titles names them otherwise: the files
  # of @titles first, in this order, then the others by file name.
  @titles [
    {"server", "Server"},
    {"server_decorated", "Server (with decorations)"},
    {"server_errors", "Server (with errors)"},
    {"rpc", "Remote Procedure Call"},
    {"rpc_errors", "Remote Procedure Call (errors)"},
    {"run_job_simple", "run_job (double arrow)"},
    {"run_job", "run_job (no best decoration)"},
    {"run_job_shared", "run_job (shared, no decorations)"},
    {"counter", "counter"},
    {"mixing_correlation", "mixing_correlation"},
    {"mixing_multishot", "mixing_multishot"},
    {"mixing_write", "mixing_write"},
    {"reply_server", "Reply server (experimental split)"},
    {"my_server", "GenServer (parametrized types)"},
    {"recon_bank", "Reconstruction: bank account"},
    {"recon_bank_errors", "Reconstruction: bank account (errors)"},
    {"recon_server", "Reconstruction: Server"},
    {"recon_server_errors", "Reconstruction: Server (errors)"},
    {"recon_jobs", "Reconstruction: jobs (recursive interface)"},
    {"recon_forward", "Reconstruction: forwarding (dependencies)"},
    {"recon_appendix", "Reconstruction: self-sends, refinements, pure calls"},
    {"recon_closure", "Reconstruction: closure sent to a received pid"},
    {"recon_limits_coverage", "Reconstruction limits 1: outside the coverage"},
    {"recon_limits_maximal", "Reconstruction limits 2: another maximal interface"},
    {"recon_limits_solving", "Reconstruction limits 3: polarity, cycle"},
    {"recon_limits_too_large", "Reconstruction limits 4: interface too large"},
    {"recon_limits_overloaded", "Reconstruction limits 4: effect-overloaded function"}
  ]

  defp examples do
    @examples
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&{Path.basename(&1, ".exs"), &1})
    |> Enum.sort_by(fn {base, _} ->
      {Enum.find_index(@titles, &(elem(&1, 0) == base)) || length(@titles), base}
    end)
    |> Enum.map(fn {base, path} ->
      %{
        name: List.keyfind(@titles, base, 0, {base, base}) |> elem(1),
        file: base,
        source: File.read!(path)
      }
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
