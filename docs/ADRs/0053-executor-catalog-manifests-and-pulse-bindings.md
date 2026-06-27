---
title: "ADR 0053 - Executor Catalog Manifests and Pulse Runtime Bindings"
description:
  "Defines executor catalog entries as the shared boundary between Wire admission, build-time
  packaging, host runtime binding, and Pulse dispatch."
sidebar:
  label: "0053. Executor catalog bindings"
  order: 53
status: proposed
date: 2026-05-12
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Architecture/06-pulse-runtime.md
  - docs/Reference/Wire/executors-and-alphabet.md
  - docs/Reference/Wire/configured-executors-and-execution-boundary.md
  - docs/Reference/Pulse/host-actions.md
  - docs/Reference/Pulse/types.md
  - docs/ADRs/0003-pulse-service-and-host-action-boundary.md
  - docs/ADRs/0017-wire-executor-and-port-catalog-boundary.md
  - docs/ADRs/0019-executor-registration-and-binding.md
  - docs/ADRs/0024-typed-executor-node-interface.md
  - docs/ADRs/0025-configured-executor-values.md
  - docs/ADRs/0039-wire-node-boundary-transform-normal-form.md
  - docs/ADRs/0044-wire-namespace-use-imports.md
  - docs/ADRs/0054-downstream-wire-packages-and-host-bindings.md
  - docs/ADRs/0058-pulse-atomic-suspend-settlement.md
  - docs/ADRs/0059-durable-external-call-frontiers-on-pulse.md
---

# ADR 0053 - Executor Catalog Manifests and Pulse Runtime Bindings

## Status

Proposed - refines ADR 0019's executor-registration boundary with build-manifest, identity, and
durable-binding detail for native executors. Defines what is canonical at each layer and what is
left to per-language packaging.

## Context

Wire source names executor authority with forms such as `@review.analyze { ... }`, but source files
do not grant runnable authority. ADR 0019 already separates Wire projections, Capability authority,
and Pulse execution. ADR 0024 requires executor nodes to expose typed input and output ports, and
ADR 0025 keeps configured executor values inert.

That split leaves three practical problems.

First, Wire cannot be completely ignorant of executors. To statically admit a node, the compiler
needs the executor's public signature: config shape, typed input projection, typed output
projection, effect metadata, and declared authority requirements. Without that projection, Wire can
parse an executor id but cannot typecheck its config or declared port boundary.

Second, Pulse needs a durable executable identity for each admitted stage. Pulse owns scheduling,
retries, checkpointing, resume, cancellation, stage logs, and provenance. It does not own domain
semantics, provider policy, application codecs, native-language build systems, or executor handle
injection. A Rust executor, for example, should be buildable and packageable with Nix-like
provenance, but `runRustExecutor` or similar language-specific syntax in Wire would make Rust a Wire
primitive and would smuggle build authority into source.

Third, the executor ABI question divides into two distinct surfaces that earlier drafts conflated.
There is a _Pulse-visible_ surface — what every bound stage looks like from the runtime — and there
is an _executor-package authoring_ surface — what an executor author writes in Rust, WASM, or a
subprocess protocol. Cortex canon must define the first and must not lock in the second. Conflating
them pushes handle injection, trait objects, and per-language calling conventions into ADR canon,
which both over-constrains executor packaging and creates the false impression that injected handles
are an enforceable capability boundary.

## Decision

Executors are registered through shared executor catalog entries. A catalog entry is the bridge
between Wire admission, build-time packaging, Capability/host binding, and Pulse dispatch. Wire
source references only the catalog executor id; it does not register new executors and does not name
native build mechanisms.

Executor catalog work is split into three related artifacts:

- an **admission projection** consumed by Wire and Capability for static checking;
- an **executor manifest** consumed by build tooling and host runtime binding;
- a **runtime binding record** consumed by Circuit emission and Pulse dispatch.

