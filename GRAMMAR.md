# The accepted language

*Implemented by the prototype (`mix typecheck FILE`). Where Descr forces a deviation
from the paper, §8 says so.*

The prototype type-checks programs (it never runs them) against the type system of
Sections 3–6 of the paper. By default it infers the decorations that annotations do not
write, as in Section 8; in ground mode it reads them as written (§9); in reconstruction
mode it also reconstructs the interfaces that `spawn`s do not declare, as in Section 9
(§11). A program is a
fragment of Elixir extended with *annotation lines*, and it is read in two steps:

1. every annotation line (§1) is parsed, then replaced by a blank line, so that line
   numbers are preserved;
2. what remains must be valid Elixir syntax: it is parsed by `Code.string_to_quoted/2`,
   and it must belong to the fragment of §§2–4.

The grammars use `⟨…⟩?` for an optional part, `⟨…⟩*` and `⟨…⟩⁺` for repetitions, and
`a, …, a` for a comma-separated sequence of zero or more elements. Everything else is
Elixir syntax. The files in [examples/](examples/) are written in this language.

## 1. Annotation lines

A line whose first non-blank character is `$` is an annotation line. Let `T` and `L` be defined as in §5.1, there are four
forms of annotations:

| form | declares | attaches to |
|---|---|---|
| `$type name = T` or `$type name(x, …, x) = T` | the type `name` (§5.3) | nothing |
| `$ L` | the type of a function | the first `def` or `defp` of the next code line; if there is none, its first `fn` |
| `$interface T` | the interface of a spawned process | the first `spawn` of the next code line |
| `$self_interface T` | the interface of the main process | nothing; at most once, at top level |

The *next code line* is the next line that is not blank, not a comment, and not an
annotation line, so several annotation lines in a row attach to the same code line.

An annotation continues on the following lines as long as its brackets are unbalanced
or the next line begins with `or` or `and`. This is how the running example writes
`worker` on two lines. A `#` starts a comment, on annotation lines too.

The types of annotations are also parsed by the Elixir parser, after two rewrites: the
operator `@` becomes the operator `~>`, so that `(s -> t)@[o, i]` and `(s -> t) @ u`
parse, and the whole type is wrapped in parentheses, so that a bare `s -> t` parses.

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
typedef  ::= $type name⟨(x, …, x)⟩? = T            at least one parameter x (§5.3)
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
         | -e | e + e | e - e | e * e | div(e, e) | rem(e, e)
         | e == e | e != e | e < e | e <= e | e > e | e >= e
         | not e | e and e | e or e
         | f(e, …, e) | Alias.f(e, …, e) | e.(e, …, e)
         | fn -> b end                     zero-arity closure, possibly unannotated (§6)
         | fn clause⁺ end                  closure with parameters, annotated (§6)
         | case e do clause⁺ end
         | receive do clause⁺ end
         | if e do b end | if e do b else b end
         | send(e, e)
         | spawn(e)                        annotated by $interface (§6, §11)
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
    | (T, …, T -> T)⟨@[T, T] | @ T⟩?              arrow, with decorations @[o, i] or @ u
    | not T | T and T | T or T | (T)
    | name | Alias.name                           defined by $type
    | name(T, …, T) | Alias.name(T, …, T)         the same, with parameters (§5.3)
L ::= A ⟨and A⟩*                                  function annotations
A ::= (T, …, T -> T)⟨@[T, T] | @ T⟩? | name       a name used as an A must denote an L,
    | name(T, …, T)                               and so must an instance
