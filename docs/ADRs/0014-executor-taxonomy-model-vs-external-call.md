---
title: "ADR 0014 — Model vs External Call"
description:
  "Cortex node executors reduce to two kinds — ModelExecutor (model-mediated generation) and
  ExternalCallExecutor (registered external backend call). Sub-workflow composition is delegated to
  the rewrite algebra."
sidebar:
  label: "0014. Model vs external call"
  order: 14
status: proposed
date: 2026-04-24
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
---

# ADR 0014 — Model vs External Call

## Status

Proposed — clarifies an implicit distinction the substrate already makes and pins the extensibility
story for new backends.

## Context

Every Cortex node carries a `StageAction` that the runtime dispatches. In practice this action
resolves to one of three things today: a model call (LLM executor), a tool call (gatherer dispatch),
or an HTTP host-action call into a consumer service. The substrate treats these as operationally
distinct — different retry semantics, different trust boundaries, different observability — but has
no explicit taxonomy.

A first sketch for the reasoning layer proposed three executor kinds: `Model | Tool | Composite`.
Two of those don't hold up. `Composite` is not a node-level executor — a sub-workflow is graph
structure inserted via rewrite algebra, not a leaf action. `Tool` and host-action collapse into one
kind: both are typed external calls under a registered name, differing only in where the call lands.

New backends are coming: OpenAPI-derived tool surfaces, WASM-packaged executors, MCP adapters.
Without an explicit taxonomy each new backend either introduces a parallel executor kind and forces
Wire grammar changes, or leaks backend specifics into the substrate — both outcomes erode the
closed-authority stance established in ADR 0010.

Picking the wrong defining axis risks a related failure. External backend calls are not uniformly
deterministic: HTTP host actions that write to databases, OpenAPI calls against stateful services,
and MCP adapters wrapping mutable systems all have side effects. If determinism is treated as the
defining property of "external call," the taxonomy collapses the moment a real backend violates it.

## Decision

Cortex defines exactly two node-level executor kinds, split on **mode of production**:

- **`ModelExecutor`** — model-mediated generation. Produces output by running an LLM under a
  constrained schema. Stochastic internally; bounded and explainable at the contract boundary.
  Retry, rate-limit, token-cost, and provenance semantics are model-aware.
- **`ExternalCallExecutor`** — a registered external backend call. Typed I/O under a registered
  name; no inline generation. One kind, many backend variants: native Haskell tools, HTTP host
  actions into consumer services, OpenAPI-derived calls, WASM modules, MCP adapters, and future
  additions. The backend list is evolvable; Wire is agnostic to which backend produced a given
  registration.

Sub-workflow composition is **not an executor kind**. A region of more-graph enters a plan through
rewrite algebra (`AppendAfter`, `ExpandNode`) from ADR 0005 / chapter 07, not through a `Composite`
action.

Determinism, replay-safety, and side-effect class are **separate metadata axes**, not properties of
the executor kind. Any executor — model or external — can be tagged as replay-safe, idempotent,
irreversible, and so on. Policy (retry eligibility, resume-on-irreversible warnings, gas class) keys
off the metadata, not off the kind.

Registration invariant: Wire references registered executor names with typed contracts and policy
metadata. Wire is agnostic to which backend produced the registration. New backends slot in under
`ExternalCallExecutor` without changes to Wire grammar or the executor-kind taxonomy.

## Alternatives considered

- **Three-kind taxonomy (`Model | Tool | Composite`).** Rejected because `Composite` is structural —
  a sub-workflow is Circuit inserted by a rewrite, not a leaf action — and `Tool` and host-action
  calls collapse into one kind with backend variants.
- **Per-backend executor kinds** (`ToolExecutor`, `HostActionExecutor`, `WasmExecutor`, …). Rejected
  because every new backend would require a change to the executor-kind taxonomy and potentially to
  Wire grammar, defeating the extensibility goal. Backend diversity belongs one level below the kind
  boundary.
- **Split on determinism** (`DeterministicExecutor` vs `StochasticExecutor`). Rejected because many
  registered external backends are not deterministic — HTTP host actions, stateful-service OpenAPI
  calls, MCP adapters. Using determinism as the defining axis makes the taxonomy collapse the first
  time a real backend violates it. Determinism belongs on a metadata axis that cross-cuts both
  kinds.
