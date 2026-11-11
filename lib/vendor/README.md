# lib/vendor: the set-theoretic types of Guillaume Duboc's branch

## Acknowledgement

The three files of this directory are the work of **Guillaume Duboc**. They are copied
from the branch `type-variables` of his fork of Elixir,
https://github.com/gldubc/elixir/tree/type-variables, at the commit recorded in
[COMMIT](COMMIT). That branch extends `Module.Types.Descr`, the type representation of
the Elixir compiler, with

- recursive type descriptors (`recursive/1`, commit 1540f05, 2026-06-26);
- type variables, substitution and tallying (`var/1`, `substitute/2`, `vars/1`,
  `tally/2`, commit 3db494d, 2026-10-03), which add the whole of `descr_tally.ex` and
  `descr_polymorphic.ex`.

The type variables and tallying of Section 8 of the paper, and the recursive types of
the prototype, rest on this work.

| file | module | origin |
|---|---|---|
| `descr.ex` | `ProcessTypes.Descr` | `lib/elixir/lib/module/types/descr.ex` |
| `descr_tally.ex` | `ProcessTypes.Descr.Tally` | `lib/elixir/lib/module/types/descr_tally.ex` |
| `descr_polymorphic.ex` | `ProcessTypes.Descr.Polymorphic` | `lib/elixir/lib/module/types/descr_polymorphic.ex` |

## License

Elixir is distributed under the Apache License 2.0; each file keeps its SPDX lines
(`Apache-2.0`, © 2021 The Elixir Team), followed by an acknowledgement of its author.

## Changes made here

