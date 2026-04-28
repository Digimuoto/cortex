---
title: "Wire Composition Sugar: Operators, Templates, Lambdas, Combinator Executors"
description:
  Speculative evaluation of composition-level reuse mechanisms for Wire beyond the v1 Mokhov
  algebra. Not a spec proposal; preserved as design backlog.
date: 2026-04-23
status: research
related:
  - docs/Reference/Wire/grammar.md
  - docs/Architecture/05-wire-language.md
---

# Wire Composition Sugar

## Context

The Wire grammar ships with two graph operators (`<>` overlay and `=>` connect) plus tuples, and one
reuse primitive at the node level: partial nodes with `//` merge (§5.3 of the spec). Deliberately
small. Deliberately Mokhov-algebraic.

Two classes of reuse are naturally expressible in v1:

- **Node-level reuse** — "same executor archetype, different config." Covered by partial nodes +
  `//`. The flagship example's `analyst_base // { prompt = ... }` is the canonical pattern.
- **One-off composed wires** — `let thesis = planner => analyst => reviewer;` binds a specific wire.

What v1 does _not_ have is **composition-level reuse** — "same topology, different node
participants." Patterns like zip, scatter-gather, or pipeline-with-review are expressible today only
by writing them out for each instance. This note evaluates the design space for adding
composition-level reuse, concludes that none of it is load-bearing for v1, and preserves the
thinking so the question doesn't have to be rediscovered.

Scope of this note: speculative design backlog, not a spec proposal. Spec stays tight around the
Mokhov algebra. Anything here is admissible later without invalidating v1 wires.

## Four Candidate Mechanisms

### 1. New Operators (`=<<`, `>>=`, `<*>`, `</>`)

Proposed in early jam sessions: sugar operators for fanout, fanin, star, clique.

Evaluated:

- **`=<<` fanout.** Redundant with `source => (a, b, c)`, which already cross-product-matches
  source's outputs to each tuple element's inputs on contract. `=<<` would add a glyph with no
  semantic gain.
- **`>>=` fanin.** Mirror of `=<<`. `(a, b, c) => aggregator` with list-valued `<- [C]` already
  covers it. Arity distinguishes list-input aggregation from singular-input arity error.
- **`<*>` star.** The applicative analogy does not port to directed dataflow. The only semantics not
  already covered are bidirectional hub-and-spoke, which introduces cycles through every spoke and
  breaks DAG. Scatter-gather is already `source => middle => sink`, one chain.
- **`</>` clique.** All-to-all in a directed graph produces `n(n-1)` edges and a cycle between every
  pair. Useful for gossip/all-reduce patterns; Wire is not targeting those. Almost always a smell in
  typed dataflow; prefer an aggregator node.

**Verdict:** zero added expressiveness for all four. Operators have compounding cost (LLM rewriter
action space, reader load, precedence decisions). Hard reject for v1 and later.

The one pattern that _is_ notationally awkward today is **zip / pairwise** — `(a, b) => (c, d)`
means cross-product (four edges); pairwise `a => c, b => d` is `(a => c) <> (b => d)` written out.
Linear growth with arity. If any operator were to justify itself, it'd be zip. But zip is better
served by templates or a combinator executor than by a new graph operator.

### 2. Templates with Holes

A named parameterized graph expression, expanded at parse time.

Sketch:

```haskell
template zip(a, b, c, d) = (a => c) <> (b => d);

let my_wire = zip(planner, analyst, gatherer, merge);
```

Invocation expands to the base algebra at compile time. Fixed arity. No first-class "template value"
exists; templates cannot be passed around, stored, or returned.

Roughly C-macro or Scheme `syntax-rules` in scope. Cheap to add:

- One new top-level form.
- Parameter-list syntax.
- Invocation-as-call syntax.
- No type-level machinery needed (body is closed over the graph algebra).

