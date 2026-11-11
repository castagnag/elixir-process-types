# Measurements

The scripts of this directory produce the figures of the appendix "Prototype
Measurements" of the paper, and of its Section 10.4. They can be run on any machine.

## Requirements

- Elixir 1.20 or later (`mix`, `elixir`) and the dependencies of the prototype
  (`mix deps.get` once).
- `bash`, `git`, and either GNU `date` or `perl`. `timeout` (or `gtimeout` on macOS) is
  used when present; without it a run is not limited in time.

## Running

From the root of the prototype:

    bench/bench.sh            # 3 runs of each line, about 5 minutes on a 2021 laptop
    bench/bench.sh 5          # 5 runs of each line
    ABLATION=0 bench/bench.sh # skip the last three lines of Table 3 (the paper needs them)

Environment variables: `TIMEOUT` (seconds allowed to one run, default 900), `OUT` (output
directory, default `bench/out/<host>-<date>`, erased first), `ABLATION`.

Close other programs first: each figure is the fastest of the runs, which removes most of
the noise, but not a machine that is busy throughout.

## What is measured

Each line of a table is one program checked in one mode. Each run starts a fresh virtual
machine, loads every module of the prototype, then checks the program once
(`bench/measure.exs`); the times are measured inside the virtual machine, in
milliseconds, by tracing the functions of the prototype. The start of the virtual
machine is measured apart (`mix run -e ':ok'`) and reported in the setup sentence. Of the
runs of a line, the one of smallest total time is kept.

| column | meaning |
|---|---|
| constraints | constraints deferred to tallying |
| tallying calls | calls to tallying: one per connected component of the constraints on an accepted program, more to locate errors |
| generation | parsing and constraint generation (total minus what follows) |
| bounds | reconstruction: reading the bounds of the constraints, mailbox-pure functions |
| derivation | reconstruction: the receives run, demands, coverage |
| dependencies | reconstruction: the dependency order of the spawns |
| solving | reconstruction: polarities, extrema, the equation x = F(x, x) |
| reconstruction | the four previous columns together (Table 1) |
| checking | the solving phase of inference; in reconstruction mode, the checking step |
| tallying | time spent in the calls to tallying (part of checking) |
| total | the whole check |

The programs:

- **Table 1** (`measurements-configs.tex`). Two programs, each in four configurations:
  decorations written or inferred, interfaces declared (inference mode) or reconstructed
  (reconstruction mode). *server* is the server of Section 2 without the jobs
  (`bench/programs/basic_decorated.exs`, `bench/programs/basic.exs`); *server with jobs*
  is `examples/server_decorated.exs` and `examples/server.exs`. The reconstructed
  configurations are these files without their `$interface` lines, written by the script
  in `OUT/programs/`: both lines for *server*, the worker's for *server with jobs* (with
  no decoration and no interface at all, the prototype rejects that program: see
  `_claude/recon/REPORT.md`, deviation 9).
- **Table 2** (`measurements-steps.tex`). The steps of the reconstruction on seven of the
  `examples/recon_*.exs`.
- **Table 3** (`measurements-tallying.tex`). The rejected server
  (`examples/server_errors.exs`), with every decoration written and with those of the
  jobs removed, where locating the errors solves many prefixes of the constraints; then,
  unless `ABLATION=0`, `examples/server.exs` as the prototype checks it, without the
  elimination of bound variables (`eliminate=false`) and with all the solutions computed
  (`tally=all`). The third change
  of tallying described in the paper (one system of equations) is a patch of the vendored
  code and has no switch.

To measure another program or option:

    mix run bench/measure.exs FILE infer|reconstruct [eliminate=false] [tally=all] [split=true]

prints one CSV line, whose columns are listed at the top of `bench/measure.exs`.

## Output

In `OUT`:

- `machine.txt`, `rows.txt`, `results.csv`: the machine, the lines, and every run;
- `tables.md`: the three tables, readable;
- `measurements-setup.tex`, `measurements-configs.tex`, `measurements-steps.tex`,
  `measurements-tallying.tex`: what the paper inputs;
- `programs/`: the variants that the script derived.

`elixir bench/report.exs OUT` rebuilds the tables from `results.csv` without measuring
again.

## Bringing the results into the paper

1. Copy the four `measurements-*.tex` files into `document/` of the paper, over the
   existing ones, and rebuild. The appendix (`app-measurements.tex`) inputs them: its
   tables and its setup sentence need no editing.
2. Reread the sentences that quote an order of magnitude; they are written in words, not
   generated:
   - `elixir.tex`, Section 10.4 (`sec:elixir-tallying`): the time of inference on the
     program of Section 2 without decorations; the factor gained by the elimination of
     bound variables and by the search of one solution; the time to reject the program
     with ill-typed sends; "every other variant ... in less than a second"; and the last
     paragraph, on what the reconstruction adds;
   - `conclusion.tex`: the sentence on the prototype;
   - `app-measurements.tex`: the comments under the tables.
3. If a line reads "no answer in N s" or "failed", look at `results.csv`, and run that
   line by hand with `mix run bench/measure.exs`.
