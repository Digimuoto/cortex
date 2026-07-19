---
title: "ADR 0097 - Wire Static Intent and Realization Inputs"
description:
  "Adds a versioned, identity-bound static-intent plane between Cortex compiler metadata and runtime
  executor arguments, while keeping grants and concrete bindings outside the admitted program."
sidebar:
  label: "0097. Wire static intent"
  order: 97
status: proposed
date: 2026-07-19
superseded_by: null
related:
  - docs/ADRs/0002-cortex-downstream-ownership-boundary.md
  - docs/ADRs/0010-wire-closed-authority-and-three-layer-stack.md
  - docs/ADRs/0053-executor-catalog-manifests-and-pulse-bindings.md
  - docs/ADRs/0054-downstream-wire-packages-and-host-bindings.md
  - docs/ADRs/0060-filesystem-package-and-binding-manifests.md
  - docs/ADRs/0079-wire-admission-witness-schema.md
  - docs/ADRs/0095-wire-single-record-executor-boundary.md
  - docs/ADRs/0096-certified-native-pure-region-compilation.md
---

# ADR 0097 - Wire Static Intent and Realization Inputs

## Status

Proposed. This ADR defines the missing semantic plane exposed by ADR 0095's one-record executor
boundary. It is intentionally a design draft: no `intent` source form, static-intent projection
registry, or intent-bound admitted-program artifact exists yet. The final removal of legacy executor
configuration must not land until the static-intent path exists and downstream consumers that use
legacy configuration as admission input have migrated.

## Context

ADR 0095 makes an important phase distinction:

- `with { ... }` is statically evaluated Cortex-owned compiler policy; and
- an executor's one record is evaluated at node ingress and delivered to that executor.

That removes the old syntactic distinction between executor configuration and source input. It also
exposes that the old `config` record accidentally carried a third category: downstream-owned facts
which must be known before execution but which are not Cortex compiler policy.

wireOS is the forcing case. Its current `wireos.declare` nodes encode `wireos.system-intent/v0`
terms in executor configuration. `WireOS.Cortex.Fragment.decodeTaskIntent` reads those terms
directly from compiled task metadata. The declaration nodes perform no meaningful runtime work, and
`WireOS.SystemGraph.Join` ignores their authored edges. Some fixtures chain the nodes only because
Cortex requires connected topology. The configuration record is therefore a bootstrap transport for
static system intent, not an executor argument.

The same category appears less visibly elsewhere:

- Logos reusable profiles request model classes, tool vocabularies, memory classes, grounding,
  approval, and budget ceilings before a host resolves providers, credentials, and concrete tools.
- CortexQC must distinguish per-call quantum data such as gate angles and shot counts from a static
  backend requirement, same-authority realization constraints, and the host's concrete device,
  region, credentials, queue policy, and spending grant.
- freestanding and Microkit examples need static component, resource, mapping, artifact, and effect
  requirements, while their synthetic completions and failures are test-scenario inputs.
- ADR 0053 describes requirement selectors derived from admitted executor configuration, but an ADR
  0095 argument may depend on a consumed port and therefore may not exist when binding must finish.

Calling every compile-time-looking value `config` concealed these differences. Conversely, treating
every field in the authored executor record as ingress data prevents an executor signature from
requiring instance-specific binding inputs before execution. Literal syntax is not a phase: a
literal field remains ingress unless its consumer declares an admission obligation, while static
intent is independently closed over runtime ports by construction.

### The design tensions