```

`not` binds tighter than `and`, which binds tighter than `or`. The suffixes `@[o, i]`
and `@ u` apply to the parenthesized arrow they follow, so the parentheses of a
decorated arrow are mandatory. The suffix `@ u` binds tighter than `and` and `or`, so a
union or an intersection u is parenthesized: `(s -> t) @ (:a or :b)`, whereas
`(s -> t) @ :a or :b` is `((s -> t) @ :a) or :b`. When a function annotation `$ L` is
a single undecorated arrow, its parentheses may be omitted, as in
`$ integer() -> integer()`. Every arrow of a function annotation has the arity of the
function.

### 5.2 Meaning

- `(s₁, …, sₙ -> t)@[o, i]` is the arrow s →ₒⁱ t of the paper, typed at the bracket
  [o, i], where s = s₁ if n = 1 and s = {s₁, …, sₙ} otherwise. For n = 0 the domain
  is `{}`: `(-> t)` is the type of a zero-arity function, as in Section 2. So a
  two-argument function and a function of pairs have the same type.
- `(s₁, …, sₙ -> t) @ u` is `(s₁, …, sₙ -> t)@[u, u]`, the arrow typed at the bracket
  [u, u]. Types are printed in this form when the two decorations are the same.
- An arrow written without decorations has the decorations of the mode (§9):
  - in inference mode, the default, they are inferred (Section 8 of the paper). Each
    occurrence of an annotation in the program (a `$ L`, a `$interface`, the
    `$self_interface`) decorates its undecorated arrows with fresh type variables,
    the same pair for equal arrows of that occurrence, as the function decorate(·) of
    Section 8.1 does; the top-level arrows of a `$ L` get a fresh pair each (rule
    i-abs);
  - in ground mode they are `@[none(), term()]`, the least arrow s →_𝟘^𝟙 t,
    applicable at every bracket, which fits functions that neither expose nor read
    the mailbox of the process running them.

  Written decorations are kept in both modes: they are those of code whose body is
  not available for inference (Section 10 of the paper).
- `pid()` is `pid(none())`, the top process type. `fun()` is the top function type
  𝟘 →_𝟙^𝟘 𝟙; it is an atomic symbol and carries no decorations. `term()` and `none()`
  are 𝟙 and 𝟘, and `boolean()` is `true or false`.

### 5.3 Type definitions

`$type name = T` inside `defmodule M` defines `M.name`, written `name` inside `M` and
`M.name` elsewhere; at top level it defines a global `name`. Definitions may refer to
one another in any order, and they may be recursive, directly or through other
definitions, provided they are *contractive* (Section 3 of the paper): every cycle of
references passes through a type constructor, that is, a tuple `{…}`, a `pid(…)` or an
arrow (its arguments, its result or its decorations), and not only through `or`, `and`
and `not`. Thus

```
$type me     = pid(me)                          # the type of send(self(), self())
$type list   = nil or {integer(), list}
$type worker = :bump or {:run, (-> term())@[:bump, worker]}
```

are definitions, while `$type t = t or integer()` and the pair `$type a = not b`,
`$type b = a` are rejected. A recursive definition denotes a regular tree, the
recursive type of the paper.

`$type name(x₁, …, xₙ) = T`, with n ≥ 1 and distinct parameters xᵢ, defines a type with
parameters, written `name(T₁, …, Tₙ)`, with exactly n arguments: an *instance*.

```
$type request(c, r)  = {c, pid(r)}
$type server(c, r)   = pid(request(c, r))
$type list(a)        = nil or {a, list(a)}
$type server_get     = server(:get_int, integer())
```

- An instance means the body of the definition with the arguments in place of the
  parameters, as if it had been written out. Parameters are not type variables, and
  nothing is quantified: every instance is expanded before type checking, and a
  parameter cannot be used without being instantiated.
- A parameter is visible in the body only, and hides a type of the same name. The other
  names of the body are resolved in the module of the definition, and those of the
  arguments where the instance is written.
- A name has one definition: `name` and `name(x)` cannot both be defined. The parameters
  of a definition have no arguments of their own (`$type f(g) = g(:a)` is an unknown type
  `g`), and `pid` cannot be redefined with parameters.
- Contractivity is a property of the instances: with `$type id(a) = a`, the definition
  `$type me = id(pid(me))` is accepted and is the `me` above, and `$type t = id(t)` is
  rejected.
- In inference mode, the arrows of an instance are decorated like written arrows: equal
  arrows get the same pair (§5.2), so with `$type box(a) = (-> a)`, the type
  `{box(:x), box(:y), box(:x)}` gets two pairs.

The definitions must be *regular*, so that the instances reached from a type are finitely
many. Consider the graph whose nodes are the parameters of all definitions, with an edge
from a parameter x to the parameter y of a definition when an instance in the body of
the definition of x gives y an argument where x occurs. The edge is *expansive* if the
argument is not x itself. A definition is rejected, on its own line, when it has the
source of an expansive edge that lies on a cycle (the condition of Viroli, and of Kennedy
and Pierce for nominal subtyping), even if it is not used. Thus

```
$type swap(a, b) = nil or {a, swap(b, a)}      # regular: two instances for swap(:x, :y)
$type grow(a)    = nil or {a, grow({a, a})}    # rejected: {a, a} strictly contains a
```

A type with parameters is not printed by its definition: in messages, a subterm is
printed as an instance when it denotes an instance that the annotations of the program
reach, and the instances written in the module at hand come first.

## 6. Required annotations and defaults

- Every function definition has a `$ L`.
- Every `spawn` has a `$interface T`, except in reconstruction mode (§11), where the
  interface of a `spawn` without annotation is reconstructed (Section 9 of the paper).
- Every `fn` with parameters has a `$ L`.
- An `fn` without parameters may have one. Without it, `fn -> b end` gets the type
  `(-> t)@[o, i]`, where t is the type of `b`. When `b` is typed several times, under
  the arrows of an enclosing function or under the summands of §10, each typing gives its
  own t and its own [o, i], as if the `fn` had a different annotation each time. This
  goes beyond the calculus of the paper, where every abstraction has one annotation; an
  `fn` with a `$ L` keeps its decorations once per occurrence (§5.2). In inference mode,
  [o, i] are fresh variables at each typing. In ground mode, `b` is
  typed at the bracket [o, i] of the *expected type* when this is a single zero-arity
  arrow, at `[none(), term()]` otherwise. The expected type is known
  - at the message of a `send`: the interface of the target;
  - at an argument of a call: the corresponding component of the domain of the callee;
  - at the result of a function body: the codomain of the arrow being checked;

  and it is passed on to the components of a tuple (after restriction by the types of
  the other components), to the branches of `case` and `receive`, and to the last
  statement of a block. For instance, in `send(w, {:run, fn -> send(self(), :bump) end})`
  with `w : pid(worker)`, the expected type of the closure is `job`, so its body is
  typed at `job`'s bracket `[job_writes, worker]`.
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

An experimental option changes how t-case and t-receive type a tuple pattern: see §10.

## 8. Deviations from the paper, and what is not supported

Descr, the type representation of the Elixir compiler, imposes one deviation.

- **No integer singleton types.** An integer literal has type `integer()`, and `n` is
  not a type. In a pattern, a literal n refines the matched type as `integer()` would,
  but it is neither subtracted from the types of the later clauses nor counted when
  checking that the clauses are exhaustive. Both approximations are sound.

Not supported: floats, strings, binaries, lists, maps and structs; the pin operator `^x`
and repeated pattern variables; guards other than type tests on variables; `receive …
after`; `cond`, `with`, `for`, `try` and `unless`; captures `&f/1`; default arguments;
`alias`, `import` and nested modules; `spawn/3` and the rest of `Process` and OTP;
`dynamic()`.

## 9. Inference and ground modes

- **Inference** (the default) follows the algorithmic rules of Fig. `fig:inference`
  (Section 8.2 of the paper). Undecorated arrows get type variables (§5.2). An
  application posits a fresh result type, constrained by rule i-app; a tuple pattern
  matched against a type with variables binds fresh projections (rule pe-tuple); an
  unannotated `fn` runs at fresh decorations (§6). The body of a `spawn` with interface
  t runs at fresh decorations [o, i] with o ≤ t ≤ i (rule i-spawn), and so does the
  main process, t being its `$self_interface`. A constraint without variables is
  checked at once. The others are solved together at the end, by tallying, and the
  program is accepted if they have a solution (the variables that only bare bounds
  constrain are first replaced by their bounds, which preserves satisfiability, and
  tallying searches for one solution, not for all of them). If they have none, the errors are
  reported at the constraints that make them unsatisfiable, taken in the order in which
  the rules generate them. Decorations may thus be omitted anywhere, but the time of
  inference depends on which ones are, and locating errors costs more than accepting,
  since it solves prefixes of the constraints (see the comments of
  `examples/server_decorated.exs` and `examples/server_errors.exs`).
- **Ground** (`mix typecheck --ground`) knows every decoration: an undecorated arrow is
  `@[none(), term()]`, an unannotated `fn` runs at the bracket of its expected type
  (§6), and the body of a `spawn` with interface t, like the main process, runs at
  [t, t]. Every constraint is checked at once.

The experimental option of §10 is available in both modes.

## 10. Experimental: splitting by summands

*An extension of the paper, off by default.* It is turned on by `--experimental-split` in
`mix typecheck`, by `"split": true` in `POST /check`, by the checkbox "experimental split"
of the playground, and by `split: true` in `ProcessTypes.check_string/2`. An example with
the line `# split: experimental` is checked with the option by the tests, and turns the
checkbox on when the playground loads it; for the language this line is a comment.

