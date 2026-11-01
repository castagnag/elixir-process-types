# elixir-process-types

A prototype type checker for Elixir processes. It implements the type system of
Sections 3–6 of the accompanying paper on set-theoretic types for Elixir actors, and
the inference of decorations of Section 8:
a process is typed `pid(t)`, where `t` is the type of the messages it accepts, and
an arrow carries the mailbox decorations of the process that runs it, written
`(s -> t)@[o, i]`, or `(s -> t) @ u` when both are u. Programs are type-checked, never
run.

By default the decorations that annotations do not write are inferred, as in
Section 8 of the paper: they get type variables, and the constraints that the rules
generate are solved by tallying. In ground mode (`--ground`) an undecorated arrow is
read as `@[none(), term()]` and every constraint is checked at once (GRAMMAR.md, §9).

Decorations are therefore optional, but the cost of inference depends on which ones
are omitted. Before tallying, the variables that only bare bounds constrain (such as
the components of tuple patterns) are replaced by their bounds, which preserves
satisfiability, and tallying searches for one solution instead of all of them
(`ProcessTypes.Eliminate`, `lib/vendor/README.md`, patch 08); the solution is built as
one system of mutually recursive types (patch 09). On the dispatcher of Section 2
([examples/server_decorated.exs](examples/server_decorated.exs)), any set of decorations can be
removed: checking takes a tenth of a second while the decorations of the job type are
written, and about a second without them, also without any decoration
([examples/server.exs](examples/server.exs)). Locating
errors costs more: on [examples/server_errors.exs](examples/server_errors.exs),
9 to 15 s without the decorations of the job type.

**Status:** work in progress. The checker implements Sections 3–6, and the inference of
Section 8, on the language specified in [GRAMMAR.md](GRAMMAR.md), which also lists the
deviation that Descr imposes (no integer singleton types); type definitions may be
recursive. [examples/](examples/) holds the examples of Sections 2, 4.1, 6.3 and 8.3 of
the paper; the test suite checks that each reports errors exactly on the lines marked
`# error:`, in both modes. Inference handles programs whose constraints need a recursive
solution, such as the jobs of Section 2 with an undecorated job type, and annotations
that mention recursive tuple types, such as lists (with provisional patches to the
copied Descr, see [lib/vendor/README.md](lib/vendor/README.md)). With no decoration at
all, [examples/run_job_shared.exs](examples/run_job_shared.exs) shows that two programs
which no single decorated arrow can serve share one `run_job` annotated with two arrows.
An experimental option, off by default, goes beyond the paper: it types a branch once per
summand of its refined type, so that a tuple pattern keeps the correlation between
components (GRAMMAR.md, §10, and [examples/reply_server.exs](examples/reply_server.exs)).

## Usage

In a fresh clone, fetch the dependencies first (they are not in git):

```
mix deps.get
mix typecheck examples/server_decorated.exs examples/server_errors.exs
mix typecheck --ground examples/server_decorated.exs     # every decoration known
mix typecheck --trace examples/counter.exs          # the constraints given to tallying
mix typecheck --experimental-split examples/reply_server.exs   # GRAMMAR.md, §10
mix test
```

For an accepted program, `mix typecheck` prints the annotated functions and the type
of the main process; otherwise it prints the errors, one per line, as
`file:line: error: message`.

## Playground

```
mix playground            # http://localhost:4000
mix playground --port 4100
```

The playground is a page where a program is checked as it is written. The examples
can be loaded from a menu, or directly with `?example=name`, by menu name or file name (e.g.
`http://localhost:4000/?example=server_errors`), and each error links to its line. The border between the two panes can be dragged
(or moved with the arrow keys), and the README and the grammar open from the header.
Each check runs in a process of its own (`ProcessTypes.Web.Runner`), which is interrupted
after 90 s, when its heap exceeds 2 GB, when the server exceeds 4 GB, or when the same
page asks for a newer check; the answer then says why, and the server goes on.
The server listens on localhost only. Its API (`GET /examples`, `GET /docs`, `POST /check` with
`{"source": ..., "client": ...}`) answers with CORS headers, so that the page can also be served
statically, with `window.PLAYGROUND_API` set to the address of the server. Before
exposing the server publicly, note that every program creates atoms (its identifiers
and literals), which the BEAM never collects: requests must then be limited.

## Requirements

Elixir 1.20.x (developed with 1.20.4 on OTP 29). Types are built with
`ProcessTypes.Descr`, a copy in [lib/vendor/](lib/vendor/) of `Module.Types.Descr`, the
type representation of the Elixir compiler, as extended by Guillaume Duboc with type
variables, tallying and recursive types (see Acknowledgements). It is compiled with the
project, and `scripts/vendor_descr.sh` refreshes it.

## Design

