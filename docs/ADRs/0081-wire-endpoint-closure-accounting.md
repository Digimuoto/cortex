---
title: "ADR 0081 - Wire Endpoint Closure Accounting and Frontier Inspection"
description:
  "Expose exact-once endpoint-use accounting over Wire's existing linear frontiers without adding
  contract discharge modes or implicit weakening."
sidebar:
  label: "0081. Endpoint closure accounting"
  order: 81
status: proposed
date: 2026-06-28
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/Reference/proof-status.md
  - docs/ADRs/0032-wire-boundary-contract-resources.md
  - docs/ADRs/0033-wire-select-guarded-affine-collapse.md
  - docs/ADRs/0041-wire-cli-command-surface.md
  - docs/ADRs/0047-wire-frontier-linearity-and-precedence.md
  - docs/ADRs/0052-wire-bounded-indexed-boundary-products.md
  - docs/ADRs/0076-wire-cli-proof-fixtures.md
  - docs/ADRs/0079-wire-admission-witness-schema.md
---

# ADR 0081 - Wire Endpoint Closure Accounting and Frontier Inspection

## Status

Proposed - Wire endpoint linearity already exists. ADR 0047 and the compiler already reject implicit
fan-out, implicit fan-in, and repeated graph-reference cloning. The Lean proof track already states
the closed actualized port-use shape. The first Haskell-facing slices are implemented: schema-v4
admission artifacts persist exact endpoint-use witnesses, the hand-maintained Haskell and Lean
validators reject stale witnesses, and `wire frontier` exposes the same accounting vocabulary.

The boundary-port-linear admission rule is now wired through both validators. The Lean proof track
adds the input-side generalization of closed port linearity (`InputPortUse`,
`BoundaryPortUseWitness`, `BoundaryPortLinear`) and proves the persisted endpoint-use witness
induces a boundary-port-linear actualized graph, with closed port linearity recovered as the
empty-boundary corollary (`boundaryPortLinear_empty_iff_closedPortLinear`,
`portUseWitness_closedPortLinear_via_boundary`). The decidable `EndpointUseLinear` rule - every
internal input edge has a symmetric output edge in the declared domain, rejecting fan-out and
fan-in - is a checked conjunct of `ValidatorReady`/`Sound` on the Lean side
(`validatorReady_endpointUseLinear`) and of `wireAdmissionArtifactValidatorReady` on the Haskell
side (`wireAdmissionEndpointUseLinear`). Because the compiler gates validator readiness before
attaching the artifact as circuit metadata and binding it (`admissionArtifactBindsCompiledCircuit`),
every Wire-compiled circuit carries an admission artifact that passed the boundary-port-linear
validation gate.

This ADR remains proposed until the design is accepted and the remaining branch-sensitive questions
and the source-to-actualized terminal-discharge correspondence are closed or explicitly deferred.

## Context

Wire already treats topology endpoints as linear resources. ADR 0047 requires every output endpoint
and every input endpoint to participate in at most one composition step. The Wire references record
the same rule: `=>` connects by `(label, contract)`, rejects one-output-to-many-input fan-out,
rejects many-output-to-one-input fan-in, and leaves unmatched endpoints exposed as carried boundary
obligations. `Cortex.Wire.Compile.linearBoundaryMatches` enforces the fan-out/fan-in side today;
`ensureDisjointGraphDomains` rejects repeated graph-reference cloning. Regression coverage exists
for all three cases.

The Lean proof track already has the closed-port shape this ADR must mirror. `OutputPortUse` has two
proof constructors: `edge` and `terminalDischarge`. `ActualizedPortGraph.ClosedPortLinear` combines
the output rule with the dual input rule: every closed actualized input has exactly one producer,
and every output has exactly one edge consumer or terminal discharge. `proof-status.md` records this
theorem cluster as proven. Schema-v4 admission artifacts now persist the Haskell endpoint-use
witness and the Haskell/Lean validators check exactness for that witness; the deeper
source-to-actualized terminal-discharge correspondence remains open.

The confusing part is terminology. At Wire graph level, a terminating node is simply a node with no
output ports. It is not a separate endpoint-use constructor. If an upstream output connects to that
node's input, the upstream output is consumed by an ordinary edge. If a node consumes one contract
and produces another, such as measurement or release producing an acknowledgment, it is a transform;
its outputs are fresh endpoints that must be accounted for in turn.