| Tension                                    | Cortex context                                                                                                                                             | Decision in this ADR                                                                                                                                             |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Constant syntax vs semantic phase          | A record literal does not tell the binder which executor fields must be available before ingress.                                                          | The executor projection declares field obligations in one `argument_shape`; dependency analysis proves admission fields and leaves the rest as residual ingress. |
| Static evaluation vs pure execution        | CorePure syntax is used for values in several phases, and NativePure compiles effect-free runtime regions; neither fact makes a value compile-time intent. | The enclosing construct fixes the phase. Static intent is evaluated during admission; pure nodes and NativePure regions still execute at runtime.                |
| Generic substrate vs downstream meaning    | Cortex must serve wireOS, Logos, CortexQC, and future consumers without importing their vocabularies.                                                      | Cortex owns a generic attachment envelope and registry protocol; downstream packages own versioned intent schemas and validators.                                |
| Closed authority vs extensibility          | Arbitrary annotations would let source invent planning meaning or smuggle authority past admission.                                                        | Intent schema identities must be registered through inert package projections. Unknown schemas, members, and versions fail closed.                               |
| Ambient registry vs stable meaning         | Revalidating a Circuit against a later registry could change a contract shape or downstream validator without changing the Circuit address.                | Admission records a digest of exactly the canonical projections and validators consulted. Every downstream artifact cites that immutable registry witness.       |
| Inline coherence vs external operations    | Small requirements are clearest next to a node; whole-system intent and environment overlays are often deployed as separate reviewed files.                | Inline Wire and sidecar documents lower to the same canonical `StaticIntentBundle`; neither is semantically privileged.                                          |
| Circuit identity vs deployment variability | The same executable topology can be requested for different systems, but stale intent must never attach to another Circuit.                                | Preserve the Circuit address and derive a separate intent-bound admitted-program address from it. Grants and bindings cite that address.                         |
| Requirement vs authority                   | Naming UART, filesystem, model, tool, or quantum needs must not grant access.                                                                              | Static intent only requests and constrains. A host grant and binding record alone authorize and select implementations.                                          |
| Package invariant vs program instance      | An executor package can always require a capability kind, while one program may request a narrower scope or backend class.                                 | Package projections own invariant slots; static intent instantiates per-program requirements; host binding satisfies them.                                       |
| Forward compatibility vs security          | `cortex.toml` currently tolerates unrelated keys, but admission and authority inputs cannot silently ignore misspellings.                                  | Intent and grant schemas are version-gated, closed decoders. Package-manifest discovery may remain forward-compatible at its outer layer.                        |
| System scope vs node scope                 | wireOS declares components and mappings across the whole Circuit; Logos and executor needs often attach to one node.                                       | Attachments have explicit circuit or node scope. Node scope is represented by a resolved Circuit node reference, never an incidental graph edge.                 |
| Core admission vs downstream admission     | Lean's Wire artifact proves generic graph facts; wireOS and CortexQC enforce domain-specific joins.                                                        | Static intent is bound to, but not embedded as opaque semantics inside, `WireAdmissionArtifact`. Each registered intent validator owns its domain checks.        |
| Required semantics vs ignorable metadata   | Debug notes may be safely dropped; deployment requirements may not.                                                                                        | Static intent is must-understand admission data, not an advisory annotation. A selected realizer must consume or explicitly reject every applicable attachment.  |
| Behavior vs test environment               | Failure timing, synthetic completions, and chosen grants are not properties of the authored workflow.                                                      | Scenario manifests remain separate realization/test inputs and never become Wire intent or executor calls.                                                       |

## Decision

Cortex introduces **static intent attachments** as a third authored semantic plane. The complete
staging model is:

| Plane or artifact                                 | Owner                           | Evaluation time     | May depend on runtime ports? | Grants authority?                            |
| ------------------------------------------------- | ------------------------------- | ------------------- | ---------------------------- | -------------------------------------------- |
| Wire topology, contracts, and executor identities | Cortex plus registered packages | compile/admission   | no                           | no                                           |
| `with { ... }` compiler metadata                  | Cortex                          | compile             | no                           | no                                           |
| static intent attachments                         | registered downstream schema    | compile/admission   | no                           | no                                           |
| executor argument admission fields                | executor projection             | compile/admission   | no                           | no by itself                                 |
| residual executor argument record                 | executor contract               | node ingress        | yes                          | no by itself                                 |
| host grant, platform facts, and binding manifest  | host/deployer                   | realization/binding | no                           | yes, within an explicit ceiling              |
| runtime outputs, checkpoints, and telemetry       | executor/runtime                | execution           | yes                          | records use; does not retroactively grant it |