Rules t-case and t-receive type a tuple pattern by projection, which loses the correlation
between components: on `{:a, pid(:r)} or {:b, pid(:s)}`, the pattern `{c, w}` gives w the
type `pid(:r) or pid(:s)`, to which only `none()` can be sent. With the option, each branch
j, whose refined type r_j is that of the rules, is typed by

```
r_j ≃ ⋁ₖ r_{j,k}     Γ, ptenv(r_{j,k}, p_j) ⊢ e_j : t   for every k
```

for clauses of functions, `fn`, `case` and `receive`, and for `p = e; b`, which is a
`case` (§7): there the rest of the block is typed once per summand. The type of the branch
is the union of the types of its body.

- The summands are those of the normal form of r_j. A summand that is empty for every
  substitution is dropped.
- A pattern is split when it is a tuple pattern, or an intersection pattern with a tuple
  pattern among its operands, and binds at least two variables. An intersection pattern is
  split before its operands, so that `{a, b} = y` correlates y with a and b. The rule is
  applied again to the components, for nested tuple patterns. Summands that give the same
  types to the variables of the pattern give one premise.
- This is not union elimination. `{_, x}` binds one variable and gets its projection, a
  variable pattern is not split, and Descr merges the products that differ in one component
  when it builds a union: `{:a, pid(:r)} or {:a, pid(:s)}` is the single product
  `{:a, pid(:r) or pid(:s)}`, so in `{c, w}` the variable w has that union type.