That means the original "contract resource discharge modes" framing was too broad. Cortex should not
add a generic contract mode that decides which nodes may consume scarce resources. Node signatures,
executor projections, packages, and downstream domain validators own whether a particular body is a
valid operation over a qubit, token, lease, key, or continuation. Cortex owns the generic topology
facts: which endpoint produced a value, which endpoint consumed it, and which boundary still exposes
an obligation.

## Decision

Wire keeps endpoint linearity universal and contract-independent. No contract mode may permit
implicit output fan-out, implicit input fan-in, repeated graph-reference cloning, hidden
aggregation, or silent endpoint weakening.

Endpoint accounting uses this general partition for open fragments and executable graphs:

```text
input_use = produced_by_edge | host_input | imported_obligation
output_use = consumed_by_edge | terminal_discharge
```

`produced_by_edge` is the ordinary upstream-output edge that satisfies an input endpoint.
`host_input` is a closed executable's top-level host input: the host supplies the input boundary of
the program being executed. `imported_obligation` is an open-boundary input handoff. It is valid for
open fragments and package interfaces because it transfers the input obligation to the caller. A
closed executable graph admits no imported obligations.

`consumed_by_edge` is the ordinary downstream-input edge created by `=>`. It covers both transforms
and terminating nodes. A terminating node is just a node whose declared output port set is empty; it
consumes its inputs by edge and produces no fresh endpoints. A transform node consumes its inputs by
edge and produces its declared outputs, each of which enters the same exact-once accounting.

`terminal_discharge` is the proof-level non-edge output use: an output is accounted for without a
downstream input port instance. The Haskell/CLI projection may refine it by kind:

```text
terminal_discharge.kind = exported_boundary | host_return | proof_boundary_sink
```

`exported_boundary` is valid for open fragments and package interfaces because it transfers the
output obligation to the caller; it does not by itself close a closed executable graph.

`host_return` is the top-level executable handoff: the program returns a final output to the host
rather than connecting it to another Wire input.

`proof_boundary_sink` is the proof-side sink/egress case with no downstream input port instance. It
is not an in-graph sink node. An in-graph sink node reached by `=>` is still `consumed_by_edge`.

A closed executable graph restricts the partition: every input must be `produced_by_edge` or
`host_input`; every output must be either `consumed_by_edge` or a closing `terminal_discharge` kind
such as `host_return` or `proof_boundary_sink`. Open-fragment import/export obligations are not
closed executable uses.

This intentionally revises the initial issue framing. The old `carryable | must-consume` and
`explicit_terminator | restricted_terminator` axes mixed topology closure with domain validation.
This ADR keeps the Cortex substrate claim smaller: expose exact endpoint use and make closure
inspection testable. It does not add contract-level discharge policy.

Branch-local endpoint use behind `select(...)` remains branch-sensitive. A selected branch may
consume endpoints through its own transforms or terminating nodes; inactive alternatives are not
simultaneous consumers. Each arm must still type-check its own frontier use, and the select
admission witness from ADR 0033 must distinguish guarded affine branch-local endpoint uses from
ordinary graph fan-out.

The admission artifact exposes enough port-use evidence for consumers and proof tooling to trust the
substrate's accounting rather than re-derive it from node-level topology. This is an extension of
ADR 0079's witness-exchange contract: schema version 4 records the closure mode, per-input endpoint
use (`produced_by_edge`, `host_input`, or `imported_obligation`), and per-output endpoint use
(`consumed_by_edge` or `terminal_discharge`). This ADR does not require the artifact to prove
domain-specific executor semantics.

### Implemented inspection slice

The first implementation slice is an inspection surface over this endpoint-use evidence. The
`wire frontier` subcommand, shaped under ADR 0041's `wire` command family and ADR 0076's precedent
for non-execution inspection subcommands, runs the normal Wire compile/lowering/admission path and
reports the frontier accounting persisted in the admission artifact:

```text
wire frontier FILE --node NODE
wire frontier FILE --return NAME
wire frontier FILE --closure
wire frontier FILE --open
wire frontier FILE --json
```

For a selected node, the command reports local input ports and their upstream providers, host-input
classification, or imported obligations; local output ports and their downstream consumers or
terminal-discharge classification; open obligations carried at the frontier; and
fan-out/fan-in/repeated-reference conflicts using the same endpoint vocabulary as admission. A node
with zero output ports may be reported as a terminating node, but that is derived from its declared
port shape, not from a separate policy.

