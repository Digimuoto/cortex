---
title: "ADR 0029 - Typed LLM Output Binding"
description:
  "Defines the Capability-layer contract for model executors that produce typed Wire outputs through
  schema-constrained generation and validation."
sidebar:
  label: "0029. Typed LLM output"
  order: 29
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Architecture/09-nous-reasoning-library.md
  - docs/Reference/Wire/contracts-ports-and-matching.md
  - docs/ADRs/0014-executor-taxonomy-model-vs-external-call.md
  - docs/ADRs/0018-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0021-executor-registration-and-binding.md
  - docs/ADRs/0026-typed-executor-node-interface.md
  - docs/ADRs/0028-wire-failure-taxonomy.md
---

# ADR 0029 - Typed LLM Output Binding

## Status

Proposed - specifies the binding-layer contract behind ADR 0026's claim that LLM executors emit
typed values or typed failures.

## Context

ADR 0026 requires LLM-backed executors to have the same external shape as other executor nodes:
typed input ports, typed output ports, and typed failures on contract violation. It correctly leaves
provider mechanics outside Wire semantics, but the binding-layer contract still needs to be stated.

Without that contract, "strict JSON mode or equivalent" is too vague for implementers. The compiler
needs to know what a registered LLM projection promises, and Pulse needs durable provenance for the
schema and validation mode used on each attempt.

## Decision

Typed LLM output is a Capability-layer binding guarantee. A model executor binding must declare, for
each output port:

- the Wire contract id and payload kind;
- the schema source used for structural validation, when the payload kind requires one;
- the provider structured-output mechanism or equivalent local validation path;
- retry policy for provider and malformed-output attempts;
- provenance fields needed to replay and audit validation.

Wire compilation checks the executor projection: port labels, contract ids, payload kinds, and
whether the projection advertises a typed-output guarantee compatible with the declared output
ports. Wire does not know provider APIs, prompt formats, credentials, model names, or host codecs.

### Schema Source

The primary schema source is the contract registry from ADR 0018. A `WireContractSpec` may carry a
schema for JSON-shaped payloads. The LLM binding compiles that schema into the provider's structured
output request when the provider supports one.

If the provider cannot enforce the schema directly, the binding may still be admissible only when it
performs local decoding and validation before materializing output. That path must advertise a
`DecodeValidated` guarantee rather than a provider-enforced guarantee.

For scalar text or markdown outputs, the payload-kind validator is sufficient unless the contract
spec adds a schema or content validator. For structured JSON outputs, a missing schema is a binding
admission failure unless the executor projection explicitly declares a narrower built-in validator.

### Validation Modes

LLM bindings should advertise one of these validation modes:

- `ProviderEnforcedSchema` - the provider receives the contract schema or an equivalent schema and
  is expected to return matching structured output;
- `DecodeValidated` - the provider may return text or JSON, but the binding decodes and validates
  locally before materialization;
- `PayloadKindOnly` - the binding validates only the declared payload kind.

`PayloadKindOnly` is not sufficient for structured JSON contracts unless the contract has no schema
and the executor projection deliberately promises only coarse payload validation.

Prompt-only "please return JSON" conventions are not a typed-output guarantee.

### Failure Handling

Provider, network, quota, timeout, and tool failures are `ExecutorProviderFailure` values under ADR
0028 and may be retried according to binding policy.

Malformed or schema-invalid model responses may be retried inside the executor binding before any
output is materialized. If retries are exhausted, the stage fails with
`ExecutorOutputValidationFailure`. The invalid response must not be passed downstream as a weakly
typed blob.

Input decode failures before the model call are `ExecutorInputDecodeFailure` and are not provider
retries.

### Provenance

Each model attempt should record enough validation provenance to audit the typed-output guarantee:

- executor id and binding id;
- model/provider policy id or concrete model id according to host policy;
- output contract id and payload kind;
- contract schema hash, if present;
- provider request schema hash, if different;
- validation mode;
- config hash;
- attempt count and retry outcome.

Provider-specific request and response details may be redacted by host policy, but the schema and
validation facts must remain visible to the substrate.

## Alternatives considered

- **Make JSON schema enforcement a Wire language feature.** Rejected because provider APIs, retries,
  credentials, and host codecs belong to Capability binding.
- **Accept prompt-only JSON conventions.** Rejected because prompt text is not a typed-output
  guarantee and cannot support stable downstream contracts.
- **Let downstream pure nodes parse model blobs.** Rejected because contract failure would move away
  from the executor boundary and reintroduce untyped prompt structure.
- **Require provider-enforced schema for every model.** Rejected because local decode-validation can
  provide the same binding guarantee for providers without native structured-output support.

## Consequences

### Positive

- LLM executors satisfy ADR 0026 without making Wire provider-aware.
- Contract schemas from ADR 0018 become the canonical source for structured model output.
- Retryable provider failures and deterministic validation failures are separated.
- Pulse records enough provenance to audit typed model output.

### Negative

- LLM bindings need structured validation code and schema hashing.
- Some existing prompt-only model workflows become inadmissible as typed-output executors.
- Contracts without schemas may need schema work before they can support structured model output.

### Obligations

- Extend Capability executor specs with validation mode, schema source, and retry metadata.
- Add binding tests for provider failure, malformed output retry, and final validation failure.
- Ensure Wire strict projection mode can reject incompatible typed-output declarations.
- Record schema/config/validation provenance in Pulse events.
- Update LLM executor docs to ban prompt-only JSON as a typed-output guarantee.

## Related

- [ADR 0014 - Model vs External Call](./0014-executor-taxonomy-model-vs-external-call.md)
- [ADR 0018 - Wire Executor and Port Catalog Boundary](./0018-wire-executor-and-port-catalog-boundary.md)
- [ADR 0021 - Executor Registration and Binding](./0021-executor-registration-and-binding.md)
- [ADR 0026 - Typed Executor Node Interface](./0026-typed-executor-node-interface.md)
- [ADR 0028 - Wire Failure Taxonomy](./0028-wire-failure-taxonomy.md)
- [Wire Contracts, Ports, and Matching Reference](../Reference/Wire/contracts-ports-and-matching.md)
