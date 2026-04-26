---
title: "Wire Grammar v1 Specification"
description: "Normative specification of the Wire v1-final grammar: keywords, operators, port typing, executor alphabet, composition semantics."
sidebar:
  label: Grammar v1
  order: 1
date: 2026-04-25
status: accepted
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/conditionality.md
---

# The Wire Language — Specification v1

A DSL for composing typed dataflow graphs. Three declaration forms, explicit imports, one composition algebra, strict port typing, explicit executor alphabet.

This spec covers **grammar, static types, and composition semantics**. Evaluation semantics — how a wire actually runs, including gas, topological memory, mutual-exclusion pruning, and rewrite bounds — is specified in a sibling document and referenced only where the grammar hands off to it.

---

## 1. Overview

A Wire program is a `.wire` file that evaluates to a **wire**: a typed dataflow graph value. Wires compose into bigger wires. Every expression the grammar admits over the wire-value class produces a wire; every operation on records, strings, and lists produces values in their own closed algebras. The type-checker's structural question is always the same: **do the ports match on contract (and label)**.

The language has exactly three top-level declaration forms (`contract`, `node`, `let`), one cross-file form (`import`), two graph operators (`<>` overlay and `=>` connect), one postfix conditional form (`select(...)`, see §7.7), one record-merge operator (`//`), one concatenation operator (`++` for strings and lists), one sum-group constructor (`|` at output port positions), and one executor-application form (`@name { ... }`). The `->` token is reserved for output-port declarations in node signatures (§6.2); it is not a graph operator.

Nodes are constructed by applying **executors** — named constructors from a closed alphabet registered outside Wire — to config records. Executors are the only **graph-level** extension point the grammar acknowledges. User code cannot define new executors; it composes them. Config values may also reference other registry-ambient identifiers (tool names, tagged-record constructors); those are scoped to config record positions and documented in §5.5.

**Labels are semantic, not cosmetic.** Ports may be labeled (`<- label: Contract`, `-> label: Contract`); a label is part of the port's identity for `=>` matching, not an annotation for humans. A labeled port connects only to an identically-labeled partner of the same contract; an unlabeled port connects only to an unlabeled partner. There is no wildcard. Author labels when you want routing control; do not label for documentation. Full rule in §6.2, matching semantics in §7.1.

---

## 2. Lexical structure

### 2.1 Whitespace and comments

Whitespace (space, tab, newline) is insignificant except as a token separator.

```wire
# line comment — runs to end of line
/* block comment — may span multiple lines, does not nest */
```

### 2.2 Identifiers

Unqualified identifier: `[a-zA-Z_][a-zA-Z0-9_]*`.
Qualified identifier: one or more unqualified identifiers joined by `.` (e.g. `llm.analyst`, `cortex.deep_report`).

Identifier kinds are disambiguated by context and by an optional leading `@`:

- **`@qualified_ident`** — executor reference. Only valid in executor-application position.
- **`qualified_ident`** — bare reference. May resolve to a `let`-bound value, an imported value, a contract name, or a config-constructor name.

### 2.3 Keywords

Reserved, cannot be used as identifiers:

```
contract   node   let   import   from   select   true   false
```

### 2.4 Literals

**Strings.** Two forms.

- Single-line: `"..."` with backslash escapes (`\n`, `\t`, `\"`, `\\`).
- Multi-line: `''...''` — verbatim, no escapes, preserves embedded newlines.

**Lists.** `[a, b, c]`. Trailing comma permitted. Empty list: `[]`.

**Records.** `{ k1 = v1; k2 = v2; }`. Fields separated by `;`. Trailing `;` permitted. Empty record: `{}`.

**Numbers.** Decimal integers and floats: `42`, `3.14`, `-7`. Leading `-` is part of the numeric literal, not an operator — Wire has no arithmetic in v1. No hex, octal, or scientific notation.

**Booleans.** `true`, `false`.

**Unit.** `()` denotes the empty wire (see §7.4). It has no role at port positions; see §6.4 on how "no output" is expressed.

### 2.5 Operators and punctuation

```
<>    =>    ->    //    ++    |    <-    :    ;    ,    =    @    .
```

`.` is used in qualified identifiers and in path-assignment notation (§8.3). Parentheses `(` `)`, braces `{` `}`, and brackets `[` `]` are structural delimiters.

---

## 3. Values

Wire has two disjoint algebras of values:

- **Wire values**: nodes, composed graph expressions, and partial nodes (the staging value between executor application and pinning).
- **Ordinary values**: records, strings, lists, numbers, booleans. These have their own operators and cannot appear on either side of a graph operator.

### 3.1 Ordinary values

**Records.** Unordered sets of named fields. Constructed with `{ k = v; ... }`. Merged with `//`.

**Strings.** Immutable text. Concatenated with `++`.

**Lists.** Ordered collections. Concatenated with `++`. Homogeneity is enforced only where a consuming executor schema or constructor signature requires it; v1 does not specify standalone ordinary-value typing beyond that. Until a list flows into a typed slot, the grammar is permissive about element types.

**Numbers and booleans.** Scalar values. Used only as config values.

### 3.2 Wire values

**Partial node.** An executor applied to a config record: `@executor { config }`. Has no ports yet. Can be `let`-bound, merged with `//` to produce another partial node, pinned into a node via a `node` declaration, or (under constrained conditions, §5.4) used directly in graph position.

**Node.** A partial node with a port signature pinned onto it. Has a boundary. Composes via graph operators. The canonical authored unit is `node = ports + executor(config)`: ports are the graph-facing interface; everything behavioral lives in the executor config record.

**Composed wire.** The result of applying a graph operator (`<>` or `=>`) to two wire values. Has a boundary derived from its operands.

All three — partial nodes, nodes, composed wires — are values. All can be `let`-bound. Only nodes and composed wires can appear in graph expressions unconditionally; partial nodes appear in graph expressions only when their remaining degrees of freedom can be resolved by context (§5.4).

---

## 4. Contracts

A **contract** is a named, typed interface. Contracts are the atoms the type-checker reasons about at port boundaries.

### 4.1 The global contract namespace

Contracts live in a single **global ambient namespace**, populated from two sources:

1. **Executor vocabulary declarations.** Each registered executor declares the set of contract names it can produce or consume. Those names enter the global namespace automatically.
2. **`contract X;` assertions in `.wire` files.** An author may assert a contract name that isn't covered by any executor's vocabulary — typically for contract-polymorphic executors (`@pure`, `@identity`) where the contract is a graph-structural concern rather than an executor-declared one.

Contract names are global. `EvidenceBundle` means the same contract wherever it appears. Two files each asserting `contract EvidenceBundle;` refer to the same contract.

Redeclaration is **idempotent**: asserting a contract name that already exists (whether from an executor vocabulary or from another file's assertion) is legal and has no effect.

Referencing an undeclared contract name is a compile error. "Undeclared" means: not in any executor's vocabulary, and not declared in any loaded `.wire` file.

### 4.2 Contract equality

Two contracts are equal iff their names are equal. Contracts are flat — no parameters, no refinement, no subtyping in v1.

### 4.3 What contracts are not

Contracts are not types in the programming-language sense. They do not describe Wire-level values (records, strings, lists). They only appear in port declarations on nodes, and their role is to gate composition: two ports connect iff their contracts match.

The structural schema of a contract's values (what bytes flow through an `EvidenceBundle` port) lives outside Wire, in the executor registry. The grammar treats contracts as opaque names; runtime structural validation happens at evaluation time, not at compile time.

### 4.4 Cost of ambient globality

Contracts declared only in wire files (not anchored to any executor) have no backstop against typos: `contract EvidnceBundle;` silently becomes a different contract from `EvidenceBundle`. The moment such a contract routes through any executor-anchored path, the mismatch surfaces at pinning. For contracts that never touch an executor port, there is no static check beyond name equality. This is acceptable for v1 and will be revisited if it causes problems in practice.

---

## 5. Executors and partial nodes

### 5.1 Executor registration

An **executor** is a named constructor registered outside Wire. Each executor declares:

- A **config schema** — what fields its config record may contain, with their types.
- A **vocabulary** — the set of contract names it can produce or consume. A contract-polymorphic executor (`@pure`, `@identity`) declares itself open-vocabulary, accepting any contract chosen at node declaration.
- **Structural constraints** — rules the port signature must satisfy. These may be tight ("exactly one input of `EvidenceBundle`, exactly one output of `AnalysisFragment | ExecutorError`") or loose ("at least one input; output is any single contract from the vocabulary").
- A **purity class** — pure or impure. This does not affect static type-checking; it is carried through to the evaluation-model spec.

The alphabet is global. All executors are referenced by qualified name with a leading `@`. There is no mechanism in Wire for defining new executors; they are added by extending the registry externally.

The boundary between what the executor pins and what the author pins is a degree-of-freedom question. A fully-pinned executor (`@llm.review` with a fixed input/output signature) leaves no choices to the author. A fully-polymorphic executor (`@pure`) leaves every choice open. Most real executors sit in between.

#### Illustrative alphabet

The prelude registry typically includes families like:

- **`@llm.*`** — agent executors backed by an LLM: `@llm.planner`, `@llm.gatherer`, `@llm.analyst`, `@llm.review`, `@llm.rewriter`. Provider is picked via config (`provider = "openrouter"`), not the executor name.
- **`@artifact.*`** — side-effecting persistence: `@artifact.log`, `@artifact.report`. Typically sinks (no output).
- **`@cortex.*`** — runtime wrappers: `@cortex.deep_report`, `@cortex.portfolio_analysis`. Consume a wire's output, produce a report reference.
- **`@pure`, `@identity`, `@const`** — contract-polymorphic utilities.

These names are conventions of the registry, not grammar. Wire itself only requires that executors be qualified identifiers.

### 5.2 Executor application

```wire
@executor { config }
```

Produces a **partial node**: the executor paired with its config record, not yet pinned to a port signature. Partial nodes are values and may be bound, passed, and merged.

Executor config is the only behavioral payload on the node surface. Prompt,
tools, memory, model choice, timeout, step budget, and executor-specific fields
are all ordinary config fields. Wire does not define a second metadata channel
for those concerns.

Schema-checking timing for partial nodes is **implementation-defined for v1**. The reference implementation checks the partial's config at pinning time — i.e., in the `node ... = <partial>` declaration — because partial-node reuse (§5.3) routinely omits fields that are filled in later by `//`. Implementations are free to perform eager type-checks on provided fields at `@` application, but must not reject a partial node for missing fields until pinning.

### 5.3 Config merge on partial nodes

```wire
let analyst_base = @llm.analyst {
  maxOutputTokens = 16384;
  memory = topological { preset = "analyst"; };
};

let analyst_mechanism_partial = analyst_base // {
  prompt = ''Attack the mechanism leg…'';
};
```

`partial_node // record` produces a new partial node with the config record merged right-biased (§8). The executor is unchanged. This is how node reuse via "base + delta" is expressed. `//` applies to partial nodes and to records; it does not apply to pinned nodes or composed wires.

### 5.4 Partial nodes in graph position

A partial node may appear directly as an operand of a graph operator iff its executor is **port-determined** — its registered structural constraints uniquely determine its port signature from its config record alone, without reference to composition context. Port-polymorphic executors must be pinned via an explicit `node` declaration before appearing in graph position.

This rule keeps partial-node well-formedness **local**. Whether `@executor { config }` is admissible at a given graph-position is a property of the partial and the executor registry — the type-checker does not walk the enclosing expression tree, and no distant edit can silently change whether an upstream partial is well-typed. Implementers can decide admissibility by inspecting only the partial and the registry.

`@cortex.deep_report { ... }` works in graph position because its structural constraints fix its port signature from its config (for instance, by declaring the expected upstream contract as a config field or by having a single registered signature regardless of config). A chained polymorphic partial like `a => @poly {} => c` is rejected at `@poly` because `@poly` is port-polymorphic and has no local pin; the author must declare the node explicitly:

```wire
node poly_pinned : <- ContractA -> ContractC = @poly {};

a => poly_pinned => c
```

The same rule applies to `<>` position: partial nodes in `<>` position must be port-determined (locally self-pinning), because `<>` has no contract-matching mechanism that could drive inference even if the spec allowed whole-expression solving.

Authors wanting local reasoning and predictable errors should prefer explicit `node` declarations for any executor whose signature is not trivially fixed. The graph-position form is sugar for the common case where a runtime wrapper like `@cortex.deep_report` is pinned entirely by its config; it is not a general inference mechanism.

Rewrite producers use the same surface as authored workflows: explicit `node`
declarations plus a final graph expression. There is no separate template-use
syntax in v1.

### 5.5 Ambient identifiers in config values

The flagship example (§12) and production wires routinely use two kinds of bare identifiers inside config records that the grammar admits but that deserve explicit explanation.

**Tool references.** Identifiers like `getDate`, `searchAssets`, `webSearch`, `getAssetFundamentals` appear as values inside `tools = [...]` lists:

```wire
tools = [getDate, searchAssets, getAssetFundamentals, webSearch];
```

These are values drawn from the executor registry's **tool registry** — a sibling namespace to the executor alphabet. Like executors and contracts, tools are globally registered and referenced by bare qualified identifier. An executor's config schema determines which tools its `tools` field (or equivalent) accepts; the author writes the identifier and the runtime resolves it against the registry. Tool references are ambient by the same mechanism as contracts and executors.

**Config constructors.** An identifier immediately followed by a record — `topological { preset = "analyst"; }` — is a **tagged-record** value form. Its grammar is `qualified_ident record_expr` without a leading `@` (see §14.4, `constructor_expr`). It is admitted at value-expression positions inside config records. The grammar treats it opaquely; its semantics are determined by the consuming executor's config schema. When `@llm.analyst`'s schema declares that its `memory` field accepts a value of shape `topological { preset: String; ... }`, the constructor is understood. Config constructors are how executors extend their config vocabulary without baking new keywords into Wire.

In both cases the grammar is neutral — it admits qualified identifiers and tagged records freely. The executor registry is the source of truth for which ones are meaningful in which positions. Misspellings of tool names and malformed config constructors surface at pinning time (when the executor's schema is consulted against the provided config) and, for anything the schema cannot reject statically, at runtime. The grammar does not attempt to enforce tool-registry membership or config-constructor validity at the lexical level.

---

## 6. Nodes

### 6.1 Declaration

```wire
node name : <port_signature> = <partial_node_expression>;
```

Where `<port_signature>` is a sequence of port declarations and `<partial_node_expression>` is any expression evaluating to a partial node.

Full form:

```wire
node analyst_mechanism :
  <- EvidenceBundle
  -> AnalysisFragment | ExecutorError
= analyst_base // { prompt = ''Attack the mechanism leg…''; };
```

### 6.2 Port declarations

A port declaration is one of:

```wire
<- Contract                         # singular input, unlabeled
<- label: Contract                  # singular input, labeled
<- [Contract]                       # list-typed input, unlabeled
<- label: [Contract]                # list-typed input, labeled

-> Contract                         # singular output, unlabeled
-> label: Contract                  # singular output, labeled
-> Contract1 | Contract2            # sum-grouped output (see §6.5)
-> label: Contract1 | label2: Contract2
```

`label:` is an unqualified identifier. Labels participate in port identity and in `=>` matching. Every port has a **port key** `(direction, contract, label)`, where `label` may be absent; an absent label is a distinct key, not a wildcard.

Two ports on the same node must have distinct port keys. Labels are therefore **required** whenever two ports on the same node would otherwise share `(direction, contract)`; omitting the label in that case is a compile error. Labels are **not** required for distinctness between different contracts or between inputs and outputs, but authoring a label is never wrong — it just makes the port addressable by that label during `=>` matching (§7.1).

**Authoring a label is a semantic commitment.** A labeled port `<- success: T` connects only to outputs also labeled `success:` of contract `T`. It does **not** connect to an unlabeled output of the same contract. Authors who want the unconstrained default should not label.

### 6.3 Singular vs list-valued ports

An **output port** is always singular — it produces at most one value per evaluation. Fan-out (one producer, many consumers) is an edge-level property: one output port may connect to many downstream inputs.

A **singular input port** `<- Contract` accepts at most one incoming edge. **Two or more incoming edges to a singular input is a composition-time type error.** Zero incoming edges is permitted on any well-typed wire value — the port simply remains on the composed wire's input boundary. Full connectivity is checked at **evaluation-time preparation**, not at compile time; see §11 rule 6.

A **list-valued input port** `<- [Contract]` accepts zero or more incoming edges. At evaluation time, all fired values are collected into a list (order is runtime-defined, outside this spec).

This asymmetry is deliberate. Fan-out produces *semantically distinct* values; each deserves its own output port. Fan-in *aggregates* values treated uniformly; they deserve one input port that collects them.

### 6.4 No output ports

A node may have zero output ports — it is then a pure sink, consuming inputs and producing no outward flow. There is no explicit "unit output" syntax; the absence of any `->` declaration in the port signature is how "no output" is expressed:

```wire
node error_sink : <- [ExecutorError] = @artifact.log {};
```

There is no `-> ()` form. `()` denotes the empty wire (§7.4); it is not a contract and cannot appear at port positions.

A node with no input ports is a source; a node with no output ports is a sink. A node with neither (zero total ports) is deferred to v2 (§13).

### 6.5 Sum-grouped output ports

A single output position may declare multiple variants joined by `|`:

```wire
-> AnalysisFragment | ExecutorError
```

This is a **sum group** — a grammar-level construct distinct from independent multi-output declarations. The grammar and runtime both carry the grouping as metadata. Specifically:

1. A sum group contains **at least two** variants. A one-variant "sum" is a syntax error; write the variant as an ordinary port.
2. Each variant has its own `(direction, contract, optional label)` identity. Two variants with the same contract require disambiguating labels.
3. **Mutual exclusion is a grammar-level property.** At each evaluation, exactly one variant fires; the others do not produce a value. The runtime enforces this using the metadata.
4. `=>` matches variants **individually**. An edge forms for each variant whose contract matches an input on the other side of the connect. The sum-grouping metadata survives on the outgoing edges so the runtime knows which edges are part of the same mutual-exclusion set.

**Sum groups are output-position only in v1.** Input ports may not use `|`.

Sum groups are a general feature for any mutually-exclusive output, not a special error-handling construct. The failure-variant pattern (`-> T | ExecutorError`) is the common case, but authors may use sum groups anywhere a node genuinely produces one of several alternatives per evaluation.

#### Label asymmetry

Labels inside sum groups attach per-variant. A leading label before the first variant labels only the first variant, not the whole group:

```wire
-> label_a: A | B              # labels only the first variant
-> A | label_b: B              # labels only the second variant
-> label_a: A | label_b: B     # labels both variants
```

The outer port declaration is one unit; labels bind to their immediate variant.

### 6.6 Node alias semantics

A `node` declaration binds a name to a specific node value. Subsequent references to that name in graph expressions all refer to **the same node**, not fresh copies. In the wire:

```wire
planner => gatherer => merge => review => rewriter <> merge => rewriter
```

the second `merge` and second `rewriter` are the **same nodes** as the first occurrences. `<>` (overlay) is union on nodes and edges; shared nodes retain their identity.

This matches `let` alias semantics (§9.3). There is no node-cloning construct in v1.

### 6.7 Node well-formedness

A `node` declaration is well-formed iff all of the following hold:

1. The named executor is registered.
2. The config record's **provided** fields have the correct types per the executor's schema (the "full config satisfies schema" check may be deferred to pinning per §5.2).
3. Every contract referenced in the port signature is in the executor's vocabulary (or the executor is contract-polymorphic).
4. The port arrangement satisfies the executor's structural constraints.
5. All port labels required for disambiguation (§6.2, §6.5) are present.
6. The node has **at least one port**. Zero-port nodes are deferred to v2 (§13).

These are compile-time checks. Whether the executor's *output values* actually conform to their declared contracts at evaluation time is a runtime structural check — not part of the static type system.

---

## 7. Wires and composition

A **wire** is any value of wire kind: a node, a composed graph expression, or (in graph position, with resolvable degrees of freedom) a partial node.

A wire has a **port-boundary**: the set of its unconnected input ports (sources) and unconnected output ports (sinks, including unconnected sum-group variants). Composition acts on boundaries only; internal structure is sealed.

### 7.1 The graph operators

**`<>` — overlay (primitive).** `a <> b` is the graph containing every node and edge in `a` plus every node and edge in `b`. Shared nodes retain their identity (no duplication). No new edges are created.

**`=>` — connect (strict port-matched).** `lhs => rhs` is defined as:

1. Let `S` = unconnected output ports and output variants in the port-boundary of `lhs`. Let `R` = unconnected input ports of `rhs`.
2. For each `p ∈ S` and each `q ∈ R`: add an edge `p → q` iff their port keys match. The port key is `(contract, label)`, with absent-label treated as a distinct key, not a wildcard. For list inputs, the match requires `contract(q) == [contract(p)]` and `label(q) == label(p)` (or both absent).
3. The result is `lhs <> rhs` with the added edges.

`=>` is **deterministic**: it adds an edge for every matching pair. It does not choose between candidates. If the resulting graph violates an arity constraint (e.g. two edges into a singular input), that is a composition-time type error surfaced by the arity rules in §6.3 — not by `=>` itself.

Unmatched ports on either side remain on the composed wire's boundary. Labels are the mechanism authors use to control matching explicitly; see §6.2.

**No path operator.** An earlier draft included `->` as a singleton-chain specialization of `=>`. It is not part of v1: it added no expressiveness over `=>`, and the `->` glyph collides with the output-port declaration form (§6.2), creating visual ambiguity in mixed contexts. `=>` covers every connect case. See §13.

### 7.2 Precedence and associativity

```
infixl 5  //     (records and partial-node config merge)
infixl 5  ++     (strings and lists)
postfix 4 select(...)
infixl 3  =>
infixl 2  <>
```

`//` and `++` live at the same precedence level. The grammar chains them freely, but because they operate on disjoint value kinds, any mixed expression fails type-checking — no well-typed program contains both in one expression. `select(...)` is a postfix suffix on its left-hand graph (see §7.7); it binds tighter than `=>` and `<>` and looser than `//` / `++`. Parentheses are always allowed and always override.

Worked examples:

- `a => b <> c => d` parses as `(a => b) <> (c => d)`.
- `a => b => c` parses as `(a => b) => c`.
- `base // { k = v; } // { j = w; }` parses as `(base // {k=v;}) // {j=w;}`.
- `x select(A: a, B: b) => c` parses as `(x select(A: a, B: b)) => c`.
- `x => y select(A: a, B: b)` parses as `x => (y select(A: a, B: b))`.

### 7.3 Boundary computation

Boundary is a derived property of the resulting graph, not a set-arithmetic operation on operand boundaries.

Given a wire `w` with node set `nodes(w)` and edge set `edges(w)`: a port `p` on some node `n ∈ nodes(w)` is **internal** iff `edges(w)` contains at least one edge incident to `p`; otherwise `p` is on the **boundary** of `w`.

For composed wires:

- `nodes(a <> b) = nodes(a) ∪ nodes(b)`; `edges(a <> b) = edges(a) ∪ edges(b)`. Shared nodes contribute once (set union). Boundary of `a <> b` is read off the resulting graph by the rule above.
- `nodes(a => b) = nodes(a <> b)`; `edges(a => b) = edges(a <> b) ∪ E`, where `E` is the set of edges added by §7.1's connect rule. Boundary of `a => b` is read off the resulting graph.

Implementers should compute the graph first and derive boundary from incidence, not attempt to maintain boundary as a separately-tracked set through the operators.

### 7.4 The empty wire `()`

`()` is the identity wire: zero nodes, zero edges, empty boundary. Identity for both `<>` and `=>`:

```
a <> () = a
() <> a = a
a => () = a
() => a = a
```

### 7.5 Tuples of wires

```wire
(a, b, c)
```

In graph position, `(a, b, c)` is the overlay `a <> b <> c` — three independent sub-wires composed as parallel lanes. Each element is itself a graph expression:

```wire
(   gatherer_mechanism     => analyst_mechanism
 ,  gatherer_timing        => analyst_timing
 ,  gatherer_beneficiaries => analyst_beneficiaries )
```

Tuple elements are flattened under composition: `((a, b), c)` is equivalent to `(a, b, c)`. A single-element parenthesized expression `(a)` is just `a`. The single-element tuple spelling `(a,)` is not admitted in v1. The empty tuple `()` is the empty wire (§7.4). Trailing commas are permitted on two-or-more-element tuples.

### 7.6 What is and isn't a match

`=>` is a mechanical cross-product-with-filter over boundary port-pairs. Matching is on **port key** — `(contract, label)` with absent-label a distinct key. The operator adds every edge whose endpoints share a key and never chooses among candidates. The consequences worth naming:

- **Two unlabeled outputs of contract `C` on `lhs` + one unlabeled singular input of `C` on `rhs`**: two edges into a singular input — arity error (§6.3). The author must label one of the outputs and label the intended consumer accordingly, or restructure the consumer to take `[C]`.
- **One unlabeled output of `C` on `lhs` + two unlabeled singular inputs of `C` on `rhs`**: two edges from one output, both valid singleton inputs (one producer can fan out). Not an error; if unintended, label one consumer and remove the label from the output's intended target to route explicitly.
- **Labeled output `success: C` + unlabeled input `<- C`**: no edge. Keys `(C, Some "success")` and `(C, None)` don't match. Add a matching label on the consumer side, or remove the label from the producer.
- **No matching pairs**: no edges added. Both sides' ports remain on the composed boundary. This is a legitimate `<>`-equivalent outcome when the author is overlaying rather than connecting.

Labels are the routing-control mechanism. Unlabeled ports participate only in unlabeled matches; labeled ports participate only in identically-labeled matches. There is no wildcard.

### 7.7 `select(...)` — postfix conditional reduction

`select(...)` is the postfix conditional form. It reduces an exclusive output boundary on its left-hand graph by attaching a continuation graph to each variant and committing to one at runtime.

```wire
selector select(
  Variant1: branch1,
  Variant2: branch2
)
```

**Surface and parse rules.**

- The form is postfix: the left-hand graph is the **selector**, and `select(...)` is its suffix.
- Each arm is `Key : expr`, where `Key` is an identifier and `expr` is any wire expression (including `()`, parenthesized continuation graphs, and other `select(...)` forms).
- Arms are comma-separated; a trailing comma is permitted; at least one arm is required.
- `select(...)` chains as a postfix: `x select(...) select(...)` is left-folded — equivalent to `(x select(...)) select(...)` — and is admissible whenever the inner `select(...)` itself yields an exclusive output boundary on its result.

**Static rules.**

- The selector must expose an exclusive output boundary (a sum group, §6.5). A non-sum-grouped boundary is a type error.
- Arm keys resolve against **variant identity** on that boundary. The default key is the variant's contract name; an explicit label (when contract names alone do not disambiguate) uses the labeled-variant key. Reordering arms does not change meaning.
- Every selector variant must be covered by exactly one arm; duplicate keys are a static error.
- Every arm is a continuation graph in the same expression namespace as `<>` / `=>`. The empty wire `()` (§7.4) is admissible as an arm body and contributes no extra branch-local topology.
- Every arm must yield the same downstream output boundary; the result of `selector select(...)` exposes that common boundary. Branches that absorb or terminate the path are deferred (§13).
- The reduced graph composes with `<>` and `=>` like any other wire (subject to the precedence rule above).

**Evaluation rules.** Only one arm is materialized — the runtime selects exactly one continuation based on which selector variant fires. Latency, branch ownership, and lowering details are out of scope for the grammar; see [conditionality.md](conditionality.md) for the full semantic model and the current implementation subset.

---

## 8. Records and merge

### 8.1 Record literals

```wire
{ title = "Report"; maxTokens = 16384; tools = [webSearch, getDate]; }
```

Fields separated by `;`. Trailing `;` permitted. Field names are unqualified identifiers; values are arbitrary expressions.

### 8.2 `//` — right-biased shallow merge

```wire
defaults // overrides
```

The result has every field in `defaults` plus every field in `overrides`; on key collision, the right operand wins. Merge is **shallow** — nested records are replaced wholesale, not merged recursively.

Laws:
- `r // {} = r`
- `{} // r = r`
- `(r // s) // t = r // (s // t)` (associative)
- Not commutative.

`//` applies to records and to partial nodes (where it merges the config record, leaving the executor untouched). It does not apply to other value kinds.

### 8.3 Path assignment

Inside a record literal, a dotted key desugars to nested record construction merged via `//`:

```wire
render.aggregateOpenGaps = true;
render.allowExtraSectionHeadings = true;
```

Desugars to:

```wire
render = {} // { aggregateOpenGaps = true; } // { allowExtraSectionHeadings = true; };
```

Which simplifies to:

```wire
render = { aggregateOpenGaps = true; allowExtraSectionHeadings = true; };
```

Repeated paths follow `//`'s right-wins rule: the last assignment to a given path prevails.

---

## 9. Top-level forms

A `.wire` file is a sequence of top-level forms. A file may optionally end in a **file-return expression** with no trailing `;`. The file's value is the file-return expression, if present.

### 9.1 `contract`

```wire
contract Name;
```

Asserts a contract name in the global namespace (§4.1). Idempotent. No effect beyond admitting the name to scope.

A file needs `contract X;` only when `X` is not already declared by any loaded executor's vocabulary. For contracts that appear in executor vocabularies — the common case — no explicit declaration is needed in user wire files.

### 9.2 `node`

```wire
node name : <port_signature> = <partial_expression>;
```

Declares a node. See §6.

### 9.3 `let`

```wire
let name = <expression>;
```

Binds a name to a value. The expression may be any Wire expression: a record, a string, a list, a partial node, a node, or a graph expression.

**Alias semantics**: `let` never duplicates. If the expression evaluates to a wire, `let name = ...;` and subsequent references to `name` refer to the same wire.

### 9.4 `import`

```wire
import name from "path/to/file.wire";
import { a, b, c } from "path/to/file.wire";
```

First form: imports the imported file's **file-return expression** as `name`. Fails if the file is declaration-only (§9.6).
Second form: imports named `let`-bindings from the file.

**Only names bound via `let` enter another file's local value scope on import.** Imports are ordinary value transport: whatever value a `let` name points to — a record, a string, a list, a partial node, a node, a composed wire — is moved across the file boundary with identity intact.

`node` declarations bind names in the declaration namespace, which is local to the declaring file. They are not directly importable, not because node identity is somehow file-local, but because the declaration namespace is not the value namespace. To expose a node across files, bind a `let` alias to it:

```wire
node gatherer_mechanism : <- PlannerOutput -> EvidenceBundle | ExecutorError =
  @llm.gatherer { prompt = "..."; };

let gatherer = gatherer_mechanism;
```

Now `import { gatherer } from "./gatherers.wire";` brings the node value into the importing file's scope. **Node identity is preserved across imports.** A node value referenced in both the declaring file and the importing file composes as the same node in the resulting program — no duplication, no fresh instantiation. This is ordinary value semantics; `let` is the namespace bridge.

`contract` declarations are ambient (§4.1). They are not importable because they do not inhabit any file's local value scope; they contribute to the global contract namespace the moment their declaring file is loaded. Authors are encouraged — though not required — to redeclare `contract X;` at the top of any file that references `X`, purely as documentation so a file's contract dependencies are readable from its header. Redeclaration is idempotent (§4.1).

**Ambient-by-loading, acknowledged.** Loading a file at all — whether by `import name from "..."` for its file-return value or by `import { x } from "..."` for a specific `let` binding — transitively loads the file's `contract` assertions into the program-wide namespace. Authors relying only on a single `let` export still inherit the file's contract declarations; this is a deliberate property of ambient contracts, not a hidden coupling. If tighter control is ever wanted, it is a v2 concern.

### 9.5 File-return expression

A file may end in a single expression with no trailing `;`. That expression is the file's value:

```wire
contract T;
let x = ...;
node a : ... = ...;
node b : ... = ...;

a => b
```

`a => b` is the file-return expression. Importing this file (first form of §9.4) yields the wire `a => b`.

### 9.6 Wire files and declaration-only files

A file with a file-return expression is a **wire file** — importable as a wire via §9.4's first form.

A file without a file-return expression is a **declaration-only file**. It contributes exactly two things to the loading program:

1. **Ambient contract assertions.** `contract X;` declarations in the file register `X` in the global contract namespace. This is the idempotent ambient mechanism of §4.1.
2. **Importable `let` bindings.** Names bound with `let name = ...;` are available to other files via `import { name } from "..."`.

Declaration-only files do **not** leak `node` names, nor any other non-`let` construct, into loading files' local scopes. A file that declares a `node foo : ... = ...;` makes `foo` part of that file's internal wire structure only; other files cannot reference `foo` unless the declaring file also binds `let foo_alias = foo;` and the importer explicitly imports `foo_alias`.

The common use cases are:

- **Prelude files** that register shared contracts not anchored to any executor vocabulary.
- **Library files** that publish reusable `let`-bound values (shared prompt blocks, tool-list constants, partial-node bases) via explicit imports.

Neither case requires or justifies implicit node/value leakage.

### 9.7 Closed composition, open vocabulary

A **program** is a root `.wire` file plus the transitive closure of its `import`s. Ambient contract collection runs over the whole program before any node well-formedness check; referencing a contract name that no file in the program declares (and no loaded executor vocabulary provides) is a compile error, not a lazy-lookup miss.

Every contract, node, and value referenced in a file must be discoverable through: executor vocabulary, `contract` declarations anywhere in the program, local `let` bindings, local `node` declarations, or explicit `import`s. There are no implicit globals beyond the executor alphabet, the contract namespace, and the registry-ambient identifier namespaces noted in §5.5.

The executor alphabet is ambient by design — executors are referenced with `@qualified.name` and resolve against the global registry. The contract namespace is ambient by §4.1. Everything else requires local declaration or explicit import.

---

## 10. Execution model (reference only)

This spec does not define evaluation semantics. The following concepts are introduced by the grammar and handed off to the evaluation-model spec for precise definition:

- **Value production per port.** An output port produces at most one value per evaluation.
- **Mutual exclusion on sum groups.** A sum-grouped port obeys the grammar-level property that exactly one variant fires per evaluation; the others produce no value. The runtime enforces this using metadata carried by the sum-group construct (§6.5).
- **Conditional downstream evaluation.** A port that produces no value this evaluation does not activate its downstream consumers. Transitively, any subgraph reachable only through a non-firing edge is not evaluated.
- **List-valued input aggregation.** A `<- [C]` port receives, at evaluation time, the list of all fired values from its incoming edges.
- **Executor purity.** Pure executors produce deterministic outputs given their inputs; the runtime may cache or reorder their evaluation. Impure executors may fail and may exhibit nondeterminism; the runtime does not cache them. The grammar does not force impure executors to use sum groups for failure — that is an authoring choice — but the convention in the prelude registry is that impure executors declare sum-grouped outputs with an error variant (typically `ExecutorError`).

The evaluation-model spec also covers: topological memory, gas accounting, rewrite bounds, determinism guarantees, and the relationship between the static graph and the live frontier.

---

## 11. Type-checking summary

A `.wire` file type-checks iff all of the following hold:

1. Every referenced contract is declared (in some executor vocabulary or in some loaded `contract` assertion).
2. Every `@executor { config }` application references a registered executor.
3. Every `node` declaration is well-formed per §6.7.
4. Every port label-requirement is satisfied (no two ports on the same node share a port key).
5. Every graph composition produces a well-formed graph under the arity rules: singular inputs receive at most one edge; list inputs receive zero or more.
6. The file-return expression (if present) evaluates to a wire value — not a record, string, list, or partial node without resolvable ports.
7. `//` and `++` are applied only to their permitted value kinds.

Well-typed wires may have **open boundaries** — unconnected singular inputs are allowed and are part of the wire's importable/composable surface. An entry wire prepared for execution is a stricter category; see below.

**Evaluation-boundary check.** When a wire is prepared for execution — a step distinct from type-checking — every singular input port on its boundary must be connected to exactly one edge. The mechanism that performs this check and what it does on failure belong to the evaluation-model spec, not the grammar. A file-return wire with unconnected singular inputs is well-typed and importable; it is not ready to run until its caller supplies the missing edges.

The type-checker does **not** verify:

- That executor outputs conform to their declared contracts at runtime (structural check at evaluation time).
- That executor evaluation terminates, succeeds, or produces quality outputs.
- That a wire's composition is semantically meaningful beyond port compatibility.
- That the wire is runnable — that check belongs to evaluation preparation.

---

## 12. Complete example

A parallel-claim-branches thesis stress-test wire, exercising the core graph, config, and runtime-wrapper features:

```wire
# ---- contracts ----
# PlannerOutput, EvidenceBundle, AnalysisFragment, ReviewConcerns,
# ReviewBundle, and ExecutorError are declared by the @llm.* and
# prelude executor vocabularies — no local assertion needed.
# ReportArtifactRef is specific to @cortex.deep_report's output
# and comes from @cortex.* vocabulary.

# ---- shared prompt blocks (ordinary values) ----

let topo_awareness = ''
  You have access to the full upstream substrate via topological memory.
  Claim discipline is enforced by this prompt, not by information availability.
'';

let weak_evidence_rule = ''
  If contrary evidence is genuinely weak across the substrate, state
  that explicitly as a finding with its own section.
'';

let citation_rule = ''Cite evidenceRefs by toolCallId for every concrete claim.'';

let analyst_suffix = topo_awareness ++ weak_evidence_rule ++ citation_rule;

# ---- partial-node bases ----

let gatherer_base = @llm.gatherer {
  memory = topological { preset = "analyst"; };
};

let analyst_base = @llm.analyst {
  maxOutputTokens = 16384;
  memory = topological { preset = "analyst"; };
};

# ---- nodes ----

node planner : -> PlannerOutput | ExecutorError = @llm.planner {};

node gatherer_mechanism : <- PlannerOutput -> EvidenceBundle | ExecutorError =
  gatherer_base // { tools = [getDate, searchAssets, getAssetFundamentals, webSearch]; };

node gatherer_timing : <- PlannerOutput -> EvidenceBundle | ExecutorError =
  gatherer_base // { tools = [getDate, searchAssets, getAssetNews, webSearch]; };

node gatherer_beneficiaries : <- PlannerOutput -> EvidenceBundle | ExecutorError =
  gatherer_base // { tools = [getDate, searchAssets, getAnalystRatingChanges, webSearch]; };

node analyst_mechanism : <- EvidenceBundle -> AnalysisFragment | ExecutorError =
  analyst_base // { prompt = ''Attack the mechanism leg…'' ++ analyst_suffix; };

node analyst_timing : <- EvidenceBundle -> AnalysisFragment | ExecutorError =
  analyst_base // { prompt = ''Attack the timing leg…'' ++ analyst_suffix; };

node analyst_beneficiaries : <- EvidenceBundle -> AnalysisFragment | ExecutorError =
  analyst_base // { prompt = ''Attack the beneficiary leg…'' ++ analyst_suffix; };

node merge : <- fragments: [AnalysisFragment] -> AnalysisFragment =
  @llm.report_merge {};

node review : <- AnalysisFragment -> ReviewConcerns | ExecutorError =
  @llm.review {};

node rewriter : <- AnalysisFragment <- ReviewConcerns -> ReviewBundle | ExecutorError =
  @llm.rewriter {};

# Aggregates every ExecutorError variant from every impure node.
# List-valued input because there are many potential error sources.

node error_sink : <- [ExecutorError] = @artifact.log {};

# ---- the wire ----

let thesis =
  (   planner
   => ( gatherer_mechanism     => analyst_mechanism
      , gatherer_timing        => analyst_timing
      , gatherer_beneficiaries => analyst_beneficiaries )
   => merge
   => review
   => rewriter )
  <> (merge => rewriter);

(thesis => error_sink)
  => @cortex.deep_report {
       title = "Thesis Parallel Claim Branches";
       description = "Structural experiment in claim-scoped analyst branching.";
       match.skill = "deep-report";
       match.priority = 105;
       match.requestContainsAny = [
         "parallel claim branches",
         "claim-scoped analysts"
       ];
       render.aggregateOpenGaps = true;
       render.allowExtraSectionHeadings = true;
       workspace.sourceKind = "deep-report";
     }
```

#### What this exercises

- **Ambient contracts.** No local `contract` declarations needed; every contract name comes from an executor vocabulary (`@llm.*`, `@artifact.*`, `@cortex.*`, prelude).
- **Top-level declarations.** Uses `let` and `node`; no `circuit`, no meta blocks. Local `contract` declarations are omitted because executor vocabularies declare the contracts.
- **Executor families.** `@llm.*` for agent executors, `@artifact.log` for side-effecting sink, `@cortex.deep_report` for the runtime wrapper at the tail.
- **Partial-node bases with `//` merge.** `gatherer_base` and `analyst_base` capture shared config; per-node deltas merge on top.
- **Sum-grouped outputs.** `T | ExecutorError` on every impure node. Mutual exclusion is grammar-level.
- **List-valued input.** `<- fragments: [AnalysisFragment]` on `merge`; `<- [ExecutorError]` on `error_sink`.
- **Strict port matching driving all edges.** `(thesis => error_sink)` routes every `ExecutorError` boundary variant into the list-valued sink while leaving the terminal success output available for the runtime wrapper.
- **Partial node in graph position.** The final `=> @cortex.deep_report { ... }` is admissible only because the executor registry makes that partial port-determined (§5.4); composition context does not infer its signature.
- **Node alias semantics.** The second `merge` and second `rewriter` inside `<> merge => rewriter` are the same nodes as earlier occurrences.
- **File-return.** The final composition is the file-return expression, no trailing `;`.

---

## 13. Out of scope for v1

The following are intentionally deferred. Each has a known generalization path that does not invalidate v1 code.

- **Filtered connect `=>?`** — aspect-style composition where `=>` matches only compatible ports and passes the rest through. Admissible later as an additional operator without changing existing `=>`.
- **Refinement contracts** — `contract A :> B;` with subtyping. Deferred; flat contracts today.
- **Universal runtime contract `Graph C`** — polymorphic runtimes that accept any graph. Deferred; runtimes today are specialized by input contract.
- **Executor authoring in `.wire`** — extending the alphabet from within Wire. Deferred; executors are globally registered externally.
- **First-class functions / lambdas** — user-defined parameterized wire templates. Deferred; reuse today is via partial nodes + `//`.
- **Zero-port wires** — nodes or wires with no ports at all. Deferred; v1 requires every node to have at least one port.
- **Sum groups at input positions** — input ports are singular or list-valued; `|` is output-only. Admissible later.
- **`->` as graph operator** — removed from v1. It was a singleton-chain specialization of `=>` with zero additional expressiveness and a visual collision with the `->` output-port marker. `=>` covers every connect case. If a compelling ergonomic case emerges later, reintroducing `->` is additive and non-breaking.
- **Port projection and internal addressing** — `wire.node.port` reaching into wire internals. Rejected by design; violates boundary sealing.
- **Multiple built-in type constructors** — `Result`, `Option`, `List` as type constructors. Rejected; failure is topology (via sum groups), fan-in is `[C]` at input ports.
- **Evaluation model spec** — gas accounting, topological memory, rewrite bounds, determinism guarantees. Deferred to a sibling doc.
- **Typo backstop for pure wire-side contracts** — contracts declared only in wire files and never touching an executor port have no static check beyond name equality. Revisit if it bites.

---

## 14. Grammar summary (stratified EBNF)

Precedence is encoded in the grammar's stratification. The normative grammar is the prose of sections 2–9; this EBNF is a reference for implementers.

### 14.1 Top-level

```
file              ::= { top_form } [ file_return ]

top_form          ::= contract_decl
                   |  node_decl
                   |  let_binding
                   |  import_stmt

contract_decl     ::= "contract" identifier ";"

node_decl         ::= "node" identifier ":" port_sig "=" expr ";"

let_binding       ::= "let" identifier "=" expr ";"

import_stmt       ::= "import" identifier "from" string_literal ";"
                   |  "import" "{" ident_list "}" "from" string_literal ";"

file_return       ::= expr                          # no trailing ";"
```

### 14.2 Port signatures

```
port_sig          ::= { port_decl }

port_decl         ::= input_port
                   |  output_port

input_port        ::= "<-" [ label ":" ] input_type

input_type        ::= contract_ref
                   |  "[" contract_ref "]"

output_port       ::= "->" output_body

output_body       ::= variant                        # single-variant
                   |  variant "|" variant { "|" variant }   # sum group, ≥2 variants

variant           ::= [ label ":" ] contract_ref

contract_ref      ::= identifier
label             ::= identifier
```

### 14.3 Expressions (stratified by precedence)

Wire has two value kinds sharing an expression namespace. Disambiguation between graph-expression and value-expression readings is **semantic, not syntactic**: the same `expr` production parses both, and type information determines which operators apply.

```
expr              ::= expr_overlay

# infixl 2  <>
expr_overlay      ::= expr_connect { "<>" expr_connect }

# infixl 3  =>
expr_connect      ::= expr_select { "=>" expr_select }

# postfix 4  select(...)
expr_select       ::= expr_merge { select_suffix }

select_suffix     ::= "select" "(" select_arm { "," select_arm } [ "," ] ")"

select_arm        ::= identifier ":" expr

# infixl 5  //   and   ++   (same level; operate on disjoint value kinds)
expr_merge        ::= expr_atom { ( "//" | "++" ) expr_atom }

expr_atom         ::= partial_expr
                   |  constructor_expr
                   |  record_expr
                   |  list_expr
                   |  string_literal
                   |  number_literal
                   |  boolean_literal
                   |  paren_or_tuple
                   |  qualified_ident

paren_or_tuple    ::= "(" ")"
                   |  "(" expr ")"
                   |  "(" expr "," expr { "," expr } [ "," ] ")"
```

### 14.4 Value forms

```
partial_expr      ::= "@" qualified_ident record_expr

constructor_expr  ::= qualified_ident record_expr   # config-value constructor, no @

record_expr       ::= "{" [ field { ";" field } [ ";" ] ] "}"

field             ::= path "=" expr

path              ::= identifier { "." identifier }

list_expr         ::= "[" [ expr { "," expr } [ "," ] ] "]"

qualified_ident   ::= identifier { "." identifier }

ident_list        ::= identifier { "," identifier } [ "," ]
```

Notes on ambiguity:

- `partial_expr` (with `@`) can appear in graph-expression or value-expression position; disambiguation is semantic.
- `constructor_expr` (without `@`) is a plain qualified identifier followed by a record — used for config-value constructors like `topological { preset = "..." }`. It is a value-expression form only; it cannot appear in graph-expression position.
- `paren_or_tuple` is the empty wire `()` with no contents, ordinary parenthesization with one expression, and a tuple with two or more comma-separated expressions. Single-element `(a,)` is not admissible in v1; use `a` for parenthesization or two-or-more elements for a tuple. In graph-expression position, a tuple overlays its elements; in value-expression position, tuples are not first-class and the form is invalid.

---

## Appendix A — design principles

1. **Wires compose into wires.** The class of wire values is closed under graph operators. Records, strings, and lists have their own closed algebras. The two layers do not mix.
2. **One rule per mechanism.** One composition primitive (`<>`), one connect (`=>`), one record merge (`//`), one concatenation (`++`), one sum-group constructor (`|`), one executor application (`@name { ... }`). No path-chain sugar: `=>` covers every linear case; `->` is reserved for output-port declarations only.
3. **Closed alphabets, open composition.** Executors and contracts are the closed inputs; composition is open-ended. The LLM rewriter's action space is `(alphabet, composition) → wire`, which is inspectable.
4. **Ambient namespaces where global by nature.** Executors are globally registered; contracts are globally named. Everything else (nodes, `let`-values) is local and explicit.
5. **Labels are semantic.** A labeled port connects only to an identically-labeled partner; unlabeled ports connect only to unlabeled partners. Authoring a label is a commitment to label-routed matching, not a cosmetic annotation. §6.2 for the rule, §7.1 for its role in `=>`.
6. **Local reasoning over global inference.** Partial-node admissibility in graph position depends only on the partial and the executor registry, not on the enclosing expression. Port-polymorphic executors require explicit `node` declarations. The grammar has no whole-expression constraint solver.
7. **Strict where it matters, permissive where it doesn't.** Port contracts (and labels) are strictly matched. Config records are shallowly merged right-biased. Ports are unordered sets. Empty wire is identity.
8. **Grammar-level what, runtime-level how.** The grammar specifies composition. The runtime specifies evaluation. Mutual-exclusion pruning, gas, memory, rewrite bounds, and runnability checks all live downstream of the grammar and leave it small.
9. **Defer generalizations until pressure.** Filtered connect, refinement, universal graph contracts, lambdas, bootstrap wires — all admissible later. None required today. v1 ships the minimum that expresses the current production wires cleanly.

---

*End of specification v1.*