The unifying rule is:

> A program declares what it requires, a host proves what is available and allowed, a binder records
> the match, and only then may the runtime deliver dynamic values to an executor.

Static intent changes the set of admissible realizations, not the Circuit's value-flow semantics.
Two admitted programs may therefore share the same Circuit and compute the same values while
requesting different platforms or authority ceilings. Conversely, an effect-free Wire node is still
runtime computation: CorePure is an expression language, not a synonym for static evaluation, and
NativePure is a runtime realization profile rather than an admission-time evaluator.

Executor-specific binding inputs do not require another authored block. ADR 0095 keeps one executor
record and lets its registered `argument_shape` mark top-level properties with
`x-cortex-binding-time = "admission"`. The compiler proves those expressions port-closed, evaluates
and validates them during admission, and specializes them out of the residual ingress record.
Unannotated fields default to ingress. The field obligation belongs to the consumer signature;
`let ... in`, module `let`, and `where` remain stage-polymorphic lexical bindings.

This executor-static subset is not a substitute for static intent. It configures or selects the
binding of that executor invocation. Static intent describes executor-independent graph, system, or
realization requirements and may have circuit scope, sidecar provenance, and downstream joins which
no executor argument owns. `with` remains Cortex-owned node policy.

### Canonical static-intent model

The canonical carrier is a versioned `StaticIntentBundle` containing normalized
`StaticIntentAttachment` records plus a source-provenance table. A semantic attachment contains at
least:

- a globally qualified, versioned schema identity;
- an explicit scope: the whole Circuit or one resolved Circuit node;
- one canonical record value validated by that schema; and
- the address of the exact `CompiledCircuit` against which references were resolved.

The separate provenance table identifies the inline block or sidecar document which contributed an
attachment. It travels with the bundle for diagnostics and audit, but is excluded from the semantic
intent digest. Moving an equivalent source file therefore does not change the requested realization.

At most one attachment for a given `(schema identity, scope)` is permitted in v1. Schemas which need
many terms, such as wireOS components, resources, mappings, and effects, carry them as keyed
collections inside that one record. This avoids an implicit merge algebra. A later schema version
may define explicit composition, but Cortex must not guess how independently authored records merge.

The normalized record may contain bounded scalar, list, and record values plus typed references to
Circuit nodes, ports, contracts, and executor projections. Authoring formats may spell references as
names, but normalization resolves them to canonical identities before hashing. Missing, ambiguous,
or wrong-kind references fail admission.

Static intent is stricter than ordinary package metadata:

- its value must be statically evaluable and closed over runtime ports, `where` values, checkpoints,
  environment variables, filesystem reads, clocks, randomness, and host secrets;
- its registered decoder rejects unknown members and unsupported schema versions;
- duplicate identities and duplicate semantic keys fail rather than select a winner;
- canonicalization is deterministic and occurs before identity calculation; and
- credentials, handles, resolved paths containing secrets, and provider clients are forbidden.

### One meaning, two authoring locations

Inline and sidecar intent are two source locations for the same canonical object.

The proposed inline Wire surface uses a dedicated `intent` clause rather than extending `with` or
overloading an executor call. Circuit-scoped intent is a module item; node-scoped intent is a node
clause. The schema id is explicit and versioned:

```wire
use wireos.device.uart.{@read_line, Line};

intent "wireos.system-intent/v1" {
  components = [
    { id = "runtime"; class = "native-protection-domain"; }
  ];
  resources = [
    {
      id = "uart0";
      class = "wireos.device.uart.pl011";
      share_mode = "exclusive";
    }
  ];
  effects = [
    {
      node = node_ref("first");
      class = "stream-observation";
      resource = "uart0";
    }
  ];
}

node first
  with { timeout = 30; }
  -> result: Line
  = @read_line;
```

This example keeps the meanings disjoint:

