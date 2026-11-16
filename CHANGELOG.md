# Changelog

## 0.2.0 (2026-11-16)

First release of Process Types for Elixir, under the Apache License 2.0.

- Type checker for Sections 3–6 of the accompanying paper (processes typed `pid(t)`,
  arrows decorated `(s -> t)@[o, i]`), on the language of [GRAMMAR.md](GRAMMAR.md).
- Inference of decorations (Section 8), the default mode: type variables and constraints
  solved by tallying; `--ground` keeps the explicit-decoration reading.
- Reconstruction of interfaces (Section 9), `--reconstruct`: a `spawn` may omit
  `$interface`.
- Recursive and parametrized `$type` definitions.
- Experimental option `--experimental-split` (off by default): a branch is typed once per
  summand of its refined type (GRAMMAR.md, §10).
- Playground (`mix playground`): check programs in the browser, with the examples of the
  paper in a menu.
- The type representation is a copy in `lib/vendor/` of the branch `type-variables` of
  Guillaume Duboc (commit 3db494d), with the patches of `scripts/descr_patches/`.
