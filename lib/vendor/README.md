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
   is printed `x`. Without it, printing a type that contains a recursive node fails.
3. `03-fun-emptiness-assumptions.patch`: the two fast paths of `phi_starter/4`, in the
   emptiness of function types, compare return types with `subtype_seen?/3` instead of
   `subtype?/2`, so that the coinductive assumptions are kept, as `phi/5` does. Without
   it, comparing two copies (two `recursive/1` systems) of a type recursive through the
   codomain of a function type, such as `w = (-> w)`, or through the input decoration of
   an arrow, which is the codomain of its read capability, does not terminate.

Patches 02 and 03 address limits of the branch that its own tests do not exercise
(printing recursive types; recursion through function codomains); they are meant to be
reported to Guillaume Duboc.

Only `ProcessTypes.Types` calls these modules.

## Limits found while using the branch (2026-10-03)

Three cases that inference meets and that the copied Descr, with the patches above, does
not handle; the corresponding tests of `test/infer_test.exs` are skipped. In the
reproducers, `D` is `ProcessTypes.Descr`, and `arrow(s, o, i, t)` is the encoding of
`ProcessTypes.Types`, `D.fun([D.union(s, D.port()), D.fun([o], D.port()), D.fun([], i)], t)`.

1. **Recursive solutions through a function type.** Tallying does not terminate on

   ```elixir
   [oa, ia, i, res] = Enum.map([:oa, :ia, :i, :res], &D.var/1)
   j = arrow(D.tuple([]), oa, ia, D.term())
   w = D.union(D.atom([:bump]), D.tuple([D.atom([:run]), j]))
   D.tally([{j, arrow(D.tuple([]), D.none(), i, res)}, {w, i}])
   ```

   whose solutions need ia ≥ i ≥ w(ia), a recursive type. `solve_recursive_equation`
   builds the solution as a node whose generator substitutes the variable by the node
   itself; substitution computes connectives with the replacement, which unfold it, so
   when the variable occurs in a Boolean combination inside a constructor (here
   `(i and not ia) or ia`, in the read capability) the unfolding never ends. Each
   constraint alone is solved at once. `scripts/descr_patches/experimental/` holds an
   attempt (lazy substitution of components) that fixes single equations such as
   x = {x or :b} or :a, but not this reproducer: the copies that
   `substitute_recursive_node` makes rerun a substitution at every unfolding.
   This is what the jobs of Section 2 need when `job` is written `(-> term())`.

2. **Intersection of two copies of a recursive tuple type.** With
   `l = nil or {integer(), l}` built twice by `recursive/1` (two systems),
   `D.subtype?(l1, l2)` answers at once, but `D.intersection(l1, l2)` does not
   terminate (`opt_tuple_leaf_intersection` / `zip_non_empty_intersection!`), and so
   neither does `D.tally([{l1, a}, {a, l2}])`.

3. **A written recursive type under inferred brackets.** For
   `worker = :bump or {:run, (-> term())@[:bump, worker]}`, a spawned process of
   interface `worker` that runs the jobs it receives generates the nine constraints
   printed by `mix typecheck --trace` on the skipped test of `test/infer_test.exs`;
   tallying stops at the i-app constraint of `j.()`, although the solution needs no
   new recursion (`i_app = i_spawn = worker`). Smaller systems with the same types are
   solved at once; the chain through the projection variables of the pattern
   `{:run, j}` is needed.
