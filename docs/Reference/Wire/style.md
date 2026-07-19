---
title: Wire Style
description:
  Canonical formatting and layout conventions for Wire source files, examples, and documentation
  snippets.
sidebar:
  label: Style
  order: 2
date: 2026-05-02
status: accepted
related:
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/ADRs/0041-wire-cli-command-surface.md
  - docs/ADRs/0042-wire-standard-effect-executors.md
---

# Wire Style

This page defines the canonical style for authored Wire source. The grammar reference defines what
parses; this page defines what Cortex examples, docs snippets, fixtures, and future formatters
should produce.

## Semicolons

Semicolons are terminators or separators. They are not operator tokens.

Use no whitespace before a semicolon:

```text
prompt = "Planning mode (high/safe): ";
```

When another token follows on the same line, use one space after the semicolon:

```wire
{ prompt = "Planning mode (high/safe): "; newline = true; }
```

Prefer multiline records once a record has enough fields that the single-line form stops scanning
cleanly:

```wire
{
  prompt = "Planning mode (high/safe): ";
  newline = true;
}
```

Use Nix-style `inherit` when a record field takes its value from a same-named variable:

```wire
{ inherit summary; }
```

Group related inherited fields when the compact form still reads cleanly:

```wire
{ inherit compileSpec testSpec docsSpec lintSpec; }
```

Prefer this over:

```text
{ summary = summary; }
```

The file-return graph expression has no trailing semicolon:

```wire
read_target
  => plan_build
  => print_report
```

## Graph Expressions

Format graph expressions by causal stage. `=>` advances causal time, so it starts a new continuation
line:

```wire
read_target
  => plan_build
  => summarize_build
  => print_report
```

`<>` expands the current frontier and binds tighter than `=>`, so a frontier inside a `=>` chain
needs no parentheses. Keep small frontiers inline:

```wire
plan_build
  => compile_check <> test_check <> docs_check <> lint_check
  => summarize_build
```

Break large frontiers vertically with a leading `<>` on each continuation, indented under the first
frontier member so each line reads as another member of the same frontier:

```wire
plan_build
  => compile_check
    <> test_check
    <> docs_check
    <> lint_check
    <> audit_check
    <> package_check
  => summarize_build
```

When a large frontier is the first graph stage, keep the first two compact members on the first line
and indent the remaining members beneath them:

```wire
compile_check <> test_check
  <> docs_check
  <> lint_check
  <> audit_check
  => summarize_build
```

Reserve parentheses for the load-bearing case: grouping a `=>` sub-sequence so it acts as a single
frontier member. Because `<>` binds tighter than `=>`, these parentheses change the topology and are
not optional:

```wire
(prepare_control
  => hadamard_control)
  <> prepare_target
  => entangle
```

Prefer named frontiers once the topology stops scanning cleanly:

```wire
let build_checks =
  compile_check
    <> test_check
    <> docs_check
    <> lint_check;

read_target
  => plan_build
  => build_checks
  => summarize_build
  => print_report
```

The rule is semantic: formatting follows topology. `=>` moves forward in causal time; `<>` expands
the current frontier. Drop precedence-redundant parentheses; keep only the parentheses that change
the parse.

## Indentation

Use two spaces inside node declarations, `where let` blocks, records, and lists:

```wire
node summarize
  <- input: BuildReport
  -> summary: Text = summary;
  where let
    ok = input.ok;
    summary = if ok then "ok" else "failed";
  in
  { inherit summary; };
```

For lists of records, put each record on its own line:

```text
tasks = [
  { name = "write ADRs"; score = 0.95; hours = 1; },
  { name = "implement stdin/stdout executors"; score = 0.88; hours = 3; },
];
```

## Nodes

Put each port declaration or output equation on its own line. The arrow should be the first
non-whitespace token on that line:

```wire
node classify
  <- evidence: EvidenceSet
  -> accepted: AcceptedSet = accepted;
```

Do not place `->` or `<-` on the `node` line, and do not combine multiple ports on one line.

Keep executor authority visible at the implementation boundary:

```wire
use std.io.{@stdin};

node read_mode
  -> answer: UserInput = @stdin { cfg = { prompt = "Planning mode (high/safe): "; }; };
```

Write CorePure output expressions directly:

```wire
node classify
  <- evidence: EvidenceSet
  -> accepted: AcceptedSet = evidence.items |> filter (item: item.score >= 0.7);
```

Do not write `pure (...)` or `@pure`; CorePure output expressions are direct and are not executor
authority.

## Comments And Strings

`#` starts a line comment outside strings:

```wire
# Comment
```

Inside a quoted string, `#` is ordinary string content and does not need escaping:

```text
argv = ["nix", "run", ".#cortex-tests", "--", "-m", "Cortex.Wire.Parser"];
```

This matches the production parser. Tree-sitter highlighting should preserve the whole quoted value
as a string.

## Formatter Direction

Wire formatting is exposed through the `wire` command:

```text
wire fmt FILE
wire fmt --check FILE
wire fmt --stdout FILE
```

The formatter is topology-first for graph expressions. It parses Wire source, chooses whether the
file can safely flow through the lowered production AST, renders graph composition by causal
structure when it can, reparses the output, and rejects rewrites that would not round-trip through
the production AST.

When a declaration-bearing Wire file compiles far enough to expose a cyclic topology, `wire fmt`
refuses to format it. Fix the graph first; formatting is only defined for source that can denote an
acyclic Wire topology.

The formatter starts with stable layout rules:

- no whitespace before semicolon terminators;
- one space after same-line semicolons;
- `inherit name;` for same-name record fields instead of `name = name;`;
- compact grouped `inherit a b c;` when related inherited fields fit cleanly on one line;
- one port arrow per line, with `<-` or `->` as the first non-whitespace token;
- `=>` starts a causal-stage continuation line;
- `<>` groups same-frontier members horizontally when small and vertically with leading `<>` when
  large;
- two-space indentation for node bodies, records, lists, and `where let`;
- stable record/list layout;
- explicit wrapping for mixed graph topology expressions;
- conservative comment preservation.

It is not a regex-only pass. Regex cleanup can help with one-time migrations, but the canonical
formatter operates over parsed Wire syntax and must be idempotent before it is added to `treefmt`.

The parser desugars several surface forms during parsing: `kind` and `form` declarations expand into
nodes and lets, source include calls expand before parsing, CorePure `${...}` string interpolation
lowers to `concat`/`toString` calls, and comment trivia is dropped. Round-tripping through the AST
cannot recover any of those, so `wire fmt` preserves files that contain them unchanged rather than
silently rewriting source into the lowered shape. Those files should continue to rely on
`just wire-style-check` and manual edits for now. A future concrete-syntax formatter can attach
comments/trivia and format these forms with full surface fidelity.

Because `wire fmt` validates include-bearing files through source elaboration, missing include
targets still make formatting fail even when the authored include spelling is preserved unchanged.

## Validation

For source files, validate both the production parser and the editor grammar when changing style:

```bash
nix run .#wire -- build examples/wire/mini-build-system.wire
just wire-style-check
tree-sitter parse examples/wire/mini-build-system.wire
tree-sitter highlight --scope source.wire examples/wire/mini-build-system.wire
```