The admission projection and executor manifest may exist without runnable authority. Only the host
runtime binding step can mint the runtime binding record that a runnable Circuit carries.

### Admission projection

The admission projection is inert data consumed by Wire and Capability. It describes the executor's
public surface as seen by source code and by the binder:

- executor id, such as `review.analyze`;
- admission projection version;
- input-port projection with labels, contract ids, and arity expectations;
- output-port projection with labels, contract ids, and validation expectations;
- config schema (a schema reference or content digest, not the config itself);
- declared **requirement slots**: capability kind, local binding name, optional config selector
  path, required permission class, expected replay/effect class per slot;
- declared **replay class** the executor requires (see _Replay and side effects_);
- declared **await strategy** (`synchronous` | `submit_park_resume`) the executor requires;
- declared **minimum isolation expectation** the package requests (in-process, WASM sandbox,
  subprocess sandbox, container, brokered process);
- effect and side-effect metadata available at admission time;
- optional default timeout, retry, memory, and validation policies.

Wire compiles against this projection. A configured executor value stores the executor id plus
static config data and remains non-runnable until a host runtime binding pack mints a binding
record.

The registry invariant is:

> `(executor id, admission projection version)` uniquely identifies admission projection content.

Two manifests claiming the same pair must agree on schemas, ports, contracts, requirement slots,
replay class, await strategy, isolation expectation, and effect declarations. Implementation
artifacts may differ under one projection; the projection itself must not.

### Executor manifest

The executor manifest is produced by an executor package and consumed by the build system plus host
runtime binding. Pulse does not consume native executor manifests directly.

- manifest schema version;
- manifest content address and signature (where applicable);
- executor id;
- admission projection version and admission projection content digest;
- implementation artifact reference (Nix store path, container image, WASM module, archive);
- implementation artifact content digest;
- **ABI kind** identifying the calling convention (for example `rust-dylib-v1`, `wasm-component-v1`,
  `subprocess-jsonl-v1`, `host-action-v1`);
- **ABI version** for that kind;
- declared **ABI driver identity** the manifest expects (driver name; the driver implementation
  digest is recorded only in the binding record);
- build provenance: source hash, lockfile hash, toolchain version, feature flags, declared runtime
  dependencies, Nix derivation/output hash;
