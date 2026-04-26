---
title: "Cortex Wire v1 Grammar (DIG-498 prototype)"
description: Early-v1 prototype grammar from DIG-498. Preserved as a historical research note; the normative grammar is docs/Reference/Wire/grammar-v1.md.
date: 2026-04-15
status: superseded
superseded_by: docs/Reference/Wire/grammar-v1.md
related:
  - DIG-498
  - DIG-482
  - DIG-540
  - DIG-541
  - docs/Reference/Wire/grammar-v1.md
  - docs/Reference/terminology.md
  - docs/Architecture/05-wire-language.md
---

# Cortex Wire v1 Grammar (DIG-498 prototype)

> **Superseded.** This document describes the DIG-498 early-v1 prototype that shipped under PR #999. The normative v1 grammar is [`docs/Reference/Wire/grammar-v1.md`](../Architecture/wire-v1-spec.md) (DIG-541). This file is preserved as a research note for historical reference; production `.wire` files use the form specified in the linked normative document, migrated per that spec's Appendix B.

Wire v1 separates node interface declarations from node implementation records,
and graph topology from node port syntax.

## Node Definitions

A node definition has this shape:

```wire
nodeName :
  <- InputContract
  -> OutputContract
= {
  executor = native "executor_id";
};
```

Everything before `=` is the node interface. Everything after `=` is the
implementation record.

Input clauses declare what the node can accept from predecessors. They are
capabilities, not fixed cardinality obligations:

```wire
<- PlannerOutput
<- AnalystOutput
```

Repeated anonymous input clauses are alternatives on the default `in` port.
They mean "this node can accept either contract", not "this node requires both
contracts". Shorthand signature inputs compile as optional capability streams:

```wire
analyst :
  <- GathererOutput
  <- ConditionPassthrough
= { executor = native "analyst"; };
```

For a clearer alternatives form, use a bracketed contract set:

```wire
analyst :
  <- [GathererOutput ConditionPassthrough]
= { executor = native "analyst"; };
```

Named input clauses declare distinct input channels for stable executor roles:

```wire
section_joiner :
  <- evidence: GathererOutput
  <- audit: AnalystOutput
= { executor = native "section_joiner"; };
```

Named signature inputs are still capabilities by default. Use explicit
record-style `ports` declarations when an executor truly requires a slot before
it can run:

```wire
node section_joiner {
  role = act;
  executor = native("section_joiner");
  ports = {
    inputs = {
      evidence = { accepts = ["GathererOutput"]; required = true; };
      audit = { accepts = ["AnalystOutput"]; required = true; };
    };
    outputs = {
      out = { contract = "ReviewerOutput"; };
    };
  };
}
```

Migration note: this is intentionally more permissive than v0 environment-owned
ports. A v0 node whose compile-environment input was `required = true` may
become a v1 node whose shorthand `<- Contract` input is optional. Production
migrations therefore need Pulse/runtime smoke coverage, not just Wire compiler
coverage, unless the node uses explicit required `ports`.

Do not use named ports to hard-code graph-discovered collections such as report
sections. Prefer a repeated contract stream, with semantic identity in the
payload:

```wire
final_writer :
  <- ReportFragment
  -> FinalReport
= { executor = native "final_writer"; };
```

The architecture target is that `final_writer` can receive any number of
`ReportFragment` values from the realized graph. Runtime payloads carry
section identity such as `valuation`, `china_export_controls`, or `quant`.

Output clauses declare what the node can offer to successors:

```wire
-> AnalystOutput
-> QuantInput
```

Multiple output clauses are an output capability set. A topology edge with no
explicit endpoint port is valid when the predecessor's output contracts and the
successor's input contracts have a compatible match.

Output ports can also be named:

```wire
planner :
  -> analysis: AnalystInput
  -> quant: QuantInput
= { executor = native "planner"; };
```

If an unqualified edge has more than one compatible port pair, the compiler
rejects it as ambiguous. Use explicit endpoint refs such as
`planner.quant => quant_node.in` to disambiguate.

Port names in signature clauses use `:` as the delimiter and therefore cannot
contain `:`. Contract names remain registered identifiers.

## Node Config

Act-node records can include JSON-like `config`. This is the current v1 hook for
runtime-instantiated workers whose stable type is the same but whose local
objective differs.