- `timeout` is Cortex scheduling policy;
- the wireOS component/resource/effect record is static downstream intent;
- `@read_line` receives `{}` at ingress; and
- the concrete PL011 mapping and authority grant arrive later from the selected platform and host.

A sidecar authoring format expresses the same attachment when system intent is reviewed or generated
separately:

```toml
schema = "wireos.system-intent/v1"
circuit_address = "sha256:..."

[[component]]
id = "runtime"
class = "native-protection-domain"

[[resource]]
id = "uart0"
class = "wireos.device.uart.pl011"
share_mode = "exclusive"

[[effect]]
node = "first"
class = "stream-observation"
resource = "uart0"
```

The sidecar is not a second manifest semantics. The compiler/attacher decodes it through the same
registered schema, resolves `first` against the cited Circuit, and produces the same canonical
attachment as the inline form. If both forms supply the same `(schema, scope)`, admission rejects
the duplicate unless their byte-identical equality is explicitly accepted by a future composition
rule.

`with` remains a closed Cortex-owned vocabulary. It does not gain an `extension` escape hatch. This
keeps compiler policy auditable and prevents a downstream schema from acquiring accidental compiler
semantics. Likewise, `cfg` remains only a conventional field inside the runtime executor record; it
does not acquire static meaning merely because all of its leaves happen to be literals.

### Projection and ownership model

A Wire package may register a **static-intent projection** alongside executor and contract
projections. The projection is inert compile-time data and contains:

- schema identity and version;
- canonical schema digest;
- allowed scope (`circuit`, `node`, or both);
- a closed value shape;
- typed-reference positions and their allowed target kinds;
- the downstream validator identity/version; and
- whether a selected realization profile must consume the attachment.

Loading the projection makes an intent vocabulary admissible; it grants no authority and does not
load a host binding. This is the same closed-authority pattern used for executor projections: Wire
may compose registered meaning but may not invent it.

Cortex owns envelope validation, canonical encoding, reference resolution, identity binding,
duplicate detection, and dispatch to the registered validator. The downstream package owns the
meaning and cross-field rules of its record. For example, wireOS owns address-space overlap,
allocation, ownership, channel, and effect-scope checks; CortexQC owns legal quantum-backend and
same-authority-frontier constraints; Logos owns model/tool/memory declaration semantics.

The generic `WireAdmissionArtifact` remains the graph/proof witness governed by ADR 0079. Opaque
downstream records are not added to its Lean kernel merely to preserve them. Instead, a sibling
`StaticIntentBundle` is independently validated and both artifacts are joined by the same Circuit
address and registry witness in an intent-bound admitted-program envelope.

The admission pipeline is ordered:

1. parse and elaborate Wire topology plus runtime argument expressions into a `CompiledCircuit`,
   recording each canonical executor, contract, projection, and validator consulted;
2. calculate the Circuit's canonical semantic address and the consulted registry-witness address,
   excluding proof and intent companions from the Circuit address;
3. statically evaluate inline intent and decode sidecars which cite that address;
4. resolve typed references, canonicalize attachments, and run generic plus downstream validation;
5. bind the resulting `StaticIntentBundle` and `WireAdmissionArtifact` to the Circuit as one
   `AdmittedProgram`; and
6. join that admitted program with platform facts, grants, artifacts, and host bindings before Pulse
   receives runnable work.

### Identity chain

The identities form a staged chain rather than one overloaded hash:

```text
CompiledCircuit
  -> circuit_address

RegistryWitness(canonical consulted projections and validator identities)
  -> registry_witness_address

StaticIntentBundle(circuit_address, registry_witness_address, normalized attachments)
  -> intent_bundle_address

AdmittedProgram(circuit_address, registry_witness_address, admission witness, intent_bundle_address)
  -> admitted_program_address

RealizationInput(admitted_program_address, platform facts, grants, bindings, artifacts)
  -> realization_address / SystemGraph address / NativePure target address
```