- Type variables may occur under the constructors of r_j, as the undecorated arrows of an
  interface make them do in inference mode: the normal form holds under every substitution,
  and so do the premises. A variable at the top of r_j has no normal form, and the rule is
  not applied: pe-tuple keeps its fresh projections. So in inference mode a spawned body
  that reads its mailbox directly, `spawn(fn -> receive do … end end)`, is not split, since
  it runs at a fresh bracket (rule i-spawn), whereas in ground mode it runs at [t, t] and is.
  To have it split in inference mode, move the body to a `def` with a written bracket.
- An `fn` without annotation in the body gets its own type and bracket under each summand
  (§6), so a program may be accepted that no single annotation of that `fn` can type.
- A body is typed once per summand, so an error may appear on one line once per summand, and
  k successive splits of n summands type the rest of a block nᵏ times.

## 11. Reconstruction of interfaces

In **reconstruction** mode a `spawn` may have no `$interface`: its interface is
reconstructed as Section 9 of the paper prescribes (Definition `def:reconstruction`), and
so is the interface of the main process when there is no `$self_interface` (in the two
other modes it is `term()`). Annotated and unannotated `spawn`s may be mixed. A program in
which every `spawn` is annotated and the interface of the main process is declared is
checked exactly as in inference mode. Inference stays the default mode, and still rejects
a `spawn` without annotation.

The mode is chosen by `--reconstruct` in `mix typecheck`, which prints the interfaces
found after the types of the functions, by `"mode": "reconstruct"` in `POST /check`, whose
answer then lists them in `"interfaces"` (`line` is null for the main process), by the
checkbox "reconstruct interfaces" of the playground, and by `mode: :reconstruct` in
`ProcessTypes.check_string/2`, whose result has them in `interfaces`. An example with the
line `# mode: reconstruct` is checked in this mode only by the tests, and turns the
checkbox on when the playground loads it; its lines `# interface (line n): T` and
`# interface (main): T` give the interfaces that must be reconstructed, as they are
printed. For the language these lines are comments.

The four steps:

1. *Generation.* The constraints are those of inference mode (§9), with rule i-spawn-alt
   for an unannotated `spawn`: its body is typed at a fresh bracket [β, α], the `spawn`
   has type `pid(γ)` for a fresh γ, and no constraint relates α, β and γ. The main process
   without `$self_interface` is typed at a fresh bracket too, without γ.