```wire
china_writer :
  <- SectionBrief
  -> ReportFragment
= {
  executor = native "report.sectionWriter";
  prompt = "Write one stress dimension.";
  config = {
    sectionId = "china_export_controls";
    title = "China Export Controls";
  };
};
```

The config belongs to the node instance, not to an edge. This preserves the
homogeneous-edge rule while allowing a planner to create several workers with
different objectives:

```wire
planner => (valuation_writer, china_writer, quant_writer),
(valuation_writer, china_writer, quant_writer) => final_writer
```

## Root and Leaf

`Source` and `Sink` are not ordinary contracts in Wire v1.

Root and Leaf are inferred structural roles:

- a node with no `<-` clauses is a root candidate
- a node with no `->` clauses is a leaf candidate
- roots and leaves are still validated through graph reachability and endpoint
  compatibility

Example:

```wire
planner :
  -> PlannerOutput
= {
  executor = native "planner";
};

report :
  <- ReviewerOutput
= {
  executor = native "report";
};
```

`planner` is root-shaped because it declares no inputs. `report` is leaf-shaped
because it declares no outputs.

## Graph Expressions

Graph topology uses graph operators, not node interface arrows.

```wire
=>   connect graph fragments
<>   overlay graph fragments
,    overlay separator inside graph expressions
()   empty graph fragment / identity
```

`=>` is generalized fragment connect. It connects the exit boundary of the left
fragment to the entry boundary of the right fragment. This preserves path
behavior for chains while also supporting grouped fan-in and fan-out.

```wire
circuit thesis =
  planner => analyst => report;
```

Grouped connect:

```wire
circuit report =
  planner => (summary, risks),
  (summary, risks) => reviewer;
```

This lowers to:

```text
planner -> summary
planner -> risks
summary -> reviewer
risks -> reviewer
```

Grouped connect is bipartite, not zip. Every exit endpoint on the left is
connected to every entry endpoint on the right:

```wire
circuit matrix =
  (a, b) => (c, d);
```

This lowers to four edges:

```text
a -> c
a -> d
b -> c
b -> d
```

Use explicit graph fragments if pairwise/zip-like wiring is intended:

```wire
a => c,
b => d
```

The empty graph fragment is an overlay identity:

```wire
circuit small =
  planner => analyst <> ();
```

## Lists and Records

Records use semicolon-terminated fields:

```wire
{
  executor = llm "model";
  prompt = "Analyze this.";
}
```

Lists are space-separated in Wire v1, with comma-separated v0 lists still
accepted during transition:

```wire
tools = [searchAssets getAssetPrices];
```

## Compatibility

Existing v0 `.wire` files remain valid in this PR. The following syntax is still
accepted while dogfood workflows migrate:

```wire
node planner {
  role = act;
  executor = native("planner");
}

circuit old_style {
  connect planner analyst;
  path [planner, analyst, reviewer];
}
```

The v1 parser/compiler is additive:

- v1 node signatures compile to explicit Wire ports
- v1 graph expressions compile to the existing `CompiledCircuit` path
- v0 combinator statements continue to compile unchanged
- endpoint compatibility still uses the generic Wire port system
- Wire contracts are nominal compatibility labels at the graph layer; payload
  kinds, schemas, codecs, and linters are registered in Haskell-owned contract
  registries, not declared inline in Wire
- v1 signature input clauses compile as optional capability streams; explicit
  record-style ports remain available when an input slot must be required

## Rewrite Proposal Subset

Raw Wire rewrite proposals use a smaller grammar than full workflow files. They
may instantiate registered templates and wire the resulting local nodes:

```wire
valuation = use Analyst {
  prompt = "Stress-test valuation compression.";
  config = {
    focus = "valuation";
  };
};

valuation;
```

Rules:

- proposals are raw Wire text, not JSON and not fenced markdown
- `use` is the only way to introduce nodes in rewrite proposals
- templates own executor, tools, input ports, and output ports
- proposals may override only template-allowed behavior fields such as
  `prompt`, `config`, `timeout`, and `maxOutputTokens`
- append-style proposals may contain disconnected components before attachment
- every proposal entry must fit the anchor outputs
- every proposal exit must fit every original successor input