**Unlocks:** named known-arity composition patterns. Zip, scatter-gather, pipeline-with-review,
error-routing wrapper, etc. — whatever the production wires repeat.

**Does not unlock:** variable-arity patterns (templates are arity-fixed), higher-order composition
(no first-class template values).

**Restriction proposal:** if added, restrict template bodies to **graph-algebra expressions only** —
`<>`, `=>`, parameters, other templates. No record operations, no string concat, no conditional
logic. Keeps the action space bounded and inspectable; same design pressure as "closed alphabets,
open composition."

### 3. Full Lambdas

First-class functions over wires. `let zip = \(a, b, c, d) -> (a => c) <> (b => d);` — bind a
function value, invoke via application.

Bigger jump than templates:

- Lambda syntax.
- Application syntax.
- Inference (probably).
- Closure semantics.
- First-class function values that can be passed, stored, returned.

**Unlocks beyond templates:**

1. **Variable-arity combinators.** `fold_overlay : [Wire] -> Wire = foldl (<>) ()`. Templates cannot
   express this — they need one definition per arity. A planner that emits `N` section briefs and
   needs `N` corresponding workers wired to one aggregator is currently awkward; with lambdas + list
   operations it is direct.

2. **Composable structural transformers.** Wire-to-wire functions composed via `∘`:
   `wrap_with_retry ∘ add_error_sink ∘ base_thesis`. Each transformer is a value; you store them in
   lists, apply them conditionally. Templates give you one transformer at a time, not composition of
   transformers.

3. **LLM rewriter abstraction (speculative).** A rewriter that notices "I keep wiring this 4-node
   pattern" could _emit a lambda definition_ capturing the pattern, then use the lambda name in
   subsequent rewrites. This is compositional compression — a qualitatively different rewriter
   behavior from "edit nodes and edges." Adjacent to the rewrite materialization plan and Paper 3
   (graph substitution semantics). Speculative; unproven.

**Does not unlock:** anything not already unlockable by templates when arity is known at compile
time.

### 4. Registered Combinator Executors

Instead of Wire-language sugar, register specific composition patterns as executors in the Cortex
alphabet. `@combinator.zip`, `@combinator.fan_out_n`, etc.

Sketch (hypothetical):

```
node zip_pair :
  <- first:  Wire
  <- second: Wire
  <- third:  Wire
  <- fourth: Wire
  -> Wire
= @combinator.zip {};
```

**Catch:** this requires Wire-typed ports or a universal `Graph` contract — both deferred in v1 (§13
"Universal runtime contract `Graph C`"). It also introduces _compile-time evaluation_ of executors,
which is a real semantic shift from today's "executors run at evaluation time."