2. *Derivation.* For each unannotated `spawn`, the `receive`s that its process runs are
   those typed at an input decoration that the constraints place above α. Each of their
   branches, of pattern p_j, gives a *demand* α ∧ q_j ≤ m_j, where q_j is what the branch
   selects and m_j is p_j with each capture variable replaced by the meet of the upper
   bounds that the constraints place on its type (those of the sends to the process itself
   excepted); the union of the accepted types of all the patterns is the *coverage*.
3. *Solving.* The type variables of the demands other than α and β are replaced by their
   extrema (meet of the upper bounds for a covariant one, join of the lower bounds for a
   contravariant one), α and β are identified, and the interface is the solution of the
   resulting equation x = F(x, x): a ground type, recursive when the process runs
   functions that it receives. The `spawn`s are solved in dependency order: one whose
   demands mention the variables of another is solved after it.
4. *Checking.* γ is replaced by the interface t found, β ≤ t ≤ α is added, as rule
   i-spawn does for a declared interface, and the constraints are solved as in inference
   mode. A message that does not conform to a reconstructed interface is reported at its
   `send`, as for a declared one.

Reconstruction fails, and the `spawn` is reported as needing a `$interface`, in two cases:
a type variable occurs in the demands with both polarities (the polarity hypothesis (PH)
of the paper, as for `{:run, from, job} -> send(from, job.())`), or the dependencies form
a cycle (two processes that each forward to the other). A program may also be rejected
at step 4 although some annotation types it (Section 9.6 of the paper): the reconstructed
interface never contains a message that no `receive` of the process handles, it is one
among several maximal interfaces when the process runs functions that it receives, and it
may be too large when a branch relates two capture variables or ships a closure.

Differences from the paper, all in the way the definitions of its Appendix D are computed.
None affects soundness, which is that of the checking step: an accepted program is one
that inference accepts with the reconstructed interfaces declared.

- *Bounds.* The decomposition of constraints (Definition `def:recon-dec`) is read in the
  normal form that tallying gives to each constraint, hence up to equivalence and not by
  cases on its form. A refinement (ζ ∧ g) ∖ g' ≤ t is the bound ζ ≤ t ∨ ¬g ∨ g' of ζ,
  whatever ζ is, whereas the paper reads refinements for the types of capture variables
  only. So the process with the branch
  `{:job, p} -> send(p, fn -> receive do {:int, n} -> n + 1 end end)`, which Section 9.6
  gives as a limit, gets an interface that the checking step accepts
  (`examples/recon_closure.exs`).
- *Capture variables.* A variable that a pattern of a `receive` binds outside every tuple
  pattern gets a type variable of its own, above the refined type of its branch, so that
  the bounds on the message are bounds of that variable (in the paper its type is the
  refined type itself, recognized by its form). Whether a branch of a `case` on such a
  variable is dead is still decided on the refined type, so the branches typed are
  those of the paper. Nothing of this happens when the program has nothing to
  reconstruct.
- *Receives run.* The `receive`s that a process runs are those whose input decoration is
  reached from α by the bounds between variables that the constraints entail, or is
  forced to `term()`, or is a written decoration above the written decorations so
  reached: a sufficient condition for the entailment of Definition `def:recon-runs`,
  which the paper decides with all the solutions of the constraints.
- *Written decorations.* A function whose arrow has a written input decoration u, run by
  the process, bounds the interface by u: F is intersected with these bounds, which the
  equation of the paper leaves to the checking step. A `receive` typed at a written
  decoration contributes its patterns to the coverage and no demand, since its
  constraints have no variable and are checked at once.
- *Polarities* are tested semantically: a type is monotone, or antitone, in a variable. A
  variable on which a type does not depend has no polarity.
- *Mailbox-pure functions* (Definition `def:recon-pure`) are sought among the functions
  defined by `def` and `defp` whose arrows are undecorated or written `@[none(), term()]`
  (a function with another written bracket is not one, nor are its callers), and the
  inverse image of Definition `def:recon-inverse` is used for those with two to eight
  arrows.
- A call of an overloaded function whose domains have no variables, on an argument
  without variables that a single arrow accepts, selects that arrow, whose decorations
  then bound the bracket of the call (Lemma `lem:recon-select`).
- The type ℧ of the encoding of arrows (README.md, Design) is removed from the bounds of
  arguments.
- The option of §10 is not available in this mode: it is ignored.