- host permission and capability requirements;
- minimum isolation expectation (may refine, but not weaken, the projection's expectation);
- output validation and commit policy requested by the executor package.

The manifest is inert. It does not grant runnable authority by itself. For Rust executors, the build
tool may compile the crate, generate an executor manifest, load the manifest's admission projection
into the catalog, and then ask host runtime binding to accept the manifest as a runnable
implementation. This is integrated compilation at the build/catalog layer, not a new Wire source
form.

### Identity and manifest selection

The admitted Circuit carries the _interface-level_ executor identity:

- executor id;
- admission projection version;
- admission projection content digest;
- canonical admitted config (durable in the Circuit node);
- admitted config digest (see _Config digest_);
- typed input/output port references and contract ids;
- declared requirement selectors derived from admitted config;
- declared replay class, await strategy, and effect metadata.

The runtime binding record carries the _implementation-level_ selection:

- runtime binding id and version;
- Pulse `StageActionId`;
- a reference to the Circuit task node whose canonical admitted config this binding belongs to;
- manifest content address (the manifest that was actually selected);
- implementation artifact content digest;
- ABI kind, ABI version, and ABI driver digest;
- binding pack identity and version (so the compatibility predicate is itself auditable);
- resolved authority fingerprints (see _Authority model_);
- isolation policy digest (the _applied_ profile, which must satisfy the manifest's minimum);
- runtime policy digest (timeout, retry, replay, commit, output validation);
- accepted replay class (the class the binding decided to honor; must be at least as strict as the
  projection's declared class);
- accepted await strategy (the durable completion/suspend shape this binding decided to honor);
- compatibility digest summarizing the above;
- reference to the compatibility predicate (binding pack version + predicate identity).

Manifest selection must be explicit. A binding pack ships a catalog rule of the form:

```text
(executor id, admission projection version)               -> manifest content address
(executor id, admission projection version, selector)     -> manifest content address
```

The first time a stage is bound, the chosen manifest content address is frozen into the runtime
binding record. The binder may not silently switch manifests on later runs.

If a binding pack catalog leaves implementation choice open (for example by selector), the recorded
manifest content address still pins the choice for that binding record.

### Canonical Pulse-visible ABI

The canonical Pulse-visible executor ABI is:

```text
StageAction : (AttemptContext, InputEnvelopeSet) -> Outcome<OutputEnvelopeSet>
```

- the _semantic_ surface is `InputEnvelopeSet -> Outcome<OutputEnvelopeSet>`;
- the _dispatch_ surface adds an `AttemptContext` carrying attempt id, cancellation token, deadline,
  lineage and checkpoint references, retry number, log and event sinks, and any
  deterministic-clock/randomness policy.

Cortex canon does **not** define a language-level executor calling convention. Config, resolved
authority handles, tool implementations, model clients, memory stores, credentials, and per-language
trait or struct shapes are not call arguments at the Pulse boundary. They are bound into the opaque
`StageAction` by the host runtime binding pack at compose time. Pulse never sees them.

Per-language calling conventions — `rust-dylib-v1`, `wasm-component-v1`, `subprocess-jsonl-v1`,
`host-action-v1` — live in executor reference documentation, not in this ADR. Each driver decides
its own author-facing shape and its own injection mechanism for resolved authorities.

In particular, `rust-dylib-v1` is **not** a security boundary. An in-process dylib can perform any
action the host process can perform unless additional sandboxing exists. A nice author-facing Rust
SDK (`struct ReviewAnalyze { model: Arc<dyn ModelClient> }`) is acceptable as SDK ergonomics; the
stable dylib boundary itself should be an `extern "C"` shim with opaque pointers, versioned vtables,
and canonical envelope serialization. The SDK can hide the shim with macros. Trust enforcement comes
from the manifest's isolation expectation and the host's isolation policy, not from injected handle
types.

Output writers and output egress are _driver-level_ mechanics, not part of the canonical ABI. The
host/Pulse boundary validates candidate outputs against compiled port contracts before commit. The
executor produces candidate outputs through whatever shape its driver chooses; the boundary, not the
executor, decides whether they pass.

### Authority model

The authority surface has three distinct layers. Earlier drafts conflated them under "handles."

1. **Declared requirement slots** live on the admission projection. They describe a capability slot
   (model provider, named tool, memory store, artifact store, host permission), a local binding
   name, an optional config selector path, and the permission/replay class the slot expects.

2. **Config-derived selectors** live on the admitted config. They are host-local strings
   (`model = "gpt-5.4"`, `tools = ["web_search"]`, `memory = "reviewer"`) that the projection's
   schema permits. Wire records them durably without resolving them.

3. **Resolved authority fingerprints** live on the runtime binding record. They identify what the
   binder chose for each declared slot, without leaking secret values:

   ```text
   resolved_authorities:
     model:
       kind: model-provider
       slot: model
       selector: gpt-5.4
       provider: anthropic
       resolution_policy: frozen-at-bind | snapshot-pinned | drift-allowed
       snapshot_id: <if frozen or pinned>
       endpoint_policy_digest: ...
       credential_ref: secret://<store>/<name>@<version>
       compatibility_fingerprint: ...
     search:
       kind: tool
       slot: search
       selector: web_search
       provider: tavily
       tool_contract_version: ...
       policy_digest: ...
     memory:
       kind: memory-store
       slot: reviewer_memory
       selector: reviewer
       store_kind: postgres
       logical_store_id: reviewer
       commit_policy_digest: ...
   ```

   Raw secret values must not appear in any fingerprint or digest. A versioned secret reference
   (`secret://store/name@version`) is acceptable when replay or audit needs it.

Tool names like `"web_search"` are host-local selectors, not globally meaningful identities. The
binding record captures what each selector resolved to, so two hosts running the same Circuit with
different `web_search` providers produce distinguishable binding records.

### Config digest

The admitted config digest is computed over the _canonical post-validation_ config, not the raw
source text:

```text
admitted_config_digest =
  hash(
    executor_id,
    admission_projection_version,
    admission_projection_content_digest,
    config_schema_digest,
    canonical_admitted_config
  )
```

Canonicalization applies defaults from the schema, normalizes map ordering, normalizes enum and
string forms, and removes formatting noise. The canonical admitted config itself is durable on the
Circuit task node; the runtime binding record references the node by id rather than carrying a
second copy.

### Replay and side effects

The admission projection declares the replay class the executor requires. The binder records the
accepted replay class in the binding record. The accepted class must be at least as strict as the
declared class.

Replay classes:

- `deterministic` — identical inputs produce identical outputs; safe to re-run on resume;
- `replay_by_rerun` — re-running on resume is acceptable but outputs may differ in non-semantic
  ways; downstream consumers must tolerate this;
- `replay_by_reusing_recorded_outputs` — committed outputs from a prior attempt must be reused on
  resume; the executor must not re-run;
- `idempotent_with_key` — re-running is safe if the executor uses the attempt-supplied idempotency
  key as the stable Pulse-side dedup anchor for external effects;
- `exactly_once_via_commit_log` — the binding layer maintains an external commit log; re-runs check
  the log before acting;
- `non_replayable` — re-running is unsafe; resume must surface a policy error unless explicitly
  overridden by host policy.

Pulse-visible output envelopes are buffered per attempt and committed only on success. Failure
discards uncommitted envelopes.

External side effects through resolved authorities are _not_ automatically rolled back. The binding
layer must classify each authority handle:

- transactional handles must provide explicit commit/abort semantics that the StageAction invokes;
- non-transactional handles must be declared non-rollbackable and combined with a compatible replay
  class;
- handles that need idempotency must receive the attempt's Pulse-side idempotency key through the
  driver's authority-injection mechanism. Provider submit/dedup tokens are driver-owned: they may
  incorporate request parameters beyond the Pulse key, but their derivation must be deterministic
  and byte-for-byte stable across crash re-entry.

### Await strategy

The admission projection declares the await strategy an executor requires, and the runtime binding
record stores the accepted strategy the host binding pack commits to for the bound stage. Await
strategy is not an executor category: an `ExternalCallExecutor`, `ModelExecutor`, or other bound
stage may use either shape if its replay/effect policy supports it.

Initial strategies:

- `synchronous` — the `StageAction` completes or fails in the current attempt and does not park on a
  durable signal.
- `submit_park_resume` — the `StageAction` may submit external work, persist attempt metadata
  through Pulse-owned durable attempt state (whose provider-specific fields the binding writes as
  opaque data), return `StageSuspend`, and later re-enter after a trusted wake via ADR 0058's atomic
  suspend settlement. ADR 0059 defines the external-call specialization: the wake signal is
  `external-call:*`, ordinary signal delivery rejects that namespace, and the delivered signal
  re-arms the waiting node rather than becoming node output.

Pulse does not infer the strategy from the executor id or backend class. It dispatches the opaque
`StageAction`, records the accepted strategy for audit/resume, and rejects or refuses resume when a
binding pack attempts to re-enter a stage under an incompatible strategy.

### Resume compatibility predicate

Resume is not a byte-equality check on the compatibility digest. A binding pack ships a
**compatibility predicate** whose identity and version live on the runtime binding record. The
predicate decides whether `state_old → state_new` is admissible for re-entry.

The predicate must consider at least:

- executor id, admission projection version, admission projection content digest;
- admitted config digest;
- manifest content address;
- implementation artifact content digest, ABI kind, ABI version, ABI driver digest;
- resolved authority compatibility fingerprints;
- isolation policy digest;
- runtime policy digest (timeout/retry/replay/commit/output validation);
- accepted replay class;
- accepted await strategy;
- output contract validator identities.

Typical permissive transitions (credential rotation within the same logical authority, store path
relocation, behavior-preserving driver patch, refreshed secret version) should be admissible.
Typical blocking transitions (artifact changed unexpectedly, model alias resolved to a different
snapshot, contract validator changed, isolation policy weakened, permission flipped) must not be
admissible without explicit policy override.

Cortex canon names the inputs the predicate must consider. The predicate body is host code, attached
to a versioned binding pack, not Cortex canon.

### Pulse dispatch and Pulse ignorance

Pulse executes already-bound stage actions. It dispatches each stage through the opaque
`StageAction` carried on the `StageDefinition`. Pulse:

- does not read executor manifests;
- does not load implementation artifacts;
- does not resolve authority requirements;
- does not interpret ABI kinds beyond identity comparison;
- does not validate isolation policy;
- does not instantiate executors;
- does not pass handles, tools, model clients, or secrets to anything.

Pulse records the binding id, action id, ABI kind/version, replay class, await strategy, attempt
lifecycle, checkpoint lineage, and committed output envelopes in its normal runtime state. On resume
Pulse loads the durable runtime binding record, asks the binder to reconstruct a `StageAction`,
evaluates the binding pack's compatibility predicate, and either re-enters the stage or refuses.

### Error model

Failures along the lifecycle are first-class and distinct:

- `AdmissionError` — Wire compile-time failure (missing projection, schema mismatch, contract id
  mismatch, registry conflict);
- `BindingError` — host cannot construct a `StageAction` (manifest not found, signature invalid, ABI
  driver unavailable, requirement unresolved, isolation policy refused, replay class downgrade
  rejected);
- `DispatchError` — Pulse/driver could not invoke a constructed `StageAction` (artifact load
  failure, attempt context construction failure);
- `ExecutorError` — the executor ran and returned failure;
- `ValidationError` — executor returned candidate outputs that failed contract validation at the
  host/Pulse boundary;
- `PolicyError` — replay, commit, permission, or isolation policy violation surfaced at attempt
  open, commit, or resume time.

Observability, retry decisions, and resume decisions must distinguish these classes.

### Compile, bind, run summary

An implementation tool such as `foldw build` therefore performs:

1. build native executor packages and emit signed or content-addressed executor manifests;
2. compose the executor admission catalog and contract registry from Wire packages;
3. compile Wire against the admission projections, emitting an admitted Circuit whose nodes carry
   interface-level identity (admitted config, port refs, declared requirements);
4. compose host runtime binding packs and resolve manifest selection, authority requirements, and
   isolation policy per node;
5. mint runtime binding records and construct opaque `StageAction`s;
6. emit a `StagePlan` of `StageDefinition`s for Pulse, each carrying a runtime binding record and a
   `StageAction`.

The Wire program is unchanged:

```wire
node analyze
  <- evidence: EvidenceSet;
  -> analysis: AnalysisRecord;
  = @review.analyze { model = "gpt-5.4"; tools = ["web_search"]; } (evidence);
```

The fact that `review.analyze` is implemented in Rust, Haskell, WASM, a model provider adapter, or a
host-action endpoint is catalog metadata.

### Boundary rules

- Wire typechecks executor references against catalog admission projections, not executor source
  code.
- Wire source cannot define, compile, or register runtime executors.
- Config is static Wire data validated before graph admission, canonicalized before digest.
- The canonical admitted config lives on the Circuit task node, not on the binding record.
- Output validation against port contracts happens at the host/Pulse boundary before commit, not
  inside the executor.
- Executors receive declared input values; everything else (config, resolved authorities, output
  envelope mechanics, attempt context) is driver-level and outside Cortex canon.
- Pulse owns durable execution mechanics and dispatches opaque `StageAction`s. It does not own
  domain semantics, native build systems, executor manifest admission, authority resolution, or
  isolation policy.
- Host runtime binding packs own provider policy, credentials, native executables, application
  codecs, host-action endpoints, isolation policy decisions, and the compatibility predicate.
- In-process dylib execution is not a security boundary; trust enforcement comes from isolation
  policy, not from injected handle types.

## Alternatives considered

- **Make native executor calls Wire syntax** - rejected because forms such as `runRustExecutor(...)`
  make a host implementation language part of Wire semantics and bypass the closed executor
  alphabet.
- **Let Pulse own executor registration** - rejected because Pulse would become the owner of domain
  semantics, provider policy, native build artifacts, application codecs, and isolation policy,
  conflicting with ADR 0003 and ADR 0019.
- **Give executors downstream edges** - rejected because executor behavior would depend on graph
  context instead of the declared typed node boundary. Downstream routing remains topology.
- **Canonicalize a per-language ABI in Cortex (`fn run(inputs, config, outputs, handles)`)** -
  rejected because it over-constrains executor packaging, fixes unstable Rust internals into Cortex
  canon, and creates the false impression that injected handles enforce capability boundaries.
  Per-language calling conventions belong in executor reference docs.
- **Treat injected handles as a capability-security mechanism** - rejected because in-process dylib
  execution can bypass any in-memory handle discipline. Isolation policy and ABI-kind selection are
  the enforcement layer; handles are SDK ergonomics.
- **Use byte equality on the compatibility digest for resume** - rejected because credential
  rotation, store relocation, and behavior-preserving driver patches must be admissible without
  invalidating durable bindings. Resume needs an explicit predicate.

## Consequences

### Positive

- Wire can statically validate executor config, port declarations, and requirement slots without
  knowing executor implementation semantics.
- The Pulse-visible ABI stays minimal (`inputs -> outputs`), so Pulse does not learn about
  languages, tools, or authorities.
- Native executors can participate in integrated builds through manifests and content-addressed
  artifacts.
- Resume is a versioned host predicate, not a brittle digest comparison.
- Implementation identity (manifest content address, artifact digest, ABI driver digest) is
  separable from interface identity (admission projection digest, admitted config digest).
- Authority fingerprints make audit and resume meaningful without leaking secrets.
- Per-language ABI drivers can evolve independently of ADR canon.

### Negative

- The catalog and binding record become real versioned artifacts with several digests and
  fingerprints.
- Build tooling must compose executor manifests, resolve authorities, and pin manifest selection
  before a runnable bundle can be emitted.
- Per-language ABI drivers (`rust-dylib-v1`, `wasm-component-v1`, `subprocess-jsonl-v1`,
  `host-action-v1`) become their own reference surfaces.
- Hosts must distinguish projection-only catalog entries from entries with runnable authority and
  must own their compatibility predicate.

### Obligations

- Define concrete Haskell data types for admission projections (including declared requirement
  slots, declared replay class, declared await strategy, and minimum isolation expectation),
  executor manifests, runtime binding records, resolved authority fingerprints, and ABI kind/version
  constants.
- Define the manifest selection rule on host runtime binding packs and the registry conflict
  invariant for `(executor id, admission projection version)`.
- Define the canonical config digest function and place canonical admitted config durably on the
  Circuit task node.
- Define the compatibility predicate interface, its versioning, and the canonical input list.
- Define attempt-scoped output buffering and host/Pulse boundary output validation; classify
  external side effects through declared replay classes and per-handle commit/abort semantics.
- Define await-strategy constants, persist the accepted strategy in runtime binding records, and
  make the resume compatibility predicate reject incompatible strategy changes unless a binding pack
  provides an explicit migration.
- Define the error hierarchy
  (`AdmissionError | BindingError | DispatchError | ExecutorError | ValidationError | PolicyError`)
  and surface it through Pulse runtime state.
- Document per-language ABI drivers in `docs/Reference/Executors/` rather than in this ADR.
- Document that `rust-dylib-v1` is not a security boundary and that isolation policy is the
  enforcement layer.

## Traceability

- Feature keys: `capability.executor_catalog`
- Public surface: `Cortex.Capability` (the `Cortex.Capability.Catalog.*` and
  `Cortex.Capability.BindingPack` surface),
  [Wire Executors and Alphabet reference](../Reference/Wire/executors-and-alphabet.md),
  [Pulse Types reference](../Reference/Pulse/types.md)
- Implementation: `src/Cortex/Capability/Catalog/AdmissionProjection.hs` (`AdmissionProjection`,
  `RequirementSlot`, `admissionProjectionDigest`),
  `src/Cortex/Capability/Catalog/ExecutorManifest.hs` (`ExecutorManifest`, `AbiKind`,
  `ContentAddress`), `src/Cortex/Capability/Catalog/RuntimeBindingRecord.hs`
  (`RuntimeBindingRecord`, `ResolvedAuthorityFingerprint`),
  `src/Cortex/Capability/Catalog/AwaitStrategy.hs` (`ReplayClass`, `AwaitStrategy`,
  `IsolationExpectation`), `src/Cortex/Capability/BindingPack.hs` (`HostBindingPack`)
- Tests: `test/Cortex/Capability/CatalogSpec.hs` (admission-projection and runtime-binding-record
  JSON round-trips plus `admissionProjectionDigest` determinism and field-sensitivity),
  `test/Cortex/Capability/BindingPack/BraketSpec.hs` (a concrete host binding pack minting runtime
  binding records)
- Theory/proof: none
- Tracking: GitHub #304

## Related

- [ADR 0003 - Pulse Service and Host-Action Boundary](./0003-pulse-service-and-host-action-boundary.md)
- [ADR 0017 - Wire Executor and Port Catalog Boundary](./0017-wire-executor-and-port-catalog-boundary.md)
- [ADR 0019 - Executor Registration and Binding](./0019-executor-registration-and-binding.md)
- [ADR 0024 - Typed Executor Node Interface](./0024-typed-executor-node-interface.md)
- [ADR 0025 - Configured Executor Values](./0025-configured-executor-values.md)
- [ADR 0039 - Wire Node Boundary Transform Normal Form](./0039-wire-node-boundary-transform-normal-form.md)
- [ADR 0044 - Wire Namespace Use Imports](./0044-wire-namespace-use-imports.md)
- [ADR 0054 - Downstream Wire Packages and Host Runtime Bindings](./0054-downstream-wire-packages-and-host-bindings.md)
- [ADR 0059 - Durable External-Call Frontiers on Pulse](./0059-durable-external-call-frontiers-on-pulse.md)
- [Wire Executors and Alphabet Reference](../Reference/Wire/executors-and-alphabet.md)
- [Pulse Host-Action Contract](../Reference/Pulse/host-actions.md)
- [Pulse Types Reference](../Reference/Pulse/types.md)

## Amendment - Effect-class digest identity (cross-reference) (2026-06-27, issue #304)

**Status: proposed. Pointer only — no decision is made or changed here.** The admission projection's
`effect` field (the four-valued `WireExecutorEffect`, `src/Cortex/Wire/Executor.hs`) that this ADR
folds into the admission-projection content digest (`admissionProjectionDigest`,
`src/Cortex/Capability/Catalog/AdmissionProjection.hs`) is the executor **side-effect class
lattice**. Its vocabulary (`pure ⊑ model ⊑ host_effect ⊑ impure`), its declared-only status, and the
fact that it participates in interface identity through the projection content digest are governed
by the amendment to [ADR 0014](./0014-executor-taxonomy-model-vs-external-call.md) under feature key
`capability.effect_class_lattice`. No Traceability block is added here — it lives in the 0014
amendment.