**Trade-off:** uses the existing alphabet mechanism (fits the design rule "Wire composes registered
authority; Haskell owns what the authority means"), but introduces a second role for executors —
structural expansion alongside value production. One mechanism, two semantics.

## Analysis

Three questions decide each:

**What's the trigger that promotes it from speculative to necessary?**

- **Operators:** none foreseeable. Reject permanently.
- **Templates:** the first time a production wire or rewrite proposal repeats a known-arity
  composition pattern enough times that inlining feels painful. Probably arrives with dynamic
  rewrite work.
- **Lambdas:** the first time a planner-driven rewrite needs variable-arity wiring (N workers wired
  generically), or the first time the rewriter wants to factor a discovered pattern into a named
  abstraction.
- **Combinator executors:** requires universal `Graph` contract landing first. Until then, blocked.

**What's the cost?**

- **Operators:** low per operator, compounding. Each one expands LLM rewriter action space and
  reader load permanently.
- **Templates:** moderate. One new top-level form, restricted body, parse-time expansion. Rewriter
  just sees the expansion.
- **Lambdas:** high. Full function language under Wire. Inference story. Closure semantics. Type
  system implications.
- **Combinator executors:** moderate-high. Unlocks structural-expansion-at-compile-time, which
  affects evaluation model.

**What does the rewriter have to learn?**

- **Operators:** more glyphs.
- **Templates:** new top-level form; expansion means rewriter sees base algebra.
- **Lambdas:** full function language; action space significantly bigger.
- **Combinator executors:** nothing new — executors are already in the alphabet.

## Recommendation

**Hold the line at v1's Mokhov algebra.** No operator sugar, no templates, no lambdas, no combinator
executors in v1.

Watch for these pressure signals:

1. **Known-arity composition repetition** in production wires or rewrite proposals. If it starts
   happening, templates are the right answer — cheap, bounded.
2. **Variable-arity wiring requirement** from planner-driven rewrites. Lambdas become the right
   answer — but only this specific case justifies them.
3. **Rewriter pattern-compression behavior** in agent work. If a rewriter starts "wanting" to name
   patterns it discovers, lambdas become interesting for a different reason. Speculative.
4. **Universal Graph contract** landing for other reasons. Combinator executors become admissible as
   a by-product; evaluate then.

Until one of those fires concretely, each mechanism stays in the backlog.

## Notes on Genuine Unlocks

Three observations worth preserving:

### Lambdas are not pure sugar; templates are

Templates expand at parse time. Everything they can express is a fixed-arity composition. Lambdas
can express combinators over variable-arity lists of wires. The "templates are to lambdas what
partial nodes are to full functions" framing is correct: templates buy ~80% of ergonomic wins at
~20% of conceptual cost, but the remaining 20% is real, not cosmetic.

### The rewriter abstraction case is speculative but interesting

A rewriter that can emit `let foo = \(...) -> ...` and use it later is doing something qualitatively
different from a rewriter that only edits topology. It is compressing its own output. If research on
Cortex rewriting (rewrite materialization plan / Paper 3) moves toward abstraction-emitting
rewriters, lambdas become a design requirement, not a convenience.

### "Closed alphabets, open composition" can be extended without operators

The current action space is `(alphabet, composition) → wire`. Adding templates keeps the alphabet
closed (executors and contracts registered externally) but expands the composition side with named
patterns. Adding lambdas does the same but with first-class functions. Neither violates the design
rule; both extend it. What does violate the rule: operators. Each new operator enlarges the closed
side of the equation.

## Appendix — The Zip Problem in Detail

The pairwise-composition case deserves a concrete trace because it is the most commonly-cited
motivation for added sugar.

**Current v1 expression:**

```haskell
(a => c) <> (b => d)
```

Two edges: `a → c`, `b → d`. Scales linearly with arity:

```haskell
(a1 => b1) <> (a2 => b2) <> (a3 => b3) <> (a4 => b4)
```

**Current v1 cross-product (the default for `=>` over tuples):**

```haskell
(a1, a2, a3, a4) => (b1, b2, b3, b4)
```

Sixteen edges (4×4). This is what `=>` means; it is not the same as zip.

**Candidate sugar mechanisms:**

- Operator `~~` or similar: `(a1, a2, a3, a4) ~~> (b1, b2, b3, b4)`. Dedicated pairwise operator.
  Rejected for reasons above.
- Template:
  `template zip4(a1, a2, a3, a4, b1, b2, b3, b4) = (a1=>b1) <> (a2=>b2) <> (a3=>b3) <> (a4=>b4);`.
  Arity-specific; one template per arity.
- Lambda: `let zip = \lefts rights -> foldl (<>) () (zipWith (=>) lefts rights);`. Variable-arity.
  Requires lambdas + list operations + `zipWith` as a registered combinator.
- Combinator executor: `@combinator.zip`. Requires universal Graph contract.

**Observation:** the zip problem only appears painful when you want variable-arity zip. Fixed-arity
zip is one overlay chain; the pattern is obvious and short. If variable-arity zip becomes a
production requirement, it is a lambda-level question, not an operator-level one.

---

_This note is speculative backlog. No v1 spec change is proposed. Revisit when one of the four
pressure signals fires._
