# elixir bench/report.exs OUT: from OUT/machine.txt, OUT/rows.txt and OUT/results.csv
# (written by bench/bench.sh), writes OUT/tables.md and the four files that the
# appendix of the paper inputs: measurements-setup.tex, measurements-configs.tex,
# measurements-steps.tex and measurements-tallying.tex.

[out] = System.argv()

read = fn name ->
  out |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
end

machine =
  Map.new(read.("machine.txt"), fn line ->
    [k, v] = String.split(line, "=", parts: 2)
    {k, v}
  end)

fields =
  ~w(status constraints interfaces total generation tally_calls tallying bounds derivation dependencies solving checking)a

# The fastest complete run of each line; :timeout or :failed if there is none.
runs =
  read.("results.csv")
  |> Enum.map(&String.split(&1, ","))
  |> Enum.group_by(&hd/1, fn [_id, _run | rest] -> rest end)

best = fn id ->
  complete =
    for values when length(values) == 12 <- Map.get(runs, id, []) do
      [status | numbers] = values

      fields
      |> tl()
      |> Enum.zip(Enum.map(numbers, fn n -> n |> Float.parse() |> elem(0) end))
      |> Map.new()
      |> Map.put(:status, status)
    end

  cond do
    complete != [] -> Enum.min_by(complete, & &1.total)
    ["timeout"] in Map.get(runs, id, []) -> :timeout
    true -> :failed
  end
end

rows =
  for line <- read.("rows.txt") do
    [id, table, mode | labels] = String.split(line, "|")
    best = best.(id)

    labels =
      case {table, best} do
        {"steps", %{status: "rejected:" <> _}} -> [hd(labels) <> " (rejected)"]
        _ -> labels
      end

    %{id: id, table: table, mode: mode, labels: labels, best: best}
  end

# Milliseconds: one decimal below 100, none above; thousands separated by `sep`.
ms = fn x, sep ->
  if x < 100 do
    :erlang.float_to_binary(x * 1.0, decimals: 1)
  else
    x
    |> round()
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1#{String.reverse(sep)}")
    |> String.reverse()
  end
end

count = fn x -> x |> round() |> Integer.to_string() end

outcome = fn
  "accepted" -> "accepted"
  "rejected:" <> n -> "rejected (#{n})"
end

missing = fn
  :timeout, n -> ["no answer in #{machine["timeout"]} s" | List.duplicate("", n - 1)]
  :failed, n -> ["failed" | List.duplicate("", n - 1)]
end

recon = fn b -> b.bounds + b.derivation + b.dependencies + b.solving end

# The cells of a row of each table, after its labels; `sep` separates thousands,
# `none` is the empty cell.
cells = fn
  %{table: "configs", best: b, mode: mode}, sep, none when is_map(b) ->
    [
      count.(b.constraints),
      count.(b.tally_calls),
      ms.(b.generation, sep),
      if(mode == "reconstruct", do: ms.(recon.(b), sep), else: none),
      ms.(b.tallying, sep),
      ms.(b.total, sep)
    ]

  %{table: "steps", best: b}, sep, _none when is_map(b) ->
    [
      count.(b.constraints),
      count.(b.interfaces),
      ms.(b.generation, sep),
      ms.(b.bounds, sep),
      ms.(b.derivation, sep),
      ms.(b.dependencies, sep),
      ms.(b.solving, sep),
      ms.(b.checking, sep),
      ms.(b.total, sep)
    ]

  %{table: "tallying", best: b}, sep, _none when is_map(b) ->
    [outcome.(b.status), count.(b.tally_calls), ms.(b.tallying, sep), ms.(b.total, sep)]

  %{table: "configs", best: b}, _, _ -> missing.(b, 6)
  %{table: "steps", best: b}, _, _ -> missing.(b, 9)
  %{table: "tallying", best: b}, _, _ -> missing.(b, 4)
end