The Circuit address continues to identify executable topology and runtime argument expressions. Two
deployments may therefore share a Circuit address while having different admitted-program or
realization addresses. A sidecar cannot be applied to a changed Circuit because its Circuit address
will not match. A host grant or binding cannot be replayed against changed intent because it cites
the admitted-program address. A later compiler, realizer, or binder cannot substitute ambient
registry meaning because the admitted program cites the canonical digest of exactly the projections
and validator identities used to interpret it. Adding an unrelated registry entry does not perturb
that digest; changing a consulted entry does.

Source paths, comments, and authoring order are provenance but do not perturb semantic identity once
they normalize to the same attachment set. Schema identities, scopes, resolved references, canonical
values, and schema digests do perturb identity. Existing v1 runtime and StaticC interfaces remain
unchanged when no static-intent profile is selected; intent-aware realization uses a separately
versioned envelope rather than silently changing a v1 address or ABI.

### Requirements, grants, and binding

ADR 0053 requirement slots are refined as follows:

- an executor projection declares invariant capability kinds, permissions, replay class, await
  strategy, isolation minima, and binding-time obligations for its one argument record;
- admission fields in that record supply executor-specific instance values required to bind or
  specialize that invocation;
- a static intent attachment supplies executor-independent graph or system requirements which must
  be available before execution;
- a host grant supplies the available authority ceiling;
- a host binding record proves that every invariant and per-program requirement is satisfied and
  records the chosen implementation and authority fingerprints; and
- the residual executor argument remains ordinary ingress data and is never consulted to mint
  pre-execution authority.

Requirement selectors must therefore not point into the residual runtime expression. They may cite a
projection-declared admission field which has already been evaluated, validated, and included in
program identity. Existing ADR 0053 language about selectors derived from admitted `config` is
legacy terminology to supersede when this ADR is accepted. A value such as a gate angle, output
path, prompt text, shot count, or model message remains ingress when computed from upstream values.
An executor-specific model profile or bounded option may be an admission field. A backend class,
tool permission scope, device class, resource ceiling, or cross-node constraint belongs in static
intent when its meaning is independent of one executor's argument schema.

Intent requests never widen authority. Binding computes an effective authority no greater than both
the request and the host grant. A useful abstract rule is:

```text
effective = satisfy(package invariant ∧ program intent, host grant, platform facts)
```

Failure to resolve a required attachment or capability is a pre-execution binding failure. Pulse
receives only already-bound runnable stages and remains blind to package discovery, intent-source
files, credentials, and provider selection.

### Downstream applications

#### wireOS

wireOS migrates `wireos.system-intent/v0` to a closed `wireos.system-intent/v1` static-intent
schema. Component, resource, channel, mapping, ownership, artifact, and effect terms become
collections in one circuit-scoped attachment. References to effectful task nodes become resolved
node references.

This removes `wireos.declare` pseudo-executors, synthetic handle contracts, and topology edges that
`SystemGraph.Join` ignores. Platform facts, the deployer grant, realized artifact paths, concrete
Microkit mappings, and binding records remain realization inputs. `SystemGraph` identity derives
from the intent-bound admitted program plus those realization inputs.

The resulting authoring equation is:

```text
Wire behavior + wireOS SystemIntent + platform/grant/bindings -> witnessed SystemGraph
```

It is not `Wire -> authority`, and it is not `executor cfg -> deployment plan`.

#### Logos

Logos already distinguishes reusable declarations from authority-bearing host bindings. This ADR
gives that split a Cortex-native carrier:

| Logos fact                                                                                                                       | Plane                                 |
| -------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| prompt/messages, tool results, turn inputs, dynamically selected candidate pack                                                  | executor argument or runtime artifact |
| requested model class, allowed tool vocabulary, memory class, approval intent, grounding requirement, maximum budget class       | static intent                         |
| provider endpoint/credentials, concrete model acceptance, actual tool implementation and filesystem/network scope, spend ceiling | host grant and binding                |
| timeout/retry/checkpoint policy owned by Cortex scheduling                                                                       | `with` compiler metadata              |
| observed token usage, finish reason, selected tools, cost, failures                                                              | runtime telemetry                     |

