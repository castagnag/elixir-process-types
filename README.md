# elixir-process-types

A prototype type checker for Elixir processes. It implements the type system of
Sections 3–6 of the accompanying paper on set-theoretic types for Elixir actors:
a process is typed `pid(t)`, where `t` is the type of the messages it accepts, and
an arrow carries the mailbox decorations of the process that runs it, written
`(s -> t)@[o, i]`. Programs are type-checked, never run.

Decorations are written explicitly. Their inference (Section 8 of the paper) needs
type variables and tallying, which the Elixir compiler does not provide yet.

**Status:** early work in progress. The accepted language is specified in
[GRAMMAR.md](GRAMMAR.md). [examples/](examples/) holds the examples of the paper,
which will become the test suite.

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