- **One executor kind with runtime type dispatch.** Rejected because `ModelExecutor` and
  `ExternalCallExecutor` differ on load-bearing dimensions — mode of production, rate-limit policy,
  token economics, provenance shape — and collapsing them pushes policy into ad hoc branches inside
  the executor.

## Consequences

### Positive

- New backends (OpenAPI, WASM, MCP) slot in as `ExternalCallExecutor` variants without touching Wire
  grammar or the executor-kind taxonomy.
- Policy keys off the two kinds consistently for model-aware concerns (rate limit, token cost,
  schema validation) and off cross-cutting metadata for execution concerns (retry eligibility,
  replay safety, side-effect class).
- Stage-action metadata stays small and typed; registration surface remains the single place where
  backend detail lives.
- The rewrite algebra stays the only path by which a plan gains more graph structure — composition
  concerns do not leak into executor dispatch.

### Negative

- Backend-specific metadata (OpenAPI spec IDs, WASM module hashes, MCP capability descriptors) must
  live in registration records, not inline in Wire source.
- Authoring helpers that declaratively derive a registered palette from an OpenAPI document must
  compile through the registration path rather than short-circuit into Wire semantics.

### Obligations

- Document the backend sub-taxonomy in the runtime reference so each backend's registration shape is
  explicit.
- Document the cross-cutting metadata axes (determinism, replay safety, side-effect class) as a
  distinct reference surface so policy rules can be written against it cleanly.
- Keep Wire grammar agnostic to backend — grammar growth is about topology and authoring, not about
  backend vocabulary.
- Any future proposal for a third executor kind requires its own ADR with a distinctness argument
  beyond backend diversity.

## Traceability

- Feature keys: `capability.executor_taxonomy`
- Public surface: `Cortex.Wire`, `Cortex.Capability`,
  [Wire Executors and Alphabet reference](../Reference/Wire/executors-and-alphabet.md)
- Implementation: `src/Cortex/Wire/Executor.hs` (the registered-executor projection surface;
  `WireExecutorEffect` distinguishes the model kind `WireExecutorModel` from the external-call kind
  `WireExecutorHostEffect` on the cross-cutting effect axis), `src/Cortex/Capability/Executor.hs`
  (`ExecutorSpec`, `executorProjection` — the single registered-name external-call surface under
  which native, host-action, and future backend variants slot without new executor kinds)
- Tests: `test/Cortex/Capability/Executor/PureSpec.hs` (asserts an executor spec's declared effect
  class through `executorSpecEffect`), `test/Cortex/Capability/CatalogSpec.hs` (admission projection
  carries the executor effect axis)
- Theory/proof: none
- Tracking: GitHub #304

## Related

- [0010-wire-closed-authority-and-three-layer-stack.md](./0010-wire-closed-authority-and-three-layer-stack.md)
  — this ADR extends closed authority into the executor layer.
- [0005-budgeted-rewrite-admission-and-materialization.md](./0005-budgeted-rewrite-admission-and-materialization.md)
  — owns sub-workflow composition; this ADR delegates to it.
- [../Architecture/05-wire-language.md](../Architecture/05-wire-language.md) — Wire references
  registered executor names under this taxonomy.
- [../Architecture/06-pulse-runtime.md](../Architecture/06-pulse-runtime.md) — executors are
  dispatched here.

## Amendment - Executor Side-Effect Class Lattice and Admission-Projection Digest Identity (2026-06-27, issue #304)

**Status: proposed.** Append-only amendment under GitHub #304. It does not alter the two-kind
decision above; it names a concrete realization of the **side-effect class** metadata axis this
ADR's Obligations already deferred ("Document the cross-cutting metadata axes (determinism, replay
safety, side-effect class) as a distinct reference surface").

### Context

The original decision keeps determinism, replay-safety, and side-effect class as metadata axes that
cross-cut the executor kind, and its Obligations defer documenting the side-effect axis to a later
reference surface. That axis has since materialized in code as a concrete four-valued token, and ADR
0053's admission projection folds it into the projection content digest — yet no ADR governs its
values, its meaning, or the fact that it now participates in executor identity. ADR 0053 names
"effect and side-effect metadata" only generically; the concrete vocabulary and its digest role were
undocumented.

Grounding (code read for this amendment):

