---
title: "Wire Reference — Conditionality"
description:
  "Reference for exclusive-output reduction, `select(...)`, latent branches, and current
  implementation status in Cortex."
sidebar:
  label: Conditionality
  order: 7
status: draft
date: 2026-04-24
related:
  - docs/Reference/Wire/grammar.md
  - docs/Reference/rewrites.md
  - docs/ADRs/0007-latent-branch-conditional-lowering.md
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/07-rewrites-and-materialization.md
---

# Wire Reference — Conditionality

This page specifies the **target conditional model** for Wire.

The short version is:

- conditionality is not ordinary fan-out
- conditionality is **exclusive-output reduction**
- the formal resource model is **guarded-affine collapse**
- the canonical surface is postfix `select(...)`
- branches are **latent continuations** until one is selected
- output labels are the canonical arm keys, with unique contract names accepted as fallback keys
- `()` is the identity continuation
- productive arms share a common downstream boundary
- the current Cortex runtime is a narrower binary subset of this model

This page is normative about the intended language model and informative about the current
implementation status. [grammar.md](grammar.md) carries the compact grammar and typing rules; this
page expands the same conditional model semantically and explains how the current Cortex
implementation realizes a narrower subset.

## 1. Status and Scope

Two things are true at once:

1. **The target model is clear enough to write down now.** Wire conditionality should be expressed
   as exclusive-output reduction over latent continuations.

