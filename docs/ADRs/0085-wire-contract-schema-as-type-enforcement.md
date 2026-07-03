---
title: "ADR 0085 — Wire Contract Schema-as-Type Enforcement and the No-Subtyping Ceiling"
description:
  "Makes the currently-dead WireContractSpec schema field an enforced part of the contract type by
  decode-and-validating json/artifact_ref payloads against the contract's declared schema at the
  node boundary, while explicitly rejecting structural subtyping, refinement coercions, and
  row/record polymorphism so the calculus keeps its nominal, first-order, keyed-linear identity."
sidebar:
  label: "0085. Contract schema-as-type"
  order: 85
status: proposed
date: 2026-06-30
superseded_by: null
related:
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0049-wire-fan-phantom-adapter.md
  - docs/ADRs/0052-wire-bounded-indexed-boundary-products.md
  - docs/ADRs/0071-wire-artifact-emission.md
  - docs/ADRs/0079-wire-admission-witness-schema.md
  - docs/ADRs/0080-wire-binder-construction-boundary.md
  - docs/ADRs/0086-wire-scoped-graph-construction-rejection.md
  - docs/ADRs/0087-wire-edge-as-saturation-event.md
  - docs/Architecture/03-formalism-stack.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/Reference/Wire/grammar.md
---

# ADR 0085 — Wire Contract Schema-as-Type Enforcement and the No-Subtyping Ceiling

## Status

