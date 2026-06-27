---
title: "ADR 0074 - Canonical Wire Source Formatter and wire fmt Command"
description:
  "Adopts a topology-first canonical normal form for Wire source with an idempotence guarantee and
  an explicit parenthesis policy, exposed as the `wire fmt` command with `--check` and `--stdout`."
sidebar:
  label: "0074. Wire canonical formatter"
  order: 74
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/style.md
  - docs/Reference/feature-status.md
  - docs/ADRs/0041-wire-cli-command-surface.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - "GitHub #304"
---

# ADR 0074 - Canonical Wire Source Formatter and wire fmt Command

## Status

Proposed - records the design of the implemented Wire formatter and its `wire fmt` command, and
fixes the canonical normal form and parenthesis policy that two earlier ADRs deferred.

## Context

Wire has a documented authored style ([Wire Style](../Reference/Wire/style.md)) but no canonical,
executable formatter governed by an ADR. Two decisions left explicit gaps that this ADR closes:

- ADR 0041 defines the `wire` command family and lists formatting only as a hypothetical "future
  subcommand"; it never specifies what a formatter would normalize or guarantee.
- ADR 0047 settles frontier linearity and the precedence ladder, but defers the parenthesis policy
  as an open question, calling it "formatter policy, not language semantics" and saying the right
  idiom should emerge from large real examples before the formatter's stance tightens.

Meanwhile a real formatter exists in the tree: `Cortex.Wire.Format` (the rendering core) and the
`wire fmt` command in `app/wire/Main.hs`, backed by `test/Cortex/Wire/FormatSpec.hs`. The
implemented behavior is more specific than either prior ADR records, and it is canon-shaped: it
defines a normal form for graph topology, a parenthesis policy, an idempotence contract, and a set
of source forms it refuses to rewrite. Those are durable design decisions that should be governed by
an ADR rather than living only in a Reference page and source comments.

Two constraints shape the design. First, the Wire parser is lossy: it lowers `kind`/`form`
declarations, expands source includes, lowers CorePure `${...}` interpolation to `concat`/`toString`
calls, and drops comment trivia. Round-tripping through the production AST cannot recover any of
those. Second, topology-first layout would actively mislead on a cyclic graph, where downward `=>`
flow implies an acyclic causal order that does not exist.

## Decision

Adopt a canonical Wire formatter that produces a **topology-first normal form** and expose it as
`wire fmt`. The formatter parses Wire source, and for each file chooses one of two strategies:

- **Format through the lowered production AST** when the surface is known to survive that route. It
  renders connect chains (`=>`) as vertical causal stages, overlays (`<>`) as frontiers, and `*`
  topology adapters as stages, then **reparses its own output and requires the reparse to be
  AST-equal to the input** before emitting it. A mismatch is an internal error, not a silent
  rewrite. This reparse check guarantees the formatted output round-trips to the same AST;
  idempotence then follows because the renderer is a deterministic function of the AST, and it is
  pinned separately by the corpus round-trip test.
- **Preserve the source byte-for-byte** (modulo a trailing newline) when it contains any construct
  the AST cannot round-trip: `#` line comments, `/* */` block comments, `kind`/`form` declarations,
  source includes, or CorePure `${...}` interpolation. These files keep relying on
  `just wire-style-check` and manual edits until Wire gains a concrete-syntax tree with trivia
  ownership.

The command surface is:

```bash
wire fmt FILE...
wire fmt --check FILE...
wire fmt --stdout FILE
```

Bare `wire fmt` writes the formatted result back in place and accepts multiple files. `--check` does
not write; it reports each file whose formatting differs and exits non-zero if any does. `--stdout`
prints the formatted result and is restricted to exactly one file. `--check` and `--stdout` are
mutually exclusive.

The **parenthesis policy** is: drop precedence-redundant parentheses; keep only the parentheses that
change the parse. Because `<>` binds tighter than `=>` and both compose left-associatively, the
formatter flattens only the left spine of connect and overlay chains. A right-nested overlay or
connect in the AST can only come from explicit source grouping, so it is re-parenthesized to
round-trip. The same rule governs the left-associative merge (`//`) and concat (`++`) operators: a
right operand that is not a parser atom is wrapped so the chain re-folds the same way.

## Boundary Rules

The formatter's contract is defined by what it formats, what it preserves, and what it refuses.

- **Formats** (lowered-AST path): top forms (`contract`, `use`, `import`, `let`, `node`), node port
  signatures and bodies, `where let` blocks, records and lists, CorePure output expressions, and
  graph topology (`=>`, `<>`, `*`). Same-name record fields normalize to `inherit name;`, and runs
  of them group as `inherit a b c;`. Numbers render in fixed-point with no scientific notation, with
  a redundant trailing `.0` stripped, because the parser accepts only plain decimals.
- **Preserves** byte-for-byte: any file containing comments, `kind`/`form`, source includes, or
  CorePure `${...}` interpolation, because the parser lowers or discards those and a production-AST
  round-trip cannot reconstruct them.
- **Refuses**: a file that lowers far enough to expose a cyclic topology fails with a dedicated
  cyclic-graph error rather than being formatted. Other compile errors that are not topology cycles
  (for example an unresolved import) are tolerated, so partially-buildable files can still be
  tidied.