- `WireExecutorEffect` (`src/Cortex/Wire/Executor.hs`) is a four-constructor sum declared in the
  order `WireExecutorPure`, `WireExecutorModel`, `WireExecutorHostEffect`, `WireExecutorImpure`. It
  serializes to the tokens `pure` / `model` / `host_effect` / `impure` (`effectText` / `parseEffect`
  in `src/Cortex/Capability/Catalog/AdmissionProjection.hs`; case-folding TOML decode, with the
  `host-effect` / `hosteffect` aliases, in `src/Cortex/Wire/Package/Manifest.hs`).
- The token is a defining field of the admission projection (`apEffect`) and is included verbatim in
  the canonical tuple that `admissionProjectionDigest` hashes
  (`src/Cortex/Capability/Catalog/AdmissionProjection.hs`). Per ADR 0053 the admission-projection
  content digest is interface-level executor identity: it is constrained by the registry invariant
  that any two manifests sharing one `(executor id, projection version)` must agree on the digest,
  and it is a required input to ADR 0053's resume compatibility predicate. The effect class
  therefore participates in run identity, not merely observability.
- The axis is **declared-only** today. `WireExecutorEffect` derives only `(Eq, Show, Generic)` — no
  `Ord` — and no admission-, binding-, or dispatch-time code compares effect classes or rejects on
  them (the effect constructors never reach `src/Cortex/Pulse`). Executors declare their class
  (`executorSpecEffect`, e.g. `WireExecutorPure` for pure executors in
  `src/Cortex/Capability/Executor/Pure.hs`, `WireExecutorHostEffect` for the Std host surface in
  `src/Cortex/Wire/Std.hs`), and the class rides the projection and digest, but no policy keys off
  it yet.

### Decision

Record the executor **side-effect class** axis flagged by this ADR as a fixed four-valued lattice,
ascending in side-effect strength in the order the constructors are declared:

`pure ⊑ model ⊑ host_effect ⊑ impure`

- `pure` — no observable effect; output is a function of declared inputs and config.
- `model` — model-mediated generation (the `ModelExecutor` kind of the original decision):
  stochastic internally, bounded at the contract boundary.
- `host_effect` — a registered, classified host effect (the common `ExternalCallExecutor` case).
- `impure` — unclassified / arbitrary effect; the conservative top of the lattice.

The class is a per-executor **declared** property carried on the admission projection, and its token
is folded verbatim into the admission-projection content digest. Consequently the class is part of
executor interface identity: two manifests sharing one `(executor id, projection version)` must
agree on it, and a change of class changes the digest the resume compatibility predicate consults.
This amendment governs the axis vocabulary and its digest-identity role **only**. The lattice
ordering is **not yet an enforced relation** — there is no `Ord` instance and no
admission/binding/dispatch gate keyed off the class; policy enforcement (refusing a `pure`-declared
executor that binds a host-effecting authority, constraining resume across a class downgrade,
gas/retry rules keyed off effect) remains future work. The single decision here is that the
side-effect class is _identity-bearing and declared_, not yet _enforced_.

### Obligations

- Document the four classes and the `pure ⊑ model ⊑ host_effect ⊑ impure` ordering on the executor
  reference surface this ADR's Obligations already require, alongside the determinism and
  replay-safety axes.
- Before any policy is written against the ordering, decide and record in a follow-up ADR whether
  the lattice is enforced at admission, at binding, or at dispatch, and which error class an
  ordering violation raises — the axis is identity-only today.
- Add a digest regression asserting that a change of `apEffect` changes `admissionProjectionDigest`;
  the current `CatalogSpec` digest-sensitivity case mutates the await-strategy field, so the effect
  token's contribution is structurally present in the canonical tuple but not yet directly tested.

### Traceability

- Feature keys: `capability.effect_class_lattice`
- Public surface: `Cortex.Capability`, `Cortex.Wire`,
  [Wire Executors and Alphabet reference](../Reference/Wire/executors-and-alphabet.md)
- Implementation: `src/Cortex/Wire/Executor.hs` (the `WireExecutorEffect` four-value sum),
  `src/Cortex/Capability/Catalog/AdmissionProjection.hs` (`apEffect`, `effectText`/`parseEffect`,
  and the inclusion of `effectText (apEffect p)` in `admissionProjectionDigest`),
  `src/Cortex/Wire/Package/Manifest.hs` (manifest TOML decode of the effect token)
- Tests: `test/Cortex/Capability/CatalogSpec.hs` (admission-projection JSON round-trip and digest
  determinism/sensitivity; does not yet isolate the effect field)
- Theory/proof: none
- Tracking: GitHub #304