Proposed — this is the value-level contract-typing follow-up that ADR 0080 deliberately deferred
(ADR 0080 Q2/Q4, Decision §2, Obligations: "the contract-typing follow-up reconciles
contracts-as-types with ADR 0017 … and is the home for codec/schema work"). It decides one thing —
whether the contract's declared schema becomes enforced type content — and is reconciled to ADR
0017's "contracts are values, not Haskell types."

## Context

A Wire contract is today a **nominal, first-order, thin** classifier. Its identity is a bare name:
`ContractId` is `structure ContractId where name : String deriving DecidableEq`
(`theory/Cortex/Wire/ElaborationIR.lean:54-58`), mirrored as a `newtype ContractId` over `Text`
equal iff the text is equal (`src/Cortex/Wire/Syntax.hs:91-96`). Composition matches port signatures
by **exact equality** — `connect` requires `output.port.signature = input.port.signature` with the
substructural side-conditions `hMatchedFunctional` / `hMatchedInjective`
(`theory/Cortex/Wire/FrontierTyping.lean:284-301`); the Haskell runtime key is the pair
`(label, contract)` matched by exact equality with `linearBoundaryMatches` rejecting 2+ counterparts
(`src/Cortex/Wire/Compile.hs:1783-1787`). There is no subtyping and no structural width/depth.

The runtime contract record carries six fields, but enforcement is uneven. `WireContractSpec`
(`src/Cortex/Wire/Contracts.hs:45-53`) declares `id`, `payloadKind`, `description`, `recordFields`,
`schema :: Maybe Aeson.Value`, and `examples`. Of these, only `payloadKind` (read via
`payloadKindForContract`, `src/Cortex/Wire/NodeBoundary.hs:634-639`, shape-checked at
`src/Cortex/Wire/NodeBoundary.hs:621`) and `recordFields` (`src/Cortex/Wire/Compile.hs:1972,1995`,
for the `*` finite-product adapter) are ever read. At decision time the boundary shape check was
**shallow**: `validateWirePayloadShape` returned `Right ()` unconditionally for `json` and only
checked `Aeson.Object _` for `artifact_ref` (`src/Cortex/Wire/Value.hs:86-103`). The **`schema`
field was dead weight** — declared (`Contracts.hs:50`), serialized (`Contracts.hs:62`), and
otherwise only ever written as `Nothing`; a repository-wide grep found **no reader that validates
against it**. (The enforcement pass recorded under Traceability has since made the schema a
read-and-enforce input.) `description` and `examples` remain serialized-only.

This leaves the largest gap between "tag-with-a-name" and "type-with-content" exactly where it hurts
most: the nominal discipline guarantees the _name_ on a port but says nothing about the _bytes_
behind a `json` or `artifact_ref` value (`artifact_ref` is itself one of the five payload kinds,
`src/Cortex/Wire/Value.hs:33-38`, named as a first-class contract-typed payload by ADR 0071). ADR
0080 audited this and consciously declined to act — "Committing schema validation now pre-empts the
contract-typing follow-up" — leaving the inert `schema` slot as a stable hook so the follow-up
"fills [it] later [without forcing] a boundary redesign." This ADR is that follow-up.

The follow-up is not greenfield. Logos ADR 0015
(`logos/docs/ADRs/0015-contract-backed-tool-schema-projection.md`) already uses
`WireContractSpec.wireContractSpecSchema` as the source of provider-native tool schemas and dispatch
validation. Its `Logos.Workbench.WireContractValidation` helper is production-wired through
`Logos.Workbench.ToolCatalog` and documents a deliberately small candidate Cortex subset: `type`,
`required`, `properties`, `additionalProperties`, `items`, `enum`, string `minLength`/`maxLength`,
and numeric `minimum`/`maximum`. Logos ADR 0015 names the intended upstream home as
`Cortex.Wire.ContractValidation`; this ADR adopts that subset as the starting dialect unless a later
Cortex implementation record explicitly justifies a divergence.

A forcing constraint frames the decision. "Make the contract carry content" can mean two very
different things, and they pull in opposite directions:

1. **Deepen the classifier without a subsumption order** — validate a value against the contract's
   own declared schema, keeping equal-iff-names matching intact.
2. **Add a subsumption order** — structural width/depth subtyping, refinement coercions, or
   row/record polymorphism, so a value of one contract may flow where a _related_ contract is
   expected.

The second forfeits the property that gives the calculus its identity: composition computed from
exact keys (`theory/Cortex/Wire/ElaborationIR.lean:304-310`), decidable and total, with no implicit
copy or conversion (`docs/Reference/Wire/grammar.md:498-499`). The canonical extension philosophy is
explicit that the type system does not grow this way — "the ecosystem grows by registering authority
into a closed alphabet, not by mutating the alphabet"
(`docs/Architecture/03-formalism-stack.md:204-205`). The decision must take the first and bound out
the second.

## Decision

Make the contract's declared schema an **enforced part of the contract type**, and hold the
no-subtyping / first-order ceiling explicitly. Concretely:

1. **Schema-as-type is enforced at the node boundary.** Where a contract declares a non-`Nothing`
   `wireContractSpecSchema` (`src/Cortex/Wire/Contracts.hs:50`), `json` and `artifact_ref` payloads
   are **decoded and validated against that schema** at the same node-boundary site that today runs
   only the shallow shape check (`validateWireValuePayloadShape`,
   `src/Cortex/Wire/NodeBoundary.hs:621`, delegating to `validateWirePayloadShape`,
   `src/Cortex/Wire/Value.hs:86-103`). The initial schema dialect is the Logos-incubated subset
   above. The schema field moves from dead-read to a read-and-enforce input of boundary validation.
   A malformed payload is a typed boundary failure, not a silent pass.

2. **Validation is value-level only, never host-type identity.** Per ADR 0017 ("contracts are
   values, not Haskell types") and ADR 0080's reconciliation obligation, the schema is a serialized
   value (`Maybe Aeson.Value`) decoded and checked at runtime; this introduces **no** `HasContract`/
   phantom-host-type layer. A contract catalog stays portable across process, language, and replay
   logs.

3. **Identity and matching are unchanged.** Schema content does **not** participate in contract
   equality or in port-signature matching. Contracts remain equal iff names are equal
   (`ElaborationIR.lean:54-58`; `Syntax.hs:91-96`); `connect`/`linearBoundaryMatches` keep exact
   `(label, contract)` matching (`FrontierTyping.lean:284-301`; `Compile.hs:1783-1787`). Schema
   deepens the _content_ a classifier vouches for, not the _order_ between classifiers.

4. **Hold the ceiling — reject the subsumption family.** Structural width/depth subtyping,
   refinement-based implicit coercions, and row/record polymorphism (a row variable over the `*`
   finite-product adapter's record fields) are **out of scope and explicitly rejected** for the
   keyed-linear calculus. Width/depth subsumption would break the exact-name composition key that
   makes "composition computed from keys" decidable and total, and refinement coercions would
   reintroduce the implicit conversions the linear discipline forbids (`grammar.md:498-499`;
   `FrontierTyping.lean:284-301`). Input ports keep their bounded **nominal union** (a list of
   contracts, `src/Cortex/Wire/AST.hs:96-118`), each member matched by exact name — a closed union,
   not a subsumption order. The same ceiling governs any **future refinement of the port-matching
   relation** ("edge kinds", multiplicity modes, protocol/session-like state): a refinement may only
   _partition or grade_ an already-typed match between two ports carrying the **same** contract — it
   may reject matches that would otherwise succeed, never manufacture one — and the instant a kind
   would relate two _different_ contract names (e.g. `T` to `Observation<T>`), it has stopped being
   a refinement and become an implicit coercion rejected by this rule; such a transformation is a
   node or a witness, not structure on the match.

5. **Design precedes mechanization.** This ADR fixes the host-boundary content-validation contract;
   the Lean mechanization of it (a universal preservation/soundness statement over the validator) is
   a downstream obligation, not part of this decision. The first concrete deliverable is the Haskell
   enforcement pass plus negative-test guards that a malformed `json`/`artifact_ref` payload is
   rejected.

## Alternatives considered

- **Leave the schema field inert (status quo).** Rejected: it is the single largest unenforced gap
  in the contract type — the `schema`, `description`, and `examples` fields are serialized but never
  read (`Contracts.hs:50-53,62-63`), and the only boundary check is a shallow shape tag that passes
  _all_ `json` and accepts any object for `artifact_ref` (`Value.hs:86-103`). ADR 0080 deferred this
  intentionally on the explicit promise of a follow-up; this is that follow-up. Doing nothing leaves
  the nominal type guaranteeing the port name while saying nothing about the bytes.

- **Adopt structural width/depth subtyping and refinement coercions.** Rejected because it forfeits
  the calculus's identity: subsumption introduces implicit coercion that conflicts with the
  exact-name composition key (`ElaborationIR.lean:304-310`; `Compile.hs:1783-1787`) and the linear
  no-implicit-copy/no-implicit-conversion discipline (`grammar.md:498-499`;
  `FrontierTyping.lean:284-301`). It would relocate Cortex/Wire from a keyed-linear frontier
  calculus to a structural/subtyped one and contradict the closed-alphabet extension philosophy
  (`03-formalism-stack.md:204-205`).

- **Add row/record polymorphism over the `*` finite-product adapter.** Rejected for this decision:
  the record↔ports capability is canon-live but deliberately **static and nominal** — ADR 0049 (a
  static nominal adapter, never polymorphism) was superseded by merge-and-generalize into the live
  monomorphic `*` adapter (ADR 0052; ADR 0049). Adding a row variable is the one extension that
  would genuinely violate the first-order/nominal ceiling; whether to generalize the _live
  monomorphic_ adapter to a polymorphic form is a separate future tension, not this decision, and is
  bounded out here.

- **Encode contracts as Haskell phantom types (`HasContract`/`WireCodec`).** Rejected: ADR 0017
  decided contracts are values, not host types, so the catalog stays portable across process,
  language, and replay; ADR 0080 reaffirmed this. Schema-as-type must stay value-level
  decode-and-validate, which alternative 1 above already provides.

## Consequences

### Positive

- Once implemented, closes the largest "tag vs type" gap honestly: a contract with a declared schema
  will vouch for the _content_ it carries at the node boundary, not just the name on the port.
- Preserves the calculus's identity wholesale — no subsumption order, equal-iff-names matching and
  the linear keyed-port discipline are untouched (decision rules 3 and 4).
- Costs no boundary redesign: the `schema` slot already exists and is serialized
  (`Contracts.hs:50,62`); only the validator was missing, exactly as ADR 0080 Q4 anticipated.
- Gives `artifact_ref` (ADR 0071) and `json` payloads a real content contract instead of a shallow
  object-shape check (`Value.hs:100-103`).
- Records the no-subtyping/no-row-polymorphism ceiling as a deliberate, cited design boundary rather
  than an accident of incompleteness.

### Negative

- Adds a runtime decode-and-validate cost at the node boundary for contracts that declare a schema;
  contracts without a schema keep today's shallow check (no regression, no new guarantee).
- The "validate against `Maybe Aeson.Value`" surface needs a Cortex-owned, versioned schema dialect.
  The upstream validator pins the Logos subset as dialect version 1 (`wireContractDialectVersion`),
  with one recorded divergence: the payload-kind gate accepts `artifact_ref` alongside `json`.
- The guarantee is at the **host boundary only** until mechanized; the Lean typed core
  (`FrontierTyped`) still ranges over names, not schema content (decision rule 5).

### Obligations

- **Discharged — enforcement pass.** `validateWireValuePayloadShape`
  (`src/Cortex/Wire/NodeBoundary.hs`) now consults `wireContractSpecSchema` for `json` and
  `artifact_ref` payloads at all three egress sites, with negative-test guards in
  `test/Cortex/Wire/RuntimeSpec.hs` (malformed payloads rejected with path-bearing errors),
  `test/Cortex/Wire/ContractValidationSpec.hs`, and an end-to-end TOML-manifest case in
  `test/Cortex/Wire/PackageSpec.hs`.
- **Discharged — dialect upstreamed.** The Logos-incubated validator ships as
  `Cortex.Wire.ContractValidation` with one recorded divergence: the payload-kind gate accepts
  `artifact_ref` alongside `json` (the reference object is the payload the schema describes). The
  pinned dialect is documented in `Reference/Wire/contracts-ports-and-matching.md`.
- **Discharged — dialect mechanized.** `theory/Cortex/Wire/ContractValidation.lean` models the
  parsed dialect (`SchemaAccepts`), `ContractValidationCheck.lean` proves the executable checker
  sound **and** complete (`schemaAcceptsCheck_iff`), and generated fixtures under
  `ContractValidation/Emitted/` pin Haskell↔Lean agreement (`native_decide` theorems, a
  byte-equality drift test, and a shared `wireContractDialectVersion`/`dialectVersion` constant).
  Validation of the **resolved durable artifact content** behind an `artifact_ref` (as opposed to
  the reference object) remains open at the artifact-store boundary, as does ingress validation of
  host-supplied inputs; both are named follow-ups, not part of this decision.
- Decide the fate of the equally-inert `description`/`examples` fields (`Contracts.hs:48,51`) —
  enforce, retire, or keep documentary — as a follow-up; this ADR governs `schema` only
  (`validateWireContractExamples` ships as consumer API but is not wired into compilation).

## Traceability

- Feature keys: `wire.contract_schema_enforcement`
- Public surface: `Cortex.Wire`,
  [contracts-ports-and-matching](../Reference/Wire/contracts-ports-and-matching.md)
- Implementation: `src/Cortex/Wire/ContractValidation.hs` (the dialect validator,
  `wireContractDialectVersion`), `src/Cortex/Wire/NodeBoundary.hs` (`validateWireValuePayloadShape`
  consults the registered spec's schema at the egress boundary), `src/Cortex/Wire/Contracts.hs`
  (`WireContractSpec.wireContractSpecSchema`, the enforced hook) — Impl status `implemented`
- Tests: `test/Cortex/Wire/ContractValidationSpec.hs` (dialect semantics + Lean-fixture drift gate),
  `test/Cortex/Wire/RuntimeSpec.hs` (boundary-validation negatives),
  `test/Cortex/Wire/PackageSpec.hs` (TOML-manifest schema end-to-end)
- Theory/proof: `theory/Cortex/Wire/ContractValidation.lean` / `ContractValidationCheck.lean`
  (`SchemaAccepts`, `schemaAcceptsCheck_iff`/`_sound`/`_complete`) plus generated
  `ContractValidation/Emitted/` fixtures; tracked as the contract schema validation row in
  [proof-status](../Reference/proof-status.md)

## Related

- [0017-wire-executor-and-port-catalog-boundary.md](0017-wire-executor-and-port-catalog-boundary.md)
  — contracts are values, not host types (the constraint schema-as-type must respect).
- [0032-wire-boundary-contract-resources.md](0032-wire-boundary-contract-resources.md) — contracts
  as _planning resources_; this ADR is about contract _content validation_, a distinct concern.
- [0049-wire-fan-phantom-adapter.md](0049-wire-fan-phantom-adapter.md) /
  [0052-wire-bounded-indexed-boundary-products.md](0052-wire-bounded-indexed-boundary-products.md) —
  the static nominal record↔ports adapter the row-polymorphism ceiling bounds out.
- [0071-wire-artifact-emission.md](0071-wire-artifact-emission.md) — names `artifact_ref` as a
  first-class payload kind; this ADR gives its content a contract.
- [0079-wire-admission-witness-schema.md](0079-wire-admission-witness-schema.md) — the Haskell→Lean
  _admission-artifact_ exchange schema (a different schema: proof-witness wire format, not contract
  value content).
- [0080-wire-binder-construction-boundary.md](0080-wire-binder-construction-boundary.md) — deferred
  this exact contract-typing/schema follow-up.
- [0086-wire-scoped-graph-construction-rejection.md](0086-wire-scoped-graph-construction-rejection.md)
  — the sibling ceiling: this ADR bounds what a contract match may mean; 0086 bounds how topology
  may be formed (rejecting the graph-block/`saturate` bundle).
- Logos ADR 0015 (`logos/docs/ADRs/0015-contract-backed-tool-schema-projection.md`) — downstream
  prior art: Wire-backed tool schema projection and the candidate `Cortex.Wire.ContractValidation`
  subset this ADR starts from.
- [03-formalism-stack.md](../Architecture/03-formalism-stack.md) — the closed-alphabet,
  grow-by-erasable-forms extension philosophy.
- [Wire/grammar.md](../Reference/Wire/grammar.md) — linear endpoint matching, no implicit fan-out.

## Tracking

- #315 — value-level contract typing and codec/schema work (inherited from ADR 0080); this ADR is
  the design record for the schema-enforcement half.
