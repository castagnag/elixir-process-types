# The accepted language

*Implemented by the prototype (`mix typecheck FILE`). Where Descr forces a deviation
from the paper, §8 says so.*

The prototype type-checks programs (it never runs them) against the type system of
Sections 3–6 of the paper, with every decoration explicit. A program is a fragment of
Elixir extended with *annotation lines*, and it is read in two steps:

1. every annotation line (§1) is parsed, then replaced by a blank line, so that line
   numbers are preserved;
2. what remains must be valid Elixir syntax: it is parsed by `Code.string_to_quoted/2`,
   and it must belong to the fragment of §§2–4.

The grammars use `⟨…⟩?` for an optional part, `⟨…⟩*` and `⟨…⟩⁺` for repetitions, and
`a, …, a` for a comma-separated sequence of zero or more elements. Everything else is
Elixir syntax. The files in [examples/](examples/) are written in this language.

## 1. Annotation lines

A line whose first non-blank character is `$` is an annotation line. There are four
forms:

| form | declares | attaches to |
|---|---|---|
| `$type name = T` | the type `name` (§5.3) | nothing |
| `$ L` | the type of a function | the first `def` or `defp` of the next code line; if there is none, its first `fn` |
| `$interface T` | the interface of a spawned process | the first `spawn` of the next code line |
| `$self_interface T` | the interface of the main process | nothing; at most once, at top level |

The *next code line* is the next line that is not blank, not a comment, and not an
annotation line, so several annotation lines in a row attach to the same code line.

An annotation continues on the following lines as long as its brackets are unbalanced
or the next line begins with `or` or `and`. This is how the running example writes
`worker` on two lines. A `#` starts a comment, on annotation lines too.

The types of annotations are also parsed by the Elixir parser, after two rewrites: the
suffix `@[` becomes the operator `~> [`, so that `(s -> t)@[o, i]` parses, and the whole
type is wrapped in parentheses, so that a bare `s -> t` parses.

## 2. Programs

```
program  ::= top*
top      ::= module | typedef | selfint | stmt
module   ::= defmodule Alias do member* end
member   ::= typedef | fundef
fundef   ::= $ L  clause_f⁺                      consecutive clauses, same name and arity
clause_f ::= kind name⟨(p, …, p)⟩? ⟨when g⟩? do b end
           | kind name⟨(p, …, p)⟩? ⟨when g⟩?, do: e
kind     ::= def | defp
typedef  ::= $type name = T
selfint  ::= $self_interface T
```

The top-level statements (`stmt`, §3), in order, form the body of the *main process*.
Modules are not nested. A local call `f(…)` refers to a function of the current module,
a remote call `Alias.f(…)` to a function of the module `Alias` (a `defp` only from inside
its own module). Functions and types may be used before their definition.

## 3. Expressions

```
b      ::= s ⟨NL s⟩*                       block; NL is a newline or a ;
s      ::= e | p = e                       a match binds the variables of p in the rest of the block
e      ::= x
         | n | :a | true | false | nil     n an integer literal, possibly negative; :a any atom
         | {e, …, e}                       tuple
         | self()
         | -e | e + e | e - e | e * e
         | e == e | e != e | e < e | e <= e | e > e | e >= e
         | not e | e and e | e or e
         | f(e, …, e) | Alias.f(e, …, e) | e.(e, …, e)
         | fn -> b end                     zero-arity closure, possibly unannotated (§6)
         | fn clause⁺ end                  closure with parameters, annotated (§6)
         | case e do clause⁺ end
         | receive do clause⁺ end
         | if e do b end | if e do b else b end
         | send(e, e)
         | spawn(e)                        annotated by $interface (§6)
         | (b)
clause ::= p, …, p ⟨when g⟩? -> b          exactly one pattern in case and receive
```

Precedence and associativity are those of Elixir.

## 4. Patterns and guards

```
p    ::= x | _ | n | :a | true | false | nil | {p, …, p} | p = p
g    ::= test(x) | not g | g and g | g or g
test ::= is_integer | is_atom | is_boolean | is_tuple | is_pid | is_function
```

- The variables of the patterns of a clause are pairwise distinct: there is no implicit
  equality test. `_` is not a variable.
- In a pattern, `p₁ = p₂` is the intersection pattern p₁ ∧ p₂.
- Guards are type tests on variables. Every variable tested in `g` occurs in the
  patterns of the clause, and `not` and `or` combine only tests of the same variable.
  Hence a guard assigns to each variable x it tests a test type τₓ, built by union,
  intersection and negation from `integer()`, `atom()`, `boolean()`, `tuple()`,
  `pid()` and `fun()`. The clause is read as its patterns with every tested x replaced
  by the pattern x ∧ τₓ (Section 3 of the paper). For example, `x when is_integer(x)`
  is x ∧ `integer()`.
- An integer literal in a pattern is approximated, since there are no integer
  singleton types (§8).

## 5. Types

### 5.1 Syntax

```
T ::= :a | true | false | nil                    singleton types (atoms only, §8)
    | integer() | atom() | boolean() | tuple() | term() | none()
    | pid() | pid(T) | fun()
    | {T, …, T}                                   tuple types
    | (T, …, T -> T)⟨@[T, T]⟩?                    arrow, with decorations @[o, i]
    | not T | T and T | T or T | (T)
    | name | Alias.name                           defined by $type
L ::= A ⟨and A⟩*                                  function annotations
A ::= (T, …, T -> T)⟨@[T, T]⟩? | name             a name used as an A must denote an L
```