- **Validates includes**: include-bearing files are checked through source elaboration even when the
  authored include spelling is preserved, so a missing include target still makes formatting fail.

The formatter exposes two error variants: a parse error (wrapping the parser's own message) and a
cyclic-graph refusal. It is rendering-only and pure; the `wire fmt` command is the thin effectful
interpreter that reads files, applies the mode, writes or prints, and sets the exit code.

## Alternatives considered

- **A regex or textual pass.** Rejected - it cannot reason about topology or precedence and is not
  idempotent. The canonical formatter operates over parsed Wire syntax precisely so it can guarantee
  a fixed point; regex cleanup is fine for one-off migrations only.
- **A full concrete-syntax-tree formatter that reformats every construct.** Rejected for v1 - Wire
  has no CST that owns comment and trivia ownership, so the production-AST route cannot recover
  comments, `kind`/`form`, includes, or `${...}` interpolation. Deferring those to byte-for-byte
  preservation is honest; silently rewriting them into the lowered shape would destroy authored
  surface. A future concrete-syntax formatter can subsume the preserved set.
- **Leave the parenthesis policy open (the ADR 0047 stance) and rely on `just wire-style-check` plus
  manual edits.** Rejected as the permanent answer - that left the ADR 0041 `fmt` placeholder and
  the ADR 0047 paren-policy gap both unresolved. An executable normal form is the prerequisite for
  any future `treefmt` integration, and "drop precedence-redundant parens, keep the load-bearing
  ones" is a decidable rule that does not need to wait on more examples.
- **Emit the lowered AST shape and let cyclic graphs format too.** Rejected - topology-first layout
  implies an acyclic causal order; rendering a cycle that way would misrepresent the graph, so the
  formatter refuses it.

## Consequences

### Positive

- Wire gains one canonical normal form with a machine-checkable fixed point: `wire fmt --check`
  gates formatting in CI and pre-commit without writing files.
- Closes the parenthesis-policy gap ADR 0047 deferred: redundant parentheses are dropped and
  topology-changing ones are kept by re-parenthesizing right-nested AST, with the same rule applied
  to merge and concat operands.
- Fills in the `fmt` subcommand ADR 0041 only gestured at, using the same `wire` command family.
- Safe by construction: every lowered-AST rewrite is reparsed and required to be AST-equal before it
  is emitted, so a formatting bug fails loudly instead of corrupting source.
- Never destroys authored surface it cannot safely round-trip; comment-bearing and sugar-bearing
  files are preserved verbatim.

### Negative

- The formatter is two-track. Comment-bearing and sugar-bearing files are preserved rather than
  reflowed, so they still depend on `just wire-style-check` and manual edits for layout.
- It is coupled to the production parser and compiler. Grammar or lowering changes can shift the
  normal form and must keep the idempotence and round-trip invariants intact.
- `wire fmt` is undefined on cyclic-topology files; the graph must be fixed before formatting.
- It is CLI-only today. The Reference style page states the formatter must be idempotent before it
  joins `treefmt`, and it is not yet part of the `treefmt` formatter set.

### Obligations

- Keep idempotence an invariant: the corpus round-trip test (which asserts a non-trivial corpus of
  at least 15 files and that each formats to its own fixed point) must keep passing.
- When Wire gains a concrete-syntax tree with trivia ownership, extend the formatter to reflow the
  currently-preserved forms with full surface fidelity, then reconcile with `treefmt`.
- Keep the "Formatter Direction" section of [Wire Style](../Reference/Wire/style.md) in sync with
  the implemented rules.
- Resolve the Stage-3 placement question (Packaging/CLI versus Wire-language) recorded for this ADR.

## Open questions

- **Stage-3 placement.** This ADR's primary category is **Packaging, CLI & tooling** — its decision
  surface is the `wire fmt` command. But the topology-first normal form and the parenthesis policy
  it fixes are Wire-language-shaped concerns: they close a gap ADR 0047 left in the language's
  precedence semantics. Whether the language-shaped half is reclassified toward Wire language &
  grammar, or stays with the command surface, is deferred to the Stage-3 classification of this
  sweep (GitHub #304); the Obligations bullet tracks the resolution.

## Traceability

- Feature keys: `cli.wire_fmt`
- Public surface: `Cortex.Wire` (`Cortex.Wire.Format`), the `wire` CLI `fmt` subcommand,
  [Wire Style](../Reference/Wire/style.md)
- Implementation: `src/Cortex/Wire/Format.hs`, `app/wire/Main.hs`
- Tests: `test/Cortex/Wire/FormatSpec.hs`
- Theory/proof: none
- Tracking: GitHub #304

## Related

- [Chapter 05 - Wire language](../Architecture/05-wire-language.md)
- [Wire Style](../Reference/Wire/style.md) - the authored-style rules this formatter mechanizes.
- [ADR 0041 - Wire CLI Command Surface](0041-wire-cli-command-surface.md) - defines the `wire`
  command family; this ADR realizes the `fmt` subcommand it left open.
- [ADR 0047 - Wire Frontier Linearity and Precedence](0047-wire-frontier-linearity-and-precedence.md)
  - settles the precedence ladder and defers the parenthesis policy resolved here.
- [Cortex Feature Status](../Reference/feature-status.md)
- GitHub #304