headers = %{
  "configs" =>
    ~w(program decorations interfaces constraints) ++
      ["tallying calls", "generation", "reconstruction", "tallying", "total"],
  "steps" =>
    ["example", "constraints", "interfaces found"] ++
      ~w(generation bounds derivation dependencies solving checking total),
  "tallying" =>
    ["program", "decorations", "tallying", "outcome", "tallying calls", "time in tallying", "total"]
}

# Shorter column names for the paper.
short = %{
  "constraints" => "constr.",
  "tallying calls" => "calls",
  "reconstruction" => "reconstr.",
  "dependencies" => "depend.",
  "interfaces found" => "interf.",
  "time in tallying" => "time in it"
}

# Alignment of the columns: labels and outcomes to the left, numbers to the right.
aligns = %{"configs" => "lllrrrrrr", "steps" => "lrrrrrrrrr", "tallying" => "llllrrr"}

titles = %{
  "configs" => "Decorations written or inferred, interfaces declared or reconstructed",
  "steps" => "The steps of the reconstruction",
  "tallying" => "Locating errors, and inference without a change of tallying"
}

tex_escape = fn s -> String.replace(s, ~r/[_%&#]/, "\\\\\\0") end

# --- Markdown --------------------------------------------------------------------------

setup =
  "#{machine["cpu"]} (#{machine["cores"]} logical cores, #{machine["memory"]} GB of memory), " <>
    "#{machine["os"]}, Elixir #{machine["elixir"]} on Erlang/OTP #{machine["otp"]}, " <>
    "commit #{machine["commit"]} of the prototype, #{machine["date"]}. " <>
    "Fastest of #{machine["runs"]} runs, each in a fresh virtual machine; times in " <>
    "milliseconds, without the start of the virtual machine (#{machine["vm_start"]} ms)."

md =
  for table <- ~w(configs steps tallying), table_rows = Enum.filter(rows, &(&1.table == table)) do
    head = headers[table]

    lines =
      for row <- table_rows, do: "| " <> Enum.join(row.labels ++ cells.(row, ",", "–"), " | ") <> " |"

    [
      "## #{titles[table]}\n",
      "| " <> Enum.join(head, " | ") <> " |",
      "|" <> String.duplicate("---|", length(head))
      | lines
    ]
    |> Enum.join("\n")
  end

File.write!(Path.join(out, "tables.md"), "# Measurements\n\n#{setup}\n\n" <> Enum.join(md, "\n\n") <> "\n")

# --- LaTeX -----------------------------------------------------------------------------

File.write!(
  Path.join(out, "measurements-setup.tex"),
  """
  % Generated by bench/bench.sh of the prototype: do not edit.
  The figures were measured on a machine with the processor #{tex_escape.(machine["cpu"])}
  (#{machine["cores"]} logical cores, #{machine["memory"]}~GB of memory), under
  #{tex_escape.(machine["os"])}, with Elixir~#{machine["elixir"]} on Erlang/OTP~#{machine["otp"]}
  (commit #{tex_escape.(machine["commit"])} of the prototype, #{machine["date"]}). Each line is the
  fastest of #{machine["runs"]} runs, each in a fresh virtual machine. Times are in
  milliseconds and do not count the start of the virtual machine (#{machine["vm_start"]}~ms
  on this machine).
  """
)

for table <- ~w(configs steps tallying) do
  table_rows = Enum.filter(rows, &(&1.table == table))

  body =
    for row <- table_rows do
      "  " <> Enum.join(Enum.map(row.labels, tex_escape) ++ cells.(row, "\\,", "--"), " & ") <> " \\\\"
    end

  File.write!(
    Path.join(out, "measurements-#{table}.tex"),
    """
    % Generated by bench/bench.sh of the prototype: do not edit.
    \\begin{tabular}{@{}#{aligns[table]}@{}}
    \\toprule
      #{headers[table] |> Enum.map(&Map.get(short, &1, &1)) |> Enum.join(" & ")} \\\\
    \\midrule
    #{Enum.join(body, "\n")}
    \\bottomrule
    \\end{tabular}
    """
  )
end
