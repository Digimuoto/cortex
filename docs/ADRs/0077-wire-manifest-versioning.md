---
title: "ADR 0077 - Wire Package Manifest Versioning and Forward-Compatibility Contract"
description:
  "Pins the lenient cortex.toml decode policy as the Wire package manifest forward-compatibility
  contract: unmatched keys are non-fatal warnings, so an older binary accepts a manifest carrying
  later-slice keys."
sidebar:
  label: "0077. Manifest versioning"
  order: 77
status: proposed
date: 2026-06-27
superseded_by: null
related:
  - docs/ADRs/0060-filesystem-package-and-binding-manifests.md
  - docs/ADRs/0054-downstream-wire-packages-and-host-bindings.md
  - docs/Architecture/02-ownership-and-boundaries.md
  - docs/Reference/feature-status.md
---

# ADR 0077 - Wire Package Manifest Versioning and Forward-Compatibility Contract

## Status

Proposed. ADR 0060 fixed `cortex.toml` as the loading format for inert Wire package manifests and
explicitly deferred "manifest versioning" to a future hardening slice. The loader already ships a
lenient decode policy whose comment self-cites ADR 0060, but no ADR governs that policy and no test
pins it. This ADR makes the existing forward-compatibility behaviour an explicit contract rather
than an undocumented decode convenience.

## Context

[ADR 0060](./0060-filesystem-package-and-binding-manifests.md) defines `cortex.toml` as the
author-facing TOML loading format for inert Wire packages, and lists "manifest versioning" among the
fields a "future hardening slice may add". So the governing ADR for versioning is, by its own words,
not yet written.

Meanwhile the loader in `src/Cortex/Wire/Package/Manifest.hs` already makes a versioning-shaped
decision. `decodeWirePackageManifest` runs `Toml.decode` (toml-parser `>=2.0`) and matches on its
`Result`:

- `Toml.Failure errs` becomes a `WirePackageManifestDecodeError`;
- `Toml.Success _warnings manifest` is accepted, and the warning list is discarded (`_warnings`).

toml-parser reports an unmatched table key as a non-fatal warning, not a failure. Because the loader
throws the warning list away, a key the current schema does not match — a later-slice `version`,
`dependencies`, or requirement-slot field — does not reject the file. The decode keeps the keys this
binary understands and ignores the rest. That is exactly forward compatibility: an older binary
silently accepts a manifest written for a newer one. The loader's own comment already states this
and cites ADR 0060.

Two facts make this worth governing rather than leaving implicit:

- **There is no explicit version field today.** The decoded `PackageManifest` reads only
  `package.id` (a required key); none of the three in-repo manifests under
  `extensions/quantum/packages/*/cortex.toml` carry a `version` key, and the loader never reads one.
  "Versioning" is therefore not a declared schema number — it is a property of the decode policy. If
  that policy is not pinned, a future change (for example, treating unmatched keys as errors for
  strictness) would silently break the forward-compatibility property that downstream manifests are
  already relying on.
- **The behaviour is ungoverned and unexercised.** The forward-compatibility tolerance has no
  governing ADR and no test that decodes a manifest carrying an unknown later-slice key and asserts
  success. The manifest loader is reached only by happy-path tests that load well-formed quantum
  manifests.

## Decision

Adopt the **lenient, forward-compatible `cortex.toml` decode policy** as the Wire package manifest
versioning contract. The contract is defined by what the loader rejects, not by a declared version
number:

A Wire package manifest decode tolerates every non-fatal decode warning — in particular every
unmatched (unknown) table key — and fails only on a structural decode failure. An unknown key
carried by a later-slice manifest is dropped, not rejected, so a Cortex binary loads any manifest
whose recognised keys are well-formed regardless of which later keys it also carries. Forward
compatibility is the substrate guarantee; backward compatibility (a new binary reading an old
manifest) follows from every later-slice field being optional with a default.

This is intentionally a **schema-evolution policy, not a version-negotiation protocol**. There is no
`version` field, no minimum-version gate, and no per-version branching in the decoder. A manifest is
"versioned" only in the sense that its key set may grow over time while older binaries keep loading
it. Pinning the policy now means a future versioning slice (an explicit `version` field, dependency
declarations, requirement-slot syntax) must be introduced as additive optional keys that preserve
this tolerance, not as a breaking strict-decode change.

## Boundary Rules

The contract is the boundary between fatal and tolerated decode outcomes.

**Tolerated (manifest still loads):**

- an unmatched top-level or nested table key the current schema does not name — the
  forward-compatibility case;
- any other non-fatal toml-parser warning surfaced through the `Toml.Success` warning list;
- an absent optional key — every non-required field falls back to its default (`optionalList`,
  `optionalMap`, `optionalValue`), so a leaner old manifest still decodes under a newer binary.

**Fatal (`WirePackageManifestDecodeError`):**

- malformed TOML or a structural `Toml.Failure` from the decoder;
- a missing required key — `package.id`, a contract `id`/`payload_kind`, or an executor
  `id`/`effect` (`Toml.reqKey`);
