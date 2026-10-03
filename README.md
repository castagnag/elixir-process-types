# elixir-process-types

A prototype type checker for Elixir processes. It implements the type system of
Sections 3–6 of the accompanying paper on set-theoretic types for Elixir actors:
a process is typed `pid(t)`, where `t` is the type of the messages it accepts, and
an arrow carries the mailbox decorations of the process that runs it, written
`(s -> t)@[o, i]`. Programs are type-checked, never run.

Decorations are written explicitly. Their inference (Section 8 of the paper) needs
type variables and tallying, which the Elixir compiler does not provide yet.

**Status:** work in progress. The checker implements Sections 3–6 on the language
specified in [GRAMMAR.md](GRAMMAR.md), which also lists the deviations that Descr
imposes (no integer singleton types, no recursive types). [examples/](examples/)
holds the examples of Sections 2, 4.1 and 6.3 of the paper; the test suite checks
that each reports errors exactly on the lines marked `# error:`.

## Usage

```
mix typecheck examples/dispatcher.exs examples/dispatcher_errors.exs
mix test
```

For an accepted program, `mix typecheck` prints the annotated functions and the type
of the main process; otherwise it prints the errors, one per line, as
`file:line: error: message`.

## Requirements

Elixir 1.20.x (developed with 1.20.4 on OTP 29). Types are built with
`Module.Types.Descr`, the private and unstable type representation of the Elixir
compiler, so the version is pinned in `mix.exs`.

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
- **Checking.** The checker follows the algorithmic rules of Section 8.2.2 with every
  decoration known: each constraint a rule emits is checked at once, and each fresh
  variable takes its least solution (the result of an application by `fun_apply`, a
  tuple projection by `tuple_fetch`). Inference will replace this backend by the
  collection of the constraints followed by tallying.
- **Front end.** Annotation lines (`$`, `$type`, `$interface`, `$self_interface`) are
  extracted and replaced by blank lines; the rest is parsed by
  `Code.string_to_quoted/2`.

## Printing types

Types in messages are read back from Descr into the syntax of annotations. Two
limits: type names are not recovered, so a defined type such as `worker` is printed
expanded; and Descr's printer drops negated arrows and pid types, so a type such as
`fun() and not (integer() -> integer())` is printed as `fun()`. Neither affects
checking.

## Layout

| module | role |
|---|---|
| `ProcessTypes.Types` | the encoding into Descr, the only module that calls it |
| `ProcessTypes.TypeSyntax` | annotation types: parsing, names, meaning, printing |
| `ProcessTypes.Annotations` | extraction of the annotation lines |
| `ProcessTypes.Frontend` | from Elixir code to the core syntax of the checker |
| `ProcessTypes.Checker` | the typing rules |
| `ProcessTypes.Backend` | how the checker discharges constraints (`Ground`: at once) |
