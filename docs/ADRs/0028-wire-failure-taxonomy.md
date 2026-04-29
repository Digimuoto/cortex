---
title: "ADR 0028 - Wire Failure Taxonomy"
description:
  "Classifies Wire parse, admission, elaboration, runtime, executor, validation, provider, and Pulse
  infrastructure failures by owning layer and replay semantics."
sidebar:
  label: "0028. Wire failures"
  order: 28
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/07-rewrites-and-materialization.md
  - docs/Reference/Wire/grammar.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0005-budgeted-rewrite-admission-and-materialization.md
  - docs/ADRs/0009-rewrite-provenance-and-topology-integrity.md
  - docs/ADRs/0018-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0023-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0024-wire-node-clause-grammar.md
  - docs/ADRs/0025-corepure-expression-surface.md
  - docs/ADRs/0026-typed-executor-node-interface.md
  - docs/ADRs/0027-configured-executor-values.md
---

# ADR 0028 - Wire Failure Taxonomy

## Status

Proposed - defines the failure vocabulary needed by the next Wire elaborator, CLI diagnostics, and
Pulse durable execution path.

## Context

ADRs 0023 through 0027 introduce several distinct failure sites:

- malformed Wire syntax;
- missing, duplicate, or undeclared output equations;
- unknown contracts or executor ids;
- invalid configured executor values;
- elaboration-time CorePure typed errors;
- runtime CorePure typed errors;
- executor input decode failures;
- executor output validation failures;
- provider and tool failures;
- Pulse infrastructure crashes and resumes.

These failures should not collapse into one generic "execution failed" bucket. They belong to
different layers, have different retry behavior, and mean different things for durable replay.

## Decision

Wire should use a closed failure taxonomy. Each failure has an owning layer and replay class.

| Failure kind                      | Owning layer                           | When raised                                                                        | Replay class                             |
| --------------------------------- | -------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------- |
| `ParseFailure`                    | Parser                                 | Lexing or grammar failure                                                          | Compile-time                             |
| `NameFailure`                     | Static analysis                        | Unbound name, duplicate binding, invalid scope                                     | Compile-time                             |
| `ProjectionFailure`               | Wire admission                         | Unknown contract, executor, port, or projection mismatch                           | Compile-time                             |
| `ConfigFailure`                   | Wire admission / Capability projection | Executor config cannot be statically elaborated or decoded                         | Compile-time                             |
| `TopologyFailure`                 | Wire admission                         | Missing output equation, duplicate equation, invalid composition, invalid boundary | Compile-time                             |
| `ElaborationPureFailure`          | Elaborator                             | Statically reducible CorePure expression fails                                     | Compile-time deterministic               |
| `RuntimePureFailure`              | Pure executor                          | Input-dependent CorePure evaluation fails                                          | Runtime deterministic                    |
| `ExecutorInputDecodeFailure`      | Host binding                           | Wire value cannot decode into executor input type                                  | Runtime deterministic                    |
| `ExecutorProviderFailure`         | Executor binding                       | Provider, tool, network, quota, or external service failure                        | Runtime retryable by policy              |
| `ExecutorOutputValidationFailure` | Executor binding / Wire runtime        | Executor output fails contract, schema, or payload-kind validation                 | Runtime deterministic after retry policy |
| `PulseInfrastructureFailure`      | Pulse                                  | Process crash, storage interruption, worker loss                                   | Operational, resumable                   |

Compile-time failures prevent a circuit from being admitted. Runtime deterministic failures are
materialized as failed stage results and replay the same way given the same admitted circuit and
materialized inputs. Retryable external failures may be retried according to executor policy before
they become a durable executor failure. Pulse infrastructure failures are not Wire semantic
failures; Pulse should resume or retry the interrupted attempt according to its durable protocol.

### Compile-Time Failures

Parser, name, projection, config, topology, and elaboration-pure failures occur before runtime
admission completes. They should be reported by the compiler or CLI with source spans whenever
possible.

Elaboration-time CorePure failures are compile-time failures because ADR 0023 requires maximal
static reduction. A statically known divide-by-zero, bad index, missing field, type mismatch, or
budget exhaustion must not be deferred to runtime.

### Runtime Deterministic Failures

Runtime CorePure failures, host input decode failures, and output validation failures are
deterministic relative to the admitted circuit, materialized inputs, registered binding, and
validation schema.

They may be surfaced as typed executor failures. Whether a graph routes those failures through an
explicit error contract is a topology decision, not a change to the failure taxonomy.

### Retryable Executor Failures

External model, tool, HTTP, artifact, and provider failures may be retryable. The executor binding
owns retry policy and decides which provider failures are retryable.

For model-mediated outputs, a malformed structured response may be retried inside the executor
policy only before a result is materialized. After retries are exhausted, the durable failure is an
`ExecutorOutputValidationFailure`, not an untyped downstream payload.

### Pulse Operational Failures

Pulse crashes, process exits, worker loss, and transient storage interruptions are operational
failures. They should be recorded and resumed by Pulse, but they do not change the Wire program's
semantic result.

## Alternatives considered

- **Use one generic executor failure.** Rejected because compile diagnostics, retry policy, and
  replay semantics need finer distinctions.
- **Treat all runtime failures as retryable.** Rejected because deterministic CorePure, decode, and
  schema failures will not become valid by retrying the same inputs.
- **Expose provider failures as Wire topology errors.** Rejected because provider behavior belongs
  to executor binding and Pulse attempts, not source graph admission.

## Consequences

### Positive

- CLI and editor diagnostics can name the layer that owns a failure.
- Pulse can distinguish deterministic failed results from retryable attempts and operational
  interruption.
- Executor authors get a stable vocabulary for decode, provider, and validation failures.
- Tests can assert the exact phase in which a bad program fails.

### Negative

- The implementation needs structured error ADTs rather than free-form text.
- Some existing tests that only check failure text need to assert failure kind.
- Binding authors must classify provider failures instead of returning opaque exceptions.

### Obligations

- Define failure ADTs in Wire, Capability, and Pulse without circular dependencies.
- Add parser, elaborator, pure evaluator, config, and binding tests for each failure kind.
- Attach source spans to compile-time failures where possible.
- Record runtime failure kind, retry class, and relevant schema/config hashes in Pulse events.
- Keep operational Pulse failures separate from Wire semantic failures.

## Related

- [ADR 0005 - Budgeted Rewrite Admission and Materialization](./0005-budgeted-rewrite-admission-and-materialization.md)
- [ADR 0009 - Rewrite Provenance and Topology Integrity](./0009-rewrite-provenance-and-topology-integrity.md)
- [ADR 0018 - Wire Executor and Port Catalog Boundary](./0018-wire-executor-and-port-catalog-boundary.md)
- [ADR 0023 - Wire Source Elaborates to Circuits](./0023-wire-source-elaborates-to-circuits.md)
- [ADR 0025 - CorePure Expression Surface](./0025-corepure-expression-surface.md)
- [ADR 0026 - Typed Executor Node Interface](./0026-typed-executor-node-interface.md)
- [ADR 0027 - Configured Executor Values](./0027-configured-executor-values.md)
- [Chapter 06 - Pulse Runtime](../Architecture/06-pulse-runtime.md)