- a recognised key whose value has the wrong shape or an unrecognised enum tag — for example an
  unknown executor `effect`, `port_policy`, `config_shape`, port cardinality, or payload kind, each
  of which `fail`s the value parser.

A read failure before decoding (missing or unreadable file) is the separate
`WirePackageManifestReadError`. The two error constructors keep an I/O failure distinguishable from
a content failure; neither is the tolerated path.

Scope: this contract governs only the **inert Wire package manifest** decode (ADR 0060's
compile-time authority class). It says nothing about the host runtime binding manifest, which is a
separate authority-bearing class loaded by a different layer and is not implemented yet.

## Alternatives considered

- **Strict decode (reject unmatched keys).** Treat any unknown key as a hard error so manifests are
  schema-exact. Rejected: it makes every additive field a breaking change, so an older binary could
  not load a manifest authored against a newer schema. That defeats the staged-hardening plan in ADR
  0060, which explicitly expects later slices to add keys.
- **An explicit `version` field with negotiation.** Decode `package.version` and branch or gate on a
  minimum supported version. Rejected for this slice: it is heavier than the current need, nothing
  reads a version today, and version negotiation is itself a later-slice decision. The lenient
  policy already delivers forward compatibility without a version handshake; a future `version`
  field can be added as an additive optional key under this same contract if negotiation is ever
  required.
- **Leave the behaviour implicit in the loader.** Keep the lenient decode but write no ADR.
  Rejected: the property is load-bearing for downstream manifest authors and is one refactor away
  from silent removal. ADR 0060 deferred versioning, so the governing record genuinely does not
  exist; this ADR fills that gap.

## Consequences

### Positive

- The forward-compatibility property downstream manifests already depend on becomes an explicit,
  citable contract instead of an undocumented decode convenience.
- A later hardening slice can add `version`, `dependencies`, or requirement-slot keys to
  `cortex.toml` without breaking binaries that predate those keys, as long as the new keys are
  optional.
- The fatal/tolerated boundary is stated precisely, so a future reviewer can tell whether a proposed
  decoder change (for example, making an unknown enum tag fatal versus an unknown key fatal)
  preserves or breaks the contract.

### Negative

- Tolerating unknown keys means a typo in a recognised key name decodes as an ignored unknown key
  rather than an error: the misspelled field is silently dropped with its default, with only a
  discarded warning. The contract trades typo-detection for forward compatibility.
- "Versioning" without a version field is a weaker guarantee than version negotiation. It cannot
  express "this manifest requires at least binary version N"; it only guarantees that extra keys do
  not break loading.

### Obligations

- **The contract is currently untested.** No test decodes a manifest carrying an unknown later-slice
  key and asserts that decode succeeds while the warning is dropped, and no test asserts that a
  malformed or required-key-missing manifest fails. Existing manifest tests
  (`test/Cortex/Wire/QuantumPackageSpec.hs`, `test/Cortex/Wire/RealizeCompileSpec.hs`) only load
  well-formed manifests on the happy path. Add a focused decode test that pins both edges of the
  boundary: an unknown-key manifest loads, and a structurally invalid one fails with
  `WirePackageManifestDecodeError`. Until that lands, the feature-status row stays `partial`.
- If an explicit `version` field is ever introduced, it must be an additive optional key that
  preserves this tolerance; introducing it as a strict gate supersedes this ADR rather than extends
  it.
- When the toml-parser warning surface is relied on for diagnostics, decide whether the discarded
  warning list should instead be surfaced to the author (for example, as a non-fatal lint), since
  today it is dropped entirely.

## Traceability

- Feature keys: `packaging.manifest_versioning`
- Public surface: `Cortex.Wire` (the `Cortex.Wire.Package.Manifest` loader); no Reference doc yet
- Implementation: `src/Cortex/Wire/Package/Manifest.hs` (decode and unmatched-key handling),
  `src/Cortex/Wire/Package.hs` (the `WirePackage` target type); CLI entry `app/wire/Main.hs`
- Tests: none — the forward-compatibility tolerance is unexercised; existing
  `test/Cortex/Wire/QuantumPackageSpec.hs` and `test/Cortex/Wire/RealizeCompileSpec.hs` load valid
  manifests only and do not assert unknown-key tolerance
- Theory/proof: none

## Related

- [ADR 0060 - Filesystem Package and Binding Manifests](./0060-filesystem-package-and-binding-manifests.md)
  — defines `cortex.toml` and defers manifest versioning; this ADR governs the deferred slice.
- [ADR 0054 - Downstream Wire Packages and Host Runtime Bindings](./0054-downstream-wire-packages-and-host-bindings.md)
  — the inert-package-versus-host-authority split the manifest decode lives inside.
- [Chapter 02 - Ownership and Boundaries](../Architecture/02-ownership-and-boundaries.md)
- [Cortex Feature Status](../Reference/feature-status.md) — the `packaging.manifest_versioning` row.