`not` binds tighter than `and`, which binds tighter than `or`. The suffix `@[o, i]`
applies to the parenthesized arrow it follows, so the parentheses of a decorated arrow
are mandatory. When a function annotation `$ L` is a single undecorated arrow, its
parentheses may be omitted, as in `$ integer() -> integer()`. Every arrow of a
function annotation has the arity of the function.

### 5.2 Meaning

- `(s₁, …, sₙ -> t)@[o, i]` is the arrow s →ₒⁱ t of the paper, typed at the bracket
  [o, i], where s = s₁ if n = 1 and s = {s₁, …, sₙ} otherwise. For n = 0 the domain
  is `{}`: `(-> t)` is the type of a zero-arity function, as in Section 2. So a
  two-argument function and a function of pairs have the same type.
- An arrow written without `@[o, i]` is decorated `@[none(), term()]`. This is the
  least arrow s →_𝟘^𝟙 t, applicable at every bracket, which fits functions that
  neither expose nor read the mailbox of the process running them.
- `pid()` is `pid(none())`, the top process type. `fun()` is the top function type
  𝟘 →_𝟙^𝟘 𝟙; it is an atomic symbol and carries no decorations. `term()` and `none()`
  are 𝟙 and 𝟘, and `boolean()` is `true or false`.

### 5.3 Type definitions

`$type name = T` inside `defmodule M` defines `M.name`, written `name` inside `M` and
`M.name` elsewhere; at top level it defines a global `name`. Definitions may refer to
one another in any order, but not recursively, directly or through other definitions.
Recursive types will come with the move to a version of Descr that has them.

## 6. Required annotations and defaults

- Every function definition has a `$ L`.
- Every `spawn` has a `$interface T`: interfaces are not reconstructed (that is
  Section 9).
- Every `fn` with parameters has a `$ L`.
- An `fn` without parameters may have one. Without it, `fn -> b end` gets the type
  `(-> t)@[o, i]`, where t is the type of `b`, and `b` is typed at the bracket [o, i] of
  the *expected type* when this is a single zero-arity arrow, at `[none(), term()]`
  otherwise. The expected type is known
  - at the message of a `send`: the interface of the target;
  - at an argument of a call: the corresponding component of the domain of the callee;
  - at the result of a function body: the codomain of the arrow being checked;

  and it is passed on to the components of a tuple (after restriction by the types of
  the other components), to the branches of `case` and `receive`, and to the last
  statement of a block. For instance, in `send(w, {:run, fn -> send(self(), :bump) end})`
  with `w : pid(worker)`, the expected type of the closure is `job`, so its body is
  typed at `job`'s bracket `[:bump, term()]`.
- The main process has the interface declared by `$self_interface`, or `term()` if
  there is none (the defensive reading of Section 11.2).

## 7. Translation into the calculus of Section 3

| Elixir | calculus | rule |
|---|---|---|
| `$ L` followed by the clauses of `f` | f = λ^L y. `case` y `do` P₁ → b₁ … `end`, where Pⱼ is the tuple of the patterns of clause j (its pattern if the arity is 1), with its guard read as in §4 | t-abs, t-case |
| `f(e₁, …, eₙ)`, `e.(e₁, …, eₙ)` | f {e₁, …, eₙ} if n ≠ 1, f e₁ if n = 1 | t-app |
| `$interface T` with `spawn(fn -> b end)` | spawn(b, T), as in Section 5 | t-spawn (b typed at [T, T]) |
| `$interface T` with `spawn(e)` | `case` e `do` f → spawn(f {}, T) `end`, f fresh: the spawning process evaluates e, the spawned one calls it | t-case, t-spawn, t-app |
| `s; b` | `case` s `do` _ → b `end` | t-case |
| `p = e; b` | `case` e `do` p → b `end`, which must be exhaustive | t-case |
| `p = e` as last statement | `case` e `do` p ∧ y → y `end`, y fresh | t-case |
| `if e do b₁ else b₂ end` | `case` e `do` (nil ∨ false) → b₂; _ → b₁ `end`; without `else`, b₂ is `nil` | t-case |
| `e₁ and e₂`, `e₁ or e₂`, `not e` | `case` on `true` and `false` | t-case |
| `+`, `-`, `*`, unary `-` | as e + e | t-plus |
| comparisons | built-in functions of type `(term(), term() -> boolean())` | t-app |
| the top-level statements b | the process ⟨a^s₀, b, ε⟩, where s₀ is given by `$self_interface` | t-thread |

Named functions are recursive through their annotations: the calculus has no recursion
and encodes it with a fixpoint combinator (Section 3), which the annotations make
unnecessary here.

## 8. Deviations from the paper, and what is not supported

Descr, the type representation of the Elixir compiler, imposes two deviations.

- **No integer singleton types.** An integer literal has type `integer()`, and `n` is
  not a type. In a pattern, a literal n refines the matched type as `integer()` would,
  but it is neither subtracted from the types of the later clauses nor counted when
  checking that the clauses are exhaustive. Both approximations are sound.
- **No recursive types.** A `$type` definition may not mention itself, directly or
  through other definitions. Hence `send(self(), self())` and the interfaces that
  mention their own pid are out of reach, and so is the most precise type of the jobs
  of Section 2, whose input decoration is the interface of the worker that runs them.
  A supertype without recursion often suffices: see [examples/dispatcher.exs](examples/dispatcher.exs).

Not supported: floats, strings, binaries, lists, maps and structs; the pin operator `^x`
and repeated pattern variables; guards other than type tests on variables; `receive …
after`; `cond`, `with`, `for`, `try` and `unless`; captures `&f/1`; default arguments;
`alias`, `import` and nested modules; `spawn/3` and the rest of `Process` and OTP;
`dynamic()`.