`--return NAME` selects a named graph-valued export before inspection, matching
`wire build --return NAME`. `--closure` reports graph-level endpoint accounting for the selected
return graph and is the default projection. `--open` reprojects the same validator-ready admission
artifact as an open fragment for inspection, classifying top-level inputs as imported obligations
and carried outputs as exported boundaries without changing the compiled circuit metadata. `--json`
is the future editor/code-server bridge: an editor can render inline "missing upstream", "open
downstream", "consumed here", "returns to host", and "terminates here" hints from the same data
rather than inventing a second analysis.

This slice exposes the evidence currently available from the compiler and admission artifact. It
does not infer solely from the final `CompiledCircuit` node relation, which has already forgotten
source-expression and port-use detail.

### Not proposed

This ADR does not propose basic port linearity. That is already ADR 0047.

This ADR does not introduce an `unrestricted` topology mode.

This ADR does not add a `discharge_policy`, `resource.mode`, `explicit_terminator`, or
`restricted_terminator` field. If a package wants to expose a node that consumes a resource and
produces no outputs, that is a node signature. If a domain needs to prove that the node body is a
valid operation for that resource, that belongs in executor projection, certificate, package, or
downstream domain validation.

This ADR does not make measurement, release, commit, or error nodes special to Cortex. They are
ordinary Wire nodes with declared input/output ports. A measurement that consumes a qubit and
produces a bit is a transform, not a graph-terminating node.

This ADR does not make `select(...)` branch recovery or guarded affine collapse part of the first
endpoint-accounting implementation. Branch-sensitive resource accounting must use the existing
select/admission-witness machinery from ADR 0033 so inactive alternatives are not treated as
simultaneous runtime consumers.

## Alternatives considered

- **Add contract discharge modes.** Rejected because it mixes substrate endpoint accounting with
  domain-specific executor validity. Cortex should expose declared port use; packages and domains
  decide which operations are meaningful for a resource.
- **Treat terminating nodes as a special endpoint-use constructor.** Rejected because a terminating
  node is just a node with no output ports. Its inputs are consumed by ordinary edges.
- **Allow ordinary contracts to close by implicit weakening.** Rejected because it makes closure
  depend on a hidden structural rule. Outputs are accounted by edge, host return, exported boundary,
  or a proof boundary sink; they are not silently dropped.
- **Leave all endpoint accounting to downstream consumers.** Rejected because provider/consumer,
  import/export, and frontier facts are generic Wire substrate facts already computed during
  compilation and admission.
- **Make quantum qubits a first-class Cortex special case.** Rejected because Cortex should expose a
  generic endpoint-use mechanism. Quantum packages decide which transforms and sinks they provide.

## Consequences

### Positive

- The no-copy/no-drop story is stated precisely: graph-level no-fanout is already universal, and
  endpoint closure is represented by explicit endpoint-use evidence.
- Consumers can rely on Cortex for generic endpoint-use evidence instead of duplicating fan-out and
  frontier walkers.
- The design is useful beyond scarce resources: build pipelines, release gates, host-returning
  programs, authority tokens, leases, continuations, and private-key handles all benefit from the
  same frontier inspection.
- The proposal stays within Wire's existing topology model. It adds inspection and admission
  accounting, not a runtime primitive or topology operator.

### Negative

- The closure boundary must be specified precisely: open library fragments may import/export
  obligations, while closed executable graphs must produce every input and consume or return every
  output.
- Admission artifact changes require ADR 0079 schema and Lean-fixture coordination.
- Domains still need their own executor validity checks. A graph-level endpoint-use witness cannot
  prove that a host effect preserves a resource's physical or authority semantics internally.

### Obligations

- Keep endpoint-use accounting aligned with the existing proof-side partition: `OutputPortUse.edge`
  versus `OutputPortUse.terminalDischarge`, plus the dual input producer rule.
- Define the executable closure boundary where imported/exported open-fragment obligations are no
  longer allowed and every remaining input/output endpoint satisfies `ClosedPortLinear`-style
  exact-once accounting.
- Extend admission diagnostics to distinguish "fan-out/fan-in topology violation" from "open
  frontier obligation" so authors know whether to rename ports, insert an adapter, export/import the
  obligation, return it to host, or add an explicit consuming node.
- Keep the schema-v4 endpoint-use extension aligned across the Haskell
  `wireAdmissionArtifactValidatorReady` gate, Lean `validatorReadyCheck` /
  `validatorReadyCheck_soundness`, and emitted fixtures. Future admission-artifact schema changes
  must bump `wireAdmissionCurrentSchemaVersion` and regenerate fixtures with
  `just wire-lean-fixtures`.