The files are not edited by hand: `scripts/vendor_descr.sh [COMMIT]` fetches them,
renames the modules `Module.Types.Descr*` to `ProcessTypes.Descr*` (so that they do not
clash with the compiler's own `Module.Types.Descr`), inserts the acknowledgement, and
applies the patches of `scripts/descr_patches/`, in order:

1. `01-elixir-1.20.patch`: `String.to_unsafe_atom/1`, new in Elixir 1.21, becomes
   `String.to_atom/1`, so that the files compile with Elixir 1.20.
2. `02-print-recursive-nodes.patch`: `to_quoted/2` prints a recursive node as
   `rec(x, body)`, where `body` is one unfolding of the node in which the node itself
   is printed `x`, and `term_type?/1` accepts nodes. Without it, printing a type that
   contains a recursive node fails, also when the node is intersected with a variable.
3. `03-fun-emptiness-assumptions.patch`: the two fast paths of `phi_starter/4`, in the
   emptiness of function types, compare return types with `subtype_seen?/3` instead of
   `subtype?/2`, so that the coinductive assumptions are kept, as `phi/5` does. Without
   it, comparing two copies (two `recursive/1` systems) of a type recursive through the
   codomain of a function type, such as `w = (-> w)`, or through the input decoration of
   an arrow, which is the codomain of its read capability, does not terminate.
4. `04-exposed-diagrams.patch`: `subtype?/2`, `subtype_static?/2` and
   `polymorphic_subtype?/2` compare polymorphic diagrams in which no leaf is a recursive
   node. A node leaf may hide type variables at the top level of its unfolding, and
   `Poly.all_pairs?/3` compared it without the truth values that its path gives them.
   Without it, `subtype?` answers false on valid subtypings (for k = {k} or x,
   `subtype?(y and k, k)`), so tallying, which validates its solutions with `subtype?`,
   answers that there is no solution to satisfiable systems such as i ≤ ia, {ia} ≤ i:
   inference then reports false errors.
5. `05-emptiness-connectives.patch`: `subtype_seen?/3` and `tuple_elements_empty?/6`
   compute differences and intersections without `simplify_polymorphic/1`, which decides
   equivalence with `subtype?/2` and so loses the coinductive assumptions. Without it,
   comparing two copies of a recursive type with a variable (k = {k} or x) does not
   terminate, nor does the validation of recursive solutions of tallying.

6. `06-lazy-substitution.patch`, **provisional**, to be replaced by Guillaume Duboc's
   fix when there is one: below a constructor, structural substitution substitutes
   lazily, in a node of its own, an element where it would combine a recursive node with
   other types; copies and lazy nodes are named after the substitution, so that the same
   unfolding gives the same nodes; structural substitution does not simplify; and the
   polymorphic leaves that connectives store when they unfold a node are exposed, also
   in emptiness checks. Without it, tallying does not terminate on {x ∨ :b} ≤ x, nor on
   the validation of the recursive worker of limit 3 below.
7. `07-intern-nodes-memoize-emptiness.patch`, **provisional**, to be replaced by
   Guillaume Duboc's fix when there is one. (a) Nodes are interned in the process
   dictionary: a node is `{n, :node, :node}`, where `n` maps to its id, state and
   generator; the same id gives the same node, unfoldings are cached, and neither the
   ids of lazy nodes nor the comparison of systems contain closures. Without it, ids
   embed substitutions and states whose generators capture other states, so hashing or
   comparing a node (`phash2` in `bdd_leaf_new/2`, `===`) traverses a tree exponentially
   larger than the term in memory. (b) Emptiness results are memoized in the process
   dictionary where a key enters `seen` (nodes and the diagrams of functions, lists, maps
   and tuples), as in Algorithm 2 of "Implementing Set-Theoretic Types": a key being
   checked is assumed empty; when its check fails, the positive results recorded since
   are rolled back; when the outermost check succeeds, they are definitive. Being shared
   by every check of the process, the memo also keeps the assumptions where a check
   restarts without `seen` (the fast paths of `phi_starter/4`, `simplify_polymorphic/1`),
   which made the emptiness of limit 1 descend forever. (c) `syntactic_vars/1`, the
   variables that occur in a type, without the equivalence checks of `vars/1`. Since
   nodes live in the process dictionary, a type with recursive nodes must be used in the
   process that built it. Solves limit 1 below.

8. `08-first-solution.patch`, ours, not reported: `tally_first/2`, for inference, which
   needs satisfiability and one solution, not all the principal ones. It normalizes each
   constraint, then searches depth first, with backtracking, over the alternatives of
   the normal forms (fewest alternatives first) and over those of propagation, and stops
   at the first saturated set that `solve/1` and `valid_solution?/2` accept. A version
   that first saturated the single-alternative constraints alone, to refute without
   search, made no measurable difference and is kept in
   `experimental/08-first-solution-with-refutation.patch` (it applies instead of this
   one). In theory it answers `[]` exactly when `tally/2` does;
   in practice the two reach different saturated sets, and `solve/1` and
   `valid_solution?/2` inherit the false negatives of `subtype?/2`, so they may
   disagree (they agree on every example and test). Without it,
   the families of alternatives grow exponentially on decoration inference
   (`_claude/INFERENCE-SCALING.md` of the paper).
9. `09-solve-as-system.patch`, ours, not reported: the solve phase of tallying builds
   the solution as one system of mutually recursive nodes. A saturated set gives one
   equation per variable, α = (lower ∨ α′) ∧ upper with α′ fresh. `solve/1` solved them
   one after the other, substituting each recursive solution into the others and back,
   which gave nests of recursive systems. Now one `recursive/1` system has a node per
   variable whose equation mentions a variable of the set. In each body, one structural
   substitution replaces every variable of the set by its node (or by its solution, when
   its equation mentions none) and every α′ by α. In a normalized set the bounds of α
   have only larger variables at the top level (normalization keeps the least variable
   of each line), so the nodes are well defined. The sequential solve is kept for the
   case where top-level occurrences form a cycle (never met: 571 solves over the test
   suite, none cyclic). The fallback now renames without simplifying, and
   `solve_recursive_equation/2` uses `syntactic_vars/1` instead of `vars/1`. Without the
   patch, emptiness checks, simplification and printing of the nested solutions blew up:
   two runners of the same kind sharing an undecorated `run_job` took more than 100 s,
   and the fully undecorated dispatcher did not finish (1.6 s with the patch).
10. `10-factorize.patch`, ours, not reported: `factorize/1` merges the equivalent
    recursive nodes of a type, as `factorize` in SSTT (Laurent and Nguyen, "Implementing
    Set-Theoretic Types"). Every node reachable from the type is mapped to the first node
    equivalent to it (`equal?/2`) in depth-first order, and these representatives are
    rebuilt as one `recursive/1` system. The type is returned unchanged when no two nodes
    are equivalent, when a node is the domain of an optional map field, and when merging
    would put a node at the top level of its own definition. `map_nodes/2` replaces the
    nodes that occur in a type. `ProcessTypes.Printer` factorizes before printing: the
    main type of the undecorated dispatcher went from 47 `rec` binders (19 KB) to 2
    (1.6 KB), at no measurable cost.
11. `11-lazy-node-intersection.patch`, ours, proposed to Guillaume Duboc in a pull request
    (`_claude/descr-report/pr/`): the intersection of two different recursive nodes is a
    node of its own, named after the pair of node ids, so that `opt_intersection/2` of a
    recursive tuple type with a copy of itself terminates (limit 2 below). The
    intersection of a node with itself is the node. `non_empty_intersection!/3` does not
    check the emptiness of such a node, which would unfold the node whose generator is
    running; emptiness is decided when the node is used.
12. `12-local-identities.patch`, ours, not proposed to Guillaume Duboc: type variables and
    recursive systems are numbered by counters of the process (process dictionary, like
    the interned nodes of patch 07) instead of `:erlang.unique_integer/1` and
    `make_ref/0`, global to the VM. BDD literals are ordered by the hash of their
    content, which contains these identities, so the same check run twice in one VM (two
    clicks in the playground) gave equivalent but differently written types, and
    different times. Each check of the playground runs in a fresh process, so now it
    gives the same result as in a fresh VM. Variables, like nodes, are local to a process.
13. `13-print-complements.patch`, ours, not proposed to Guillaume Duboc; printing only.
    `to_quoted/2` prints a type whose complement has fewer kinds (atoms, tuples,
    functions, ...) as `not` that complement, so that "term() minus a few tuples", the
    form of the input decorations that inference finds, no longer lists every other kind.
    The complement of the complement has more kinds: the rule never applies twice in a
    row, and nothing is printed twice. In a closed tuple DNF line, a negated tuple
    disjoint from the positive one is dropped, and one that contains it in every
    component but one, k, is absorbed into that component:
    `{p1, ..., pn} and not {n1, ..., nn}` = `{p1, ..., pk and not nk, ..., pn}`. The
    input decoration of `loop` in `examples/server.exs` now prints
    `not ({:run, not (-> term())@[...]} or {:total, not pid({:total, integer()})} or
    {:work_add, not integer()})`. Printing all the types of that example takes 9 ms
    instead of 31 ms.
14. `14-reconstruction-support.patch`, ours, not proposed to Guillaume Duboc: three
    functions for the reconstruction of interfaces (Section 9 of the paper, GRAMMAR.md
    §11); none changes tallying, and inference does not call them.
    - `tally_normalize/3` (`Tally.normalize_constraint/3`) exposes the first step of
      tallying on one constraint: the normal form of `left <= right`, a list of
      alternatives, each a list of bounds `{lower, variable, upper}`, such that a
      substitution satisfies the constraint iff it satisfies the bounds of one
      alternative; the variables of `fixed` are never bounded. The reconstruction reads
      in it the bounds that a constraint entails (`ProcessTypes.Reconstruct.Bounds`).
    - `substitute_top/2` substitutes variables at the top level of a type only, not
      below its type constructors: a chain ζ ≤ η between two unknowns of the
      reconstruction is replaced by the bound of η, while the guarded occurrences of η
      stay for the recursive solution.
    - `solve_equations/2` (`Tally.solve_guarded/2`) solves a system of equations
      `variable = type` in which the variables of the system occur only below type
      constructors, as one `recursive/1` system with a node per variable, the way
      `solve_system/2` of patch 09 builds the solutions of tallying.

Patches 02 to 07 address limits of the branch that its own tests do not exercise; they
were reported to Guillaume Duboc, with the limits below.

Only `ProcessTypes.Types` calls these modules.

## Limits found while using the branch (2026-10-03)

Three cases that inference met; with the patches above, all are handled by the copied
Descr (the second since patch 11). In the reproducers, `D` is `ProcessTypes.Descr`, and `arrow(s, o, i, t)` is the encoding of
`ProcessTypes.Types`, `D.fun([D.union(s, D.port()), D.fun([o], D.port()), D.fun([], i)], t)`.

1. **Recursive solutions through a function type** (solved by patch 07). With patch 06,
   tallying solved
   {x ∨ :b} ≤ x and the two-constraint system of the jobs of Section 2,

   ```elixir
   [oa, ia, i, res] = Enum.map([:oa, :ia, :i, :res], &D.var/1)
   j = arrow(D.tuple([]), oa, ia, D.term())
   w = D.union(D.atom([:bump]), D.tuple([D.atom([:run]), j]))
   D.tally([{j, arrow(D.tuple([]), D.none(), i, res)}, {w, i}])
   ```

   but not the constraints of the whole program (`job = (-> term())`). Six of them
   suffice: `o_spawn ≤ w`, `w ≤ i_spawn`, `i_spawn ∧ {:run, term()} ≤ {p1, p2}`,
   `o_app ≤ o_spawn`, `i_spawn ≤ i_app`, `p2 ≤ arrow({}, o_app, i_app, res)`, with `w`
   as above. They did not finish in 120 s: the emptiness check descended forever, losing
   its assumptions in the fast paths of `phi_starter/4` and in `simplify_polymorphic/1`,
   and hashing nodes became exponential. With patch 07 they are solved in about 20 ms,
   and the whole program in about 3 s, with the expected error.

2. **Intersection of a recursive tuple type** (solved by patch 11). With `l = nil or {integer(), l}`,
   `D.intersection(l, l)` does not terminate, nor does the intersection of two copies
   (two `recursive/1` systems): `opt_tuple_leaf_intersection` →
   `zip_non_empty_intersection!` intersects the components eagerly and descends through
   the nodes, with no memo on pairs of nodes. Union, difference, `subtype?` and
   `D.bare_intersection` terminate. Since tallying intersects bounds,
   `D.tally([{l1, a}, {a, l2}])` does not terminate either. Patch 11 makes the
   intersection of two different nodes a node of its own, named after the pair.

3. **A written recursive type under inferred brackets** (solved by patch 06). For
   `worker = :bump or {:run, (-> term())@[:bump, worker]}`, tallying found the expected
   solution but validating it compared copies of recursive types that the substitution
   had named differently, and did not terminate.