2. **The current implementation is narrower than the target model.** Current Cortex runtime support
   is still binary and is realized through retained-anchor rewrite machinery. That narrower
   implementation status is described explicitly in
   [§10 Current Implementation Status](#10-current-implementation-status).

This page therefore does five things:

- specifies the target semantic model for conditionality
- specifies the target `select(...)` surface
- defines latent branches in the target model
- states the main typing, composition, resource, and budgeting rules
- records how the current Cortex implementation realizes a narrower subset today

This page does not repeat the full EBNF for `select(...)`; that lives in [grammar.md](grammar.md).

## 2. Conditionality Is Exclusive-Output Reduction

The right starting point is not “a node with several possible next edges.” The right starting point
is:

> a graph exposes an **exclusive output boundary**, and conditionality reduces that boundary by
> selecting which continuation becomes the output of the reduced graph.

If a graph `x` yields several mutually exclusive exits, conditionality is the operation that says:

- attach one continuation graph to each possible exit
- actualize exactly one of them
- treat the result as the output of a reduced graph `x'`

This is why conditionality is not ordinary `match`, and not ordinary routing into already-live
branches.

It is better understood as:

- a graph `x`
- with an exclusive output boundary
- reduced by `select(...)` into a graph `x'`
- where `x'` has one actualized continuation path

The resource term for this reduction is **guarded-affine collapse**. Before selection, each arm is a
guarded continuation: it is validated as a possible future, but it is not live topology. It is
affine because at most one guarded arm can be promoted for the run. Selection collapses the
exclusive boundary by promoting the chosen arm into the live linear context and discarding the
unchosen arms.

This is also why parentheses are natural in branch bodies:

```wire
(gather_missing_constraints => repair_plan)
```

is one **continuation graph**. It has its own entry boundary and its own exit boundary, and
`select(...)` may actualize it as one possible continuation.

## 3. Why Ordinary Fan-Out Is Wrong

If a conditional were lowered as ordinary graph fan-out, then both branches would appear runnable
under the normal readiness rules. That is wrong for Wire.

In ordinary fan-out:

```wire
a => (b <> c)
```

both `b` and `c` are part of the live graph and both are eligible to become actual work when their
inputs are available.

That is **not** what a conditional means. A conditional means:

- the workflow knows several possible futures
- runtime will commit to exactly one of them
- the unchosen futures never become live topology

The opposite mistake is to hide the choice inside stage-local imperative code. That also fails,
because the compiled workflow artifact then stops telling the truth about what obligations may
arise.

The conditional model Wire needs is therefore:

> compiled possibility is wider than current actuality, but only one branch may become live.

## 4. Exclusive Outputs Are Necessary but Not Sufficient

Wire already has one crucial ingredient: **sum-grouped output ports**.

```wire
node gate
  <- evidence: EvidenceBundle ;
  -> fragment: AnalysisFragment | error: ExecutorError ;
  = @review.review (evidence) ;
```

The accepted grammar already says:

- a sum group is a grammar-level construct distinct from independent multi-output declarations
- at each evaluation, exactly one variant fires
- the runtime carries and enforces that mutual-exclusion metadata

See [§4 Contracts And Ports](grammar.md#4-contracts-and-ports).

That means the language already knows how to say:

> this node produces one of several mutually exclusive outcomes.

But that is still **not** a full conditional.

Sum groups define an **exclusive output boundary**. They do **not yet** define how continuation
graphs should be attached to that boundary. That second step is what conditionality needs.

So the full model has two layers:

1. **exclusive output declaration** — already in the grammar via sum groups
2. **exclusive-output reduction** — the conditional surface defined on this page

## 5. Canonical Surface: `select(...)`

The target surface is a postfix conditional form:

```wire
selector select(
  Variant1: branch1,
  Variant2: branch2
) => shared_continuation
```

The intended reading is:

- the graph on the left of `select(...)` exposes an exclusive output boundary
- each arm names one possible output variant of that boundary
- each arm provides the continuation graph for that variant
- exactly one continuation graph is actualized
- the reduced graph then continues through the selected continuation

This is why the operator belongs **after** the selecting graph, not around it. The left-hand graph
is the thing whose output boundary is being reduced.

> **Syntax status.** `select(...)` is now the accepted conditional form in [grammar.md](grammar.md).
> This page remains the fuller semantic reference for how that form should be understood.

### 5.1 `select(...)` is a single expression unit

`select(...)` should read as one expression unit in the same way ordinary grouped graph expressions
do.

So:

```wire
x select(
  Left: a,
  Right: b
) => continuation
```

means:

- reduce the exclusive boundary exposed by `x`
- actualize either `a` or `b`
- then connect the resulting reduced graph to `continuation`

This does **not** mean the same thing as:

```wire
x => (a <> b) => continuation
```

The boundary shape may be similar when all arms are productive, but the actuality story is
different:

- `x => (a <> b)` makes both branches live
- `x select(...)` keeps both branches latent and actualizes one

That semantic distinction must stay explicit.

### 5.2 Output labels are the canonical arm keys

Branch keys resolve against **variant identity**.

The current rule is:

- use the variant's **label** as the arm key;
- accept the variant's **contract name** as a fallback only when it is unique;
- report an ambiguity when a key resolves to more than one variant.

So with:

```wire
node validate_plan
  <- draft: DraftPlan ;
  -> valid: ResearchPlan | issue: PlanIssue ;
  = @review.validate_plan (draft) ;
```

this is the natural conditional:

```wire
validate_plan select(
  valid: (),
  issue: (gather_missing_constraints => repair_plan)
)
```

This is better than positional matching because:

- variant reordering does not silently change meaning
- the names already exist in the node signature
- exhaustiveness is easier to check

## 6. `()` Is Empty Wire, and Empty Wire Is Identity

`()` is the **empty wire**: zero nodes, zero edges, empty boundary.

Under composition, empty wire is identity:

```wire
a <> () = a
() <> a = a
a => () = a
() => a = a
```

So `()` is not a strange conditional-only token, and it is not a materialized `Id` node. It is the
ordinary empty wire, which disappears when placed in a continuation hole.

Inside `select(...)`, that means an arm body of `()` contributes **no extra branch-local topology**.
If the selected variant already exposes the required downstream boundary, the reduced graph simply
continues.

In:

```wire
validate_plan select(
  valid: (),
  issue: (gather_missing_constraints => repair_plan)
)
```

the first branch means:

- take the already-valid `ResearchPlan`
- insert no extra branch-local graph
- continue directly with the current boundary

and the second branch means:

- take the `PlanIssue`
- run the repair continuation graph
- continue with the repaired `ResearchPlan`

This also means `()` is **not** a terminal branch. A terminal branch would absorb the current path
and expose no matching downstream boundary. `()` does the opposite: it vanishes under composition,
so the current boundary continues unchanged.

## 7. Latent Branches

### 7.1 Core concept

**Latent branches** are Wire's mechanism for implementing closed-world conditional branching without
turning possibilities into live topology.

A conditional does **not** compile to ordinary fan-out. Instead, it compiles to:

- one **owner / anchor node** that remains in the live compiled graph
- one or more **latent branch fragments** or implicit pass-through continuations
- exactly one selected continuation that becomes actualized

Only the chosen continuation is ever materialized. All others stay latent.

### 7.2 Why latent branches exist

Latent branches solve the central correctness problem:

- several possible futures are known at compile time
- runtime commits to exactly one
- unchosen futures must never become live

This keeps compiled possibility wider than current actuality without making the compiled artifact
lie about what may happen.

### 7.3 How latent branches work

When you write:

```wire
validate_plan select(
  valid: (),
  issue: (gather_missing_constraints => repair_plan)
)
```

the target model is:

- one owner node remains live
- one continuation is attached to `ResearchPlan`
- one continuation is attached to `PlanIssue`
- those continuations are **sealed**
- exactly one is selected and materialized

For the identity arm `()`, this may mean that no extra branch-local topology is materialized at all.
The reduced graph simply continues through the already-correct boundary.

### 7.4 Key invariants

- **Sealed internals** — Latent branch contents are not addressable from outside before
  materialization.
- **Only one becomes live** — Only the selected continuation ever becomes actual live topology.
- **Owner remains** — The anchor stays visible for provenance and lineage.
- **Latent until selected** — Unselected branches are not eligible under ordinary readiness rules;
  conditionality never lowers to ordinary fan-out.
- **Guarded-affine resources** — Branch-local boundary obligations are checked under their arm key
  before selection and become ordinary live obligations only for the selected arm.

## 8. Typing and Composition

### 8.1 Productive-arm rule

The target rule for the first usable `select(...)` design is:

- every arm must be **productive**
- every arm must expose an output boundary
- all arms must converge to the same downstream boundary
- downstream `=> ...` after `select(...)` is typed against that common boundary

Good:

```wire
review_report select(
  ReviewedReport: (),
  ReviewIssue: revise_report
) => publish_report
```

because both arms expose the same downstream boundary expected by `publish_report`.

Deferred:

```wire
review_report select(
  ReviewedReport: (),
  ReviewIssue: error_terminal
) => publish_report
```

because one branch is productive and the other is absorptive or terminal. That introduces optional
downstream execution and is a larger typing step.

### 8.2 Informal typing rule

Informally, if:

- `G` exposes an exclusive output boundary with variants `V1 ... Vn`
- each branch `Bi` consumes `Vi`
- each branch `Bi` yields the same boundary `T`

then:

- `G select(V1: B1, ..., Vn: Bn)` also yields boundary `T`

In sketch form:

```text
G  : I -> (V1 | ... | Vn)
B1 : V1 -> T
...
Bn : Vn -> T
-------------------------------
G select(V1: B1, ..., Vn: Bn) : I -> T
```

This is enough for the semantic reference. [grammar.md](grammar.md) carries the compact formal
grammar and operator precedence.

### 8.3 Shared continuation should stay outside

This is better:

```wire
validate_plan select(
  valid: (),
  issue: (gather_missing_constraints => repair_plan)
) => (load_positions <> load_option_chains <> load_filings <> load_macro_context)
```

than this:

```wire
validate_plan select(
  valid: load_positions,
  issue: (gather_missing_constraints => repair_plan => load_positions)
)
```

Parenthesize the overlay because the grammar rejects unparenthesized mixed `<>` / `=>` expressions.

because the shared continuation should not be duplicated inside the branch alternatives unless it
genuinely differs by branch.

Keeping shared continuation outside `select(...)`:

- keeps the branch-local shape symmetric
- avoids ambiguity about what the shared continuation is
- keeps the branch-local gas reserve smaller and clearer
- matches the retained-owner materialization story better

## 9. Examples

### 9.1 Binary workflow example

```wire
node validate_plan
  <- draft: DraftPlan ;
  -> valid: ResearchPlan | issue: PlanIssue ;
  = @review.validate_plan (draft) ;

node gather_missing_constraints
  <- issue: PlanIssue ;
  -> missing: MissingConstraints ;
  = @artifact.gather_missing_constraints (issue) ;

node repair_plan
  <- missing: MissingConstraints ;
  -> valid: ResearchPlan ;
  = @review.repair_plan (missing) ;

node review_report
  <- draft: DraftReport ;
  -> reviewed: ReviewedReport | issue: ReviewIssue ;
  = @review.review_report (draft) ;

node revise_report
  <- issue: ReviewIssue ;
  -> reviewed: ReviewedReport ;
  = @review.revise_report (issue) ;

load_brief
  => draft_plan
  => validate_plan select(
       valid: (),
       issue: (gather_missing_constraints => repair_plan)
     )
  => (load_positions <> load_option_chains <> load_filings <> load_macro_context)
  => (analyze_equities <> analyze_options <> analyze_risk)
  => gather_report
  => review_report select(
       reviewed: (),
       issue: revise_report
     )
  => publish_report
```

How to read it:

- `validate_plan` yields either a usable `ResearchPlan` or a `PlanIssue`
- `select(...)` reduces that exclusive boundary
- if `ResearchPlan` is selected, `()` forwards it unchanged
- if `PlanIssue` is selected, the repair continuation runs first
- later, `review_report select(...)` applies the same pattern again before publication

### 9.2 Planned generalization: multi-way conditionals

The target language model scales naturally to more than two arms:

```wire
classify_issue select(
  LowIssue: simple_fix,
  MediumIssue: (gather_context => standard_fix),
  HighIssue: (escalate => senior_review),
  CriticalIssue: (page_oncall => incident_plan)
) => execute_remediation
```

The same rules still apply:

- output labels are the canonical arm keys
- every arm is a continuation graph
- every arm is productive
- every arm converges to the same downstream boundary
- exactly one continuation becomes live

Current Cortex runtime does not yet natively realize this general form. See
[§10 Current Implementation Status](#10-current-implementation-status).

## 10. Current Implementation Status

The current Cortex implementation is a **narrower subset** of the target model above.

What exists today:

- accepted `select(...)` syntax in the Wire grammar
- parser and bridge-compiler support for postfix `select(...)`
- n-way source `select(...)` lowered by the compiler to nested binary condition trees
- a binary runtime model
- one owner / anchor node
- one `then` latent fragment
- one optional `else` latent fragment
- sealed latent internals
- operational realization through retained-anchor `AppendAfter`

So the truth today is:

- **semantically**: closed-world selection / actualization
- **operationally**: realized through ordinary retained-anchor rewrite machinery

What does **not** exist natively yet:

- native n-way latent fragments owned by one selector
- a distinct runtime selection event separate from ordinary rewrite machinery
- reserved latent capacity as a runtime guarantee

So the current implementation status is:

- the accepted `select(...)` language surface is implemented in the parser
- the current bridge compiler lowers that surface onto the existing binary owner + latent-fragment
  runtime
- native runtime ownership is still binary even when the source-level `select(...)` has more than
  two arms

This page treats that narrower implementation as a subset of the intended model, not as the final
shape of the language.

## 11. Resources, Budget, and Provenance

Three truths should be kept explicit.

### 11.1 The whole branch set is guarded-affine, not sum-prepaid

For closed-world latent alternatives, the right resource intuition is:

- branch validation is universal: every arm must be valid if chosen
- branch execution is exclusive: only one arm can become live
- branch-local obligations are guarded and affine before selection

That means Cortex should not charge `sum(allBranchCosts)` up front. The current runtime goes one
step narrower: it does not reserve `max(branchCosts)` either. It charges the selected branch when
the branch is actualized.

### 11.2 Current runtime uses selected-cost accounting

Today, selected latent branches still consume ordinary rewrite budget because they are operationally
realized through `AppendAfter`.

So current Cortex already gives:

- no “sum of all branches” cost up front
- truthful latent-branch semantics
- selected-cost admission through the ordinary durable rewrite path

but does **not yet** give:

- guaranteed reserved capacity for any later-selected branch regardless of prior open rewrites

If Cortex later decides that compiled latent alternatives must be guaranteed, that is an
architectural choice beyond this chapter and likely ADR-worthy. That future policy would need to say
whether it reserves `max(branchCosts)`, reserves per branch family, or changes the rewrite-budget
algebra.

### 11.3 Provenance remains attached to the owner

The retained-anchor model is part of why the current approach works well operationally:

- the owner node remains visible in lineage
- the selected branch becomes explicit topology behind it
- the branch choice is not hidden in stage-local imperative control flow

Provenance must remain attached to the owner.

## 12. Relationship to Legacy `if ... between ...`

The old surface existed for a reason: downstream workflows needed conditional branching.

The goal now is not to remove that capability. The goal is to carry it into Wire under a cleaner and
more truthful semantic model.

So the migration stance should be:

- **preserve capability**
- **change the canonical surface**
- **do not revive the old syntax as the long-term semantic center**

A typical migration shape is:

```wire
if required_evidence_missing between gatherer analyst {
  repair;
} else {
  ();
}
```

to:

```wire
required_evidence_missing select(
  Ready: (),
  MissingEvidence: repair
) => analyst
```

The exact legacy names in real workflows will vary, but the semantic mapping is stable:

- old condition anchor becomes the selector on the left
- old branch bodies become named continuation graphs inside `select(...)`
- old pass-through arm becomes `()`
- shared continuation stays outside

`if` may later exist as sugar if it genuinely helps readability, but the core model should remain
exclusive-output reduction over latent continuations.

## 13. Current Commitments

This chapter makes the following commitments unless later superseded:

1. Wire conditionality is not ordinary fan-out.
2. The right semantic model is reduction on an exclusive output boundary.
3. The canonical surface is postfix `select(...)`.
4. Output labels are the canonical arm keys; unique contract names remain fallback keys.
5. `()` is the identity continuation on the current boundary.
6. Latent branches are sealed and only the selected continuation becomes live.
7. Shared continuation should usually live outside `select(...)`.
8. Productive arms converge to a common downstream boundary.
9. The current Cortex implementation is a narrower subset of this target model.
10. The current runtime uses selected-cost branch actualization, not reserved latent capacity.

## 14. Deferred

This chapter intentionally leaves the following open:

1. whether labels are admitted alongside contract-name keys in the initial accepted surface
2. whether later versions admit terminating or absorptive arms that do not expose the shared
   downstream boundary
3. whether a dedicated terminator such as `!` becomes the first extension after the initial
   `select(...)` design
4. whether the runtime later gets a distinct selection event rather than piggybacking on ordinary
   rewrite machinery
5. whether latent branch capacity becomes reserved rather than merely conceptually distinct from
   open rewrite capacity

This chapter is intended to make the target semantics and the current implementation subset legible
alongside the accepted grammar.

## Related

- [grammar.md](grammar.md) — accepted Wire grammar.
- [../rewrites.md](../rewrites.md) — runtime rewrite algebra and current `AppendAfter` realization.
- [../../ADRs/0007-latent-branch-conditional-lowering.md](../../ADRs/0007-latent-branch-conditional-lowering.md)
  — accepted latent-branch architecture decision.
- [../../ADRs/0033-wire-select-guarded-affine-collapse.md](../../ADRs/0033-wire-select-guarded-affine-collapse.md)
  — guarded-affine collapse vocabulary.
- [../../ADRs/0034-wire-pure-select-actualization-authority.md](../../ADRs/0034-wire-pure-select-actualization-authority.md)
  — pure selectors and restricted actualization authority.
- [../../ADRs/0036-wire-latent-branch-budget-recovery.md](../../ADRs/0036-wire-latent-branch-budget-recovery.md)
  — selected-cost latent branch policy.
- [../../Architecture/05-wire-language.md](../../Architecture/05-wire-language.md) — Wire substrate
  architecture.
- [../../Architecture/07-rewrites-and-materialization.md](../../Architecture/07-rewrites-and-materialization.md)
  — rewrite/materialization architecture.