- **Types.** The types of the paper are encoded as Descr types. Descr's function
  types of different arities are disjoint, and they serve as the disjoint summands of
  the paper's model:
  - the read capability `() -> i` is the nullary function `fun([], i)`;
  - the pid type `pid(t)` is the unary function `fun([t], ℧)`;
  - the decorated arrow `(s -> t)@[o, i]` is the ternary function
    `fun([s or ℧, pid(o), fun([], i)], t)`;

  where ℧ is `port()`, a type that no value of the language inhabits. This differs
  from the encoding of Section 4.3 of the paper (tagged pairs). The laws of the paper
  have been tested on it (arrow factorization, the pid laws, multi-shot reading, and
  the failure of the three mixing laws of Section 6.3), not proved.
- **Checking.** The checker follows the algorithmic rules of Fig. `fig:inference`
  (Section 8.2), and a backend decides what to do with what they emit
  (`ProcessTypes.Backend`). In ground mode every decoration is known: each constraint
  is checked at once, and each fresh variable takes its least solution (the result of
  an application by `fun_apply`, a tuple projection by `tuple_fetch`). In inference
  mode the annotations are decorated with type variables, once per occurrence and with
  the same pair for equal arrow annotations (decorate(·) of Section 8.1, computed on the
  graph of the annotation by partition refinement); the rules mint the fresh variables
  of i-app, pe-tuple, i-abs and i-spawn; a constraint without variables is still
  checked at once, and the others are solved together, at the end, by tallying.
- **Splitting (experimental, off by default).** With the option `split`, a tuple pattern
  that binds at least two variables gives one environment per summand of the matched type
  (`Types.tuple_summands/2`, the normal form of Descr), and the body of the branch is typed
  under each; a type with a variable at its top is not split (GRAMMAR.md, §10). The cost
  is at most one typing of the body per summand: the examples do not change, and a server
  with n summands that calls a function of n arrows, already costly for large n, takes up
  to n times as long as one call on the union (21 s against 3 s at n = 16).
- **Errors in inference mode.** When the deferred constraints have no solution, the
  errors are the constraints that make them unsatisfiable, in generation order: a binary
  search finds the shortest prefix without solution, its last constraint is reported
  and dropped, and the search goes on. Types in messages are instances of a solution
  of the constraints before it, with the variables left mapped by their role (output
  decorations to `none()`, input decorations to `term()`).
- **Recursive types.** A `$type` definition may be recursive if it is contractive.
  `ProcessTypes.TypeGraph` represents an annotation by the finite graph of its regular
  tree and compiles each cycle into a system of recursive equations of Descr, one
  constructor or connective per equation, since Descr evaluates connectives eagerly.
- **Front end.** Annotation lines (`$`, `$type`, `$interface`, `$self_interface`) are
  extracted and replaced by blank lines; the rest is parsed by
  `Code.string_to_quoted/2`.

## Printing types

Types in messages are read back from Descr into the syntax of annotations, with the
names that `$type` defines: a subterm that denotes the same type as a name is printed
as the name (`Server.worker` outside the module `Server`), and so is, in a union, a
group of disjuncts whose union the name denotes. Singleton types are never renamed.
A type with parameters is printed through those of its instances that the annotations of
the program reach (`request(c, r)`), which are expanded before checking.
A recursive type that is not a name is printed `rec x. t`, x standing for the whole type
in t.
One limit: Descr's printer drops negated arrows and pid types, so a type such as
`fun() and not (integer() -> integer())` is printed as `fun()`. This does not affect
checking.

## Layout

| module | role |
|---|---|
| `ProcessTypes.Types` | the encoding into Descr, the only module that calls it |
| `ProcessTypes.TypeSyntax` | annotation types: parsing and printing |
| `ProcessTypes.TypeGraph` | the meaning of annotations: recursive types, instances of parametrized types, decorate(·) |
| `ProcessTypes.Printer` | printing types with the names that `$type` defines |
| `ProcessTypes.Annotations` | extraction of the annotation lines |
| `ProcessTypes.Frontend` | from Elixir code to the core syntax of the checker |
| `ProcessTypes.Checker` | the typing rules |
| `ProcessTypes.Backend` | how the checker discharges constraints (`Ground`: at once) |
| `ProcessTypes.Backend.Infer` | inference: variables, deferred constraints, tallying |
| `ProcessTypes.Web` | the playground server; its page is `priv/playground/index.html` |
| `ProcessTypes.Web.Runner` | the limits of time and memory of the playground's checks |
| `ProcessTypes.Descr` | in `lib/vendor/`: the copied type representation (Acknowledgements) |

## Acknowledgements

The types of the prototype rest on the work of **Guillaume Duboc**. The files of
[lib/vendor/](lib/vendor/) are copied from his branch `type-variables` of
https://github.com/gldubc/elixir, which extends `Module.Types.Descr`, the type
representation of the Elixir compiler (Apache-2.0), with recursive type descriptors and
with type variables and tallying: the recursive types and the inference of Section 8
are implemented on top of it. [lib/vendor/README.md](lib/vendor/README.md) records the
commit and the changes made to the copy.
