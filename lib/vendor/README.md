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

Patches 02 to 06 address limits of the branch that its own tests do not exercise; they
were reported to Guillaume Duboc, with the limits below.

Only `ProcessTypes.Types` calls these modules.

## Limits found while using the branch (2026-10-03)

Three cases that inference met; the first two are not handled by the copied Descr, with
the patches above, and the corresponding tests of `test/infer_test.exs` are skipped. Run them, if at
all, under a memory limit: some of these loops allocate gigabytes in seconds. In the
reproducers, `D` is `ProcessTypes.Descr`, and `arrow(s, o, i, t)` is the encoding of
`ProcessTypes.Types`, `D.fun([D.union(s, D.port()), D.fun([o], D.port()), D.fun([], i)], t)`.

1. **Recursive solutions through a function type.** With patch 06, tallying solves
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
   as above. They do not finish in 120 s, although only 8 distinct nodes are unfolded:
   emptiness checks seem to produce ever new diagrams (not verified).

2. **Intersection of a recursive tuple type.** With `l = nil or {integer(), l}`,
   `D.intersection(l, l)` does not terminate, nor does the intersection of two copies
   (two `recursive/1` systems): `opt_tuple_leaf_intersection` →
   `zip_non_empty_intersection!` intersects the components eagerly and descends through
   the nodes, with no memo on pairs of nodes. Union, difference, `subtype?` and
   `D.bare_intersection` terminate. Since tallying intersects bounds,
   `D.tally([{l1, a}, {a, l2}])` does not terminate either.

3. **A written recursive type under inferred brackets** (solved by patch 06). For
   `worker = :bump or {:run, (-> term())@[:bump, worker]}`, tallying found the expected
   solution but validating it compared copies of recursive types that the substitution
   had named differently, and did not terminate.
