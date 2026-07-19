---
name: wire-code-style
description: >
  Review, write, and format Wire source snippets and .wire examples against Cortex's canonical Wire
  style. Use when editing Wire examples, docs code blocks, parser fixtures, tree-sitter fixtures, or
  discussing a future Wire formatter.
---

# Wire Code Style

Use this skill for `.wire` source, Wire snippets in docs, tree-sitter examples, and Wire formatter
planning. This is a style skill, not a semantic review skill; use architecture or doc-review when a
syntax decision changes language meaning or canonical documentation.

Canonical source:

- `docs/Reference/Wire/style.md` - Wire style reference.
- `docs/Reference/Wire/grammar.md` - syntax source of truth.
- `editors/tree-sitter-wire/` - editor/docs highlighting grammar.
- `src/Cortex/Wire/Parser.hs` - production parser.

## Core Rules

- Do not put whitespace before semicolon terminators.
- Put one space after a semicolon only when another token follows on the same line.
- Treat semicolon as a terminator/separator, not an operator.
- Use Nix-style `inherit name;` for same-name record fields instead of `name = name;`.
- Prefer compact grouped `inherit a b c;` when related inherited fields fit cleanly on one line.
- Format nodes with at most one input and one output on one line when they fit within 100 columns
  and have no sum, `where`, metadata, or multiline expression.
- For larger nodes, put each `<-` input and `->` output declaration/equation on its own line and
  keep the arrow as the first non-whitespace token.
- Put `=>` at the start of a causal-stage continuation line.
- Keep small `<>` frontiers grouped horizontally; break large frontiers vertically with leading
  `<>`.
- Use two-space indentation inside node bodies, `where let` blocks, records, and lists.
- Prefer one field per line for non-trivial records.
- Keep compact records on one line only when they stay readable.
- Do not add a trailing semicolon to the file-return graph expression.
- Keep graph composition readable with explicit parentheses around mixed `<>` and `=>`.
- Keep executor authority visually obvious: `@qualified.executor argument`.
- Use direct CorePure expressions for pure output equations; never invent `@pure` examples.
- `#` starts a line comment outside strings only. Inside `"..."`, write literal `#` normally.

Preferred examples:

```wire
node read_mode -> answer: UserInput = @cortex.io.stdin {
  cfg = { prompt = "Planning mode (high/safe): "; };
};
```

```wire
read_target
  => plan_build
  => (compile_check <> test_check <> docs_check <> lint_check)
  => summarize_build
  => print_report
```

```wire
where let
  highMode = answer == "high";
  threshold = if highMode then 0.6 else 0.8;
in
{
  inherit threshold;
  mode = if highMode then "high-throughput" else "safe-default";
};
```

Avoid:

```wire
{ prompt = "Planning mode (high/safe): " ; }
```

## Review Checklist

When reviewing Wire source:

1. Parse it with the production parser when possible: `nix run .#wire -- build <file>`.
2. Parse/highlight it with tree-sitter when the source is an example or docs snippet:
   `tree-sitter parse <file>` and `tree-sitter highlight --scope source.wire <file>`.
3. Check semicolon spacing first; it is the most visible style drift.
4. Check compact-node eligibility; otherwise require one port arrow per line.
5. Check same-name record fields use `inherit`, grouping related fields when it stays readable.
6. Check graph topology formatting: `=>` advances stages on new lines and `<>` groups frontiers.
7. Check that comments, strings, and command arguments are not confused. In particular,
   `".#flake-output"` is a string, not a comment.
8. Keep examples generic Cortex examples unless the surrounding doc explicitly discusses a consumer.

## Formatter Direction

The formatter should be AST-driven, not a regex pass. Regex cleanup may be acceptable for a one-off
manual migration, but it must not become the canonical formatter.

Recommended path:

1. Add a formatting style reference and use it in examples manually.
2. Add `wire fmt --check` and `wire fmt` as CLI subcommands once the parser exposes enough source
   spans or a formatter AST.
3. Start with stable layout rules: semicolon spacing, same-name record `inherit`, grouped
   `inherit a b c;`, one-arrow-per-line node ports, stage-oriented `=>`, same-frontier `<>`,
   indentation, records/lists, node bodies, and topology expression wrapping.
4. Add the formatter to treefmt only after it is stable and idempotent.
5. Keep comments attached conservatively. A formatter that drops or moves comments is not
   acceptable.

Until a formatter exists, do small style edits with normal diffs and validate with:

- `nix run .#wire -- build <file>`;
- `tree-sitter parse <file>`;
- `just wire-style-check`;
- `just fmt-check` when docs or generated files are touched.