- Expose the same endpoint-use vocabulary through `wire frontier` before building editor-specific
  integration, so the CLI becomes the stable testable surface for frontier analysis.
- Keep endpoint accounting contract-generic. Do not introduce downstream or product-specific
  contract names, issue IDs, or semantics into Cortex code or canon.

## Open questions

- Should host returns be represented only in admission artifacts, or also in the compiled circuit
  metadata consumed by Pulse and downstream packages?
- How should branch-sensitive endpoint obligations across `select(...)` be surfaced without treating
  mutually exclusive alternatives as simultaneous consumers?
- Whether the source language should ever expose a direct `proof_boundary_sink` form, rather than
  keeping it proof/internal-artifact only.

## Traceability

- Feature keys: `wire.endpoint_closure_accounting`
- Public surface: `Cortex.Wire`, `wire frontier`, and the Wire admission artifact schema-v4 JSON
  surface
- Implementation: `src/Cortex/Wire/EndpointUse.hs`, `src/Cortex/Wire/AdmissionArtifact.hs`
  (`wireAdmissionEndpointUseLinear`), `src/Cortex/Wire/Cli/Frontier.hs`,
  `src/Cortex/Wire/Compile.hs`, `src/Cortex/Wire/LeanFixture.hs`, `app/wire/Main.hs`,
  `theory/Cortex/Wire/BoundaryPortLinearity.lean`,
  `theory/Cortex/Wire/AdmissionArtifact/Boundary.lean`,
  `theory/Cortex/Wire/AdmissionArtifact/BoundaryPortUse.lean`,
  `theory/Cortex/Wire/AdmissionArtifact/ValidatorCore.lean`,
  `theory/Cortex/Wire/AdmissionArtifact/ValidatorCoreCheck.lean`, and
  `theory/Cortex/Wire/AdmissionArtifact/ReadyGeneral.lean`
- Tests: `test/Cortex/Wire/Cli/FrontierSpec.hs`, `test/Cortex/Wire/EndpointUseSpec.hs`,
  `test/Cortex/Wire/CompileSpec.hs`, and the emitted Lean admission-artifact fixture corpus
- Theory/proof: existing proven model in [proof-status](../Reference/proof-status.md) for
  `OutputPortUse`, `ActualizedPortGraph.ClosedPortLinear`,
  `actualizedOutputPort_consumed_exactly_once`, and `actualizedInputPort_produced_exactly_once`; the
  boundary generalization `InputPortUse`, `BoundaryPortUseWitness`,
  `ActualizedPortGraph.BoundaryPortLinear`, and its soundness
  `boundaryPortUseWitness_toBoundaryGraph_boundaryPortLinear`, with closed port linearity recovered
  by `boundaryPortLinear_empty_iff_closedPortLinear` and
  `portUseWitness_closedPortLinear_via_boundary`; the schema-v4 bridge
  `AdmissionEndpointUseWitness.artifactBoundaryWitness` and the checked admission rule
  `EndpointUseLinear` (`artifactBoundaryWitness_boundaryPortLinear`,
  `artifactBoundaryWitness_closedPortLinear`, `validatorReady_endpointUseLinear`); schema-v4 witness
  production and Haskell/Lean validator exactness for the persisted endpoint-use witness; deeper
  source-to-actualized terminal-discharge correspondence remains open

## Related

- [Chapter 05 - Wire language](../Architecture/05-wire-language.md)
- [ADR 0032 - Wire Boundary Contracts as Planning Resources](./0032-wire-boundary-contract-resources.md)
- [ADR 0033 - Wire Select Guarded Affine Collapse](./0033-wire-select-guarded-affine-collapse.md)
- [ADR 0041 - Wire CLI Command Surface](./0041-wire-cli-command-surface.md)
- [ADR 0047 - Wire Frontier Linearity and Topology Operator Precedence](./0047-wire-frontier-linearity-and-precedence.md)
- [ADR 0052 - Wire Bounded Indexed Boundary Products](./0052-wire-bounded-indexed-boundary-products.md)
- [ADR 0076 - Wire CLI Proof-Fixture and Grammar-Acceptance Subcommands](./0076-wire-cli-proof-fixtures.md)
- [ADR 0079 - Wire Admission Artifact as Haskell-to-Lean Proof-Witness Exchange Schema](./0079-wire-admission-witness-schema.md)
- [Cortex Proof Status](../Reference/proof-status.md)
- [Wire Contracts, Ports and Matching](../Reference/Wire/contracts-ports-and-matching.md)
- [Wire Grammar Reference](../Reference/Wire/grammar.md)