Static intent may narrow an already registered tool vocabulary but cannot create tools or grant
their execution. Deferred per-turn tool selection remains runtime computation inside the authority
ceiling established by binding.

#### CortexQC

CortexQC keeps quantum program values in the one-record executor boundary:

| Quantum fact                                                                                                      | Plane                     |
| ----------------------------------------------------------------------------------------------------------------- | ------------------------- |
| qubit index, gate angle, measured bits, shots when computed or submitted per realization call                     | executor argument         |
| requirement for a quantum backend class, native-gate set, same-authority fusion, maximum queue/cost class         | static intent             |
| AWS profile and credentials, concrete region/device ARN, S3 destination, approved spending limit, provider client | host grant and binding    |
| returned device identity, task ARN, result hashes, timestamps, observed shots                                     | runtime output/provenance |

Package manifests continue to register `@quantum.*` executors, contracts, argument shapes, native
shapes, and invariant backend requirement slots. They do not contain experiment-specific intent or
provider credentials. An offline dry run may bind the same admitted program to a no-authority
renderer; hardware execution requires a separate grant whose binding is recorded.

#### Cortex examples and fixtures

- `@stdin { cfg = { prompt = ...; }; }`, `@stdout`, `@writeFile`, gate angles, and ordinary request
  options remain executor arguments. Being literals does not move them to static intent.
- timeout, retry, memory, artifact routing, and other Cortex-owned scheduling controls remain
  `with`.
- target constraints which select a NativePure or freestanding profile are realization inputs unless
  a program explicitly requires a representation property through a registered intent schema.
- synthetic success, asynchronous completion, failure, cancellation, selected grant, and expected
  terminal state belong in a fixture scenario manifest. Tooling may compile such a manifest into
  constant tables consumed by one shared C harness.
- genuine MMIO/IRQ drivers, provider adapters, and ABI shims remain code at the machine boundary;
  static intent does not pretend declarative data implements them.

### Prior art and the parts Cortex adopts

This design follows working staged systems, but deliberately combines only the properties Cortex
needs:

| System                                                                                                                                                                                                                                   | Relevant working idea                                                                                                          | Cortex relation                                                                                                                                                                                                   |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [MLIR dialect attributes](https://mlir.llvm.org/docs/LangRef/#dialects)                                                                                                                                                                  | Namespaced dialects attach constant, verifier-owned data to operations without turning it into SSA operands.                   | Static intent is namespaced constant data separate from runtime ports. Cortex adds closed package admission, must-understand behavior, and identity binding because deployment intent cannot be discardable.      |
| [Bazel toolchains](https://bazel.build/extending/toolchains) and [platform constraints](https://bazel.build/reference/be/platforms-and-toolchains)                                                                                       | A rule declares a toolchain type and constraints; analysis resolves one implementation for an execution platform.              | Executor/package requirements and program intent are declarations; host binding resolves concrete implementations against platform facts. Only the resolved binding becomes runnable authority.                   |
| [Kubernetes object spec/status](https://kubernetes.io/docs/concepts/overview/working-with-objects/#object-spec-and-status) and [Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/) | Versioned schemas express desired state separately from observed state; extension APIs have explicit validation.               | Static intent is desired, validated input; realization and runtime evidence are separate. Cortex does not adopt a continuously reconciling control plane or use a generic annotations bag for required semantics. |
| [Terraform configuration, provider, and state](https://developer.hashicorp.com/terraform/language/resources)                                                                                                                             | Provider-specific declarations are distinct from provider configuration and the state that binds declarations to real objects. | Downstream intent is distinct from host binding and realization records. Cortex does not turn Wire into an infrastructure CRUD language; topology remains the program and realizers remain downstream.            |
| [WebAssembly custom sections](https://webassembly.github.io/spec/core/binary/modules.html#custom-section)                                                                                                                                | Versioned artifacts can carry namespaced third-party data without changing core execution semantics.                           | Static intent similarly does not alter executor value semantics. Unlike WebAssembly custom sections, required Cortex intent may not be ignored by a selected realizer and must be covered by semantic identity.   |

The common pattern is a staged join between declaration, environment evidence, and selected
implementation. Cortex's additional constraint is closed authority: declaration may constrain a
later grant but can never manufacture the grant.

## Alternatives considered

- **Treat literal `cfg` fields as static and dynamic fields as runtime.** Rejected because phase
  would depend on expression analysis, seemingly harmless refactors could change binding semantics,
  and a binder still could not depend on a value whose expression refers to ingress ports.
- **Reserve `cfg` as always static.** Rejected because ADR 0095 intentionally defines one ingress
  record and existing examples legitimately compute executor options from upstream values. A field
  name convention is not a type-and-effect boundary.
- **Put downstream intent in `with`.** Rejected because `with` is Cortex-owned compiler policy. An
  open extension map would blur ownership and an unknown downstream member could silently affect
  admission or code generation.
- **Keep pseudo-executors such as `wireos.declare`.** Rejected because they add fake runtime nodes,
  fake data dependencies, and ignored graph edges. Static declarations should not masquerade as
  effects.
- **Use only external manifests.** Rejected because node-local requirements lose locality, refactors
  can drift before address checking, and small self-contained programs become unnecessarily
  multipart. Sidecars remain supported for operationally separate system intent.
- **Use only inline Wire.** Rejected because platform teams need separately reviewed, generated, or
  overlaid whole-system intent and because scenarios and grants have different ownership and secret
  handling.
- **Store program intent in the reusable package manifest.** Rejected because packages declare
  vocabulary and invariant requirements, while intent is an instance bound to one Circuit. Mixing
  them prevents package reuse and makes deployment choices look globally invariant.
- **Use free-form namespaced annotations and let consumers ignore unknown data.** Rejected because
  required deployment and authority constraints must fail closed. Advisory annotations may be added
  separately later, but they are not static intent.
- **Fold downstream intent into `WireAdmissionArtifact`.** Rejected because the artifact is the
  generic Haskell-to-Lean graph witness. Teaching its core validator every downstream schema would
  invert ADR 0002's ownership direction and destabilize the proof contract.
- **Hash intent directly into the Circuit address.** Rejected because topology/runtime behavior and
  deployment intent have different reuse boundaries. A staged admitted-program address prevents
  stale joins without erasing that distinction.
- **Let realization inspect runtime arguments opportunistically.** Rejected because doing so makes
  authority selection dependent on a future runtime value and violates the bind-before-Pulse
  boundary.

## Consequences

### Positive

- ADR 0095 can preserve a genuinely uniform executor ABI without losing statically inspectable
  downstream requirements.
- wireOS can delete fake declaration topology while retaining one content-addressed admitted
  referent for SystemGraph construction.
- Logos and CortexQC receive the same generic request-versus-grant model without moving their domain
  semantics into Cortex core.
- Inline and sidecar workflows share validation, normalization, identity, and binding rules.
- Capability selection no longer depends on a residual runtime executor argument; executor-specific
  selectors use validated admission fields instead.
- Scenario data can replace much fixture-specific C without polluting program semantics.

### Negative

- The artifact pipeline gains an additional versioned bundle and admitted-program address.
- Package projections need another registered schema class and downstream validators need a stable
  interface.
- Authors must classify values by meaning and phase instead of putting every setting under `cfg`.
- Inline/sidecar equality, diagnostic source maps, and typed reference rendering add compiler and
  formatter work.
- Existing consumers cannot be migrated by syntax rewriting alone; their binders and provenance
  models must adopt the new identity chain.

### Obligations

- Implement a closed `StaticIntentProjection` registry and versioned `StaticIntentBundle` encoding.
- Make registered projection values opaque and valid by construction through validating smart
  constructors, while retaining trust-boundary revalidation.
- Implement the consulted registry witness and require admission, intent, grants, bindings, and
  realization artifacts to cite it or prove identity with it.
- Specify the static expression subset and typed Circuit-reference encoding without admitting
  runtime values or host observations.
- Add the intent-bound admitted-program artifact and require grants, bindings, and realization
  artifacts to cite its address.
- Amend ADRs 0053 and 0060 when this design is accepted so requirement selectors no longer refer to
  runtime executor arguments and manifest classes are named unambiguously.
- Add inline and sidecar conformance tests proving byte-identical normalization and stable digests.
- Make unknown schema versions, unknown fields, missing validators, duplicate scopes, stale Circuit
  addresses, unresolved references, and unconsumed required intent typed failures.
- Migrate wireOS before removing legacy compiled `config` metadata; remove `wireos.declare` and its
  synthetic handle topology only after SystemGraph consumes the new bundle.
- Audit Logos profile/tool declarations and CortexQC backend selection against the classification
  tables above, with consumer-owned ADR amendments where their public surfaces change.
- Define a separate scenario-manifest schema and generic fixture harness; do not overload static
  intent with expected outcomes.
- Keep secrets and concrete authority fingerprints exclusively in host grant/binding material and
  redacted provenance surfaces.

## Traceability

- Feature keys: `wire.static_intent_attachments`
- Public surface: planned `Cortex.Wire.StaticIntent`; planned Wire `intent` module item and node
  clause; planned sidecar attachment command in the `wire` CLI
- Implementation: none
- Tests: none
- Theory/proof: none; the generic Wire admission proof remains governed by
  [`proof-status.md`](../Reference/proof-status.md), while downstream intent validators own their
  domain-specific evidence

## Related

- [ADR 0002 - Cortex and Downstream Ownership Boundary](0002-cortex-downstream-ownership-boundary.md)
- [ADR 0010 - Wire as a Closed-Authority Language](0010-wire-closed-authority-and-three-layer-stack.md)
- [ADR 0053 - Executor Catalog Manifests and Pulse Runtime Bindings](0053-executor-catalog-manifests-and-pulse-bindings.md)
- [ADR 0060 - Filesystem Package and Binding Manifests](0060-filesystem-package-and-binding-manifests.md)
- [ADR 0079 - Wire Admission Witness Schema](0079-wire-admission-witness-schema.md)
- [ADR 0095 - Wire Single-Record Executor Boundary](0095-wire-single-record-executor-boundary.md)
- [ADR 0096 - Certified NativePure Compilation](0096-certified-native-pure-region-compilation.md)
- [Issue 402 - Bind NativePure admission to an immutable registry snapshot](https://github.com/Digimuoto/cortex/issues/402)
- [wireOS SystemGraph plan](https://github.com/Digimuoto/wireOS/blob/main/docs/Roadmap/Plans/wire-c-generation-unification.md)
- [Logos ADR 0014 - LLM profiles and tool authority bindings](https://github.com/Digimuoto/logos/blob/main/docs/ADRs/0014-llm-profiles-and-tool-authority-bindings.md)
- [CortexQC quantum binding](https://github.com/Digimuoto/cortex-qc/blob/main/docs/Consumers/Quantum.md)

## Tracking

- [ ] Close [issue #402](https://github.com/Digimuoto/cortex/issues/402): bind admission to the
      consulted registry witness and seal raw projection constructors before the
      realization-artifact review batch closes.
- [ ] Agree on the `StaticIntentAttachment` carrier, scopes, identity chain, and must-understand
      rule.
- [ ] Validate the proposed `intent` syntax against the Wire grammar and formatter before reserving
      the keyword.
- [ ] Define the sidecar source format and prove it normalizes identically to inline intent.
- [ ] Define typed node/port/contract/executor references in both authoring formats.
- [ ] Reconcile ADR 0053 requirement slots and ADR 0060 manifest terminology.
- [ ] Prototype `wireos.system-intent/v1` and migrate one QEMU/SystemGraph fixture.
- [ ] Classify one Logos profile/tool workflow and one CortexQC hardware/dry-run workflow end to
      end.
- [ ] Block the final legacy-configuration removal on those downstream migrations and conformance
      tests.
