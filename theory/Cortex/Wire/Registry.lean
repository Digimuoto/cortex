import Cortex.Graph.Laws
import Mathlib.Data.Finset.Basic

/-!
## Overview

Proof-facing model of the Wire executor registry boundary.

## Context

Wire syntax can stage executor authority with `@qualified.name { config }`.
That expression is pure: it does not run the executor. Before a staged
executor can become a materialized graph node, the registry must establish
that the executor exists, the config is valid, ports and contracts are
known, endpoint contracts are compatible, effect metadata is known, output
validation is known, and host authority is explicit.

This module turns those documented obligations into a reusable Lean
predicate. It intentionally remains abstract over executor names, config
values, contract identifiers, and host authority tokens; the Haskell
compiler and registry are responsible for producing concrete witnesses.
The predicates here are therefore a proof boundary, not a replacement for
the runtime correspondence theorem that must connect them to the executable
admission path. A registry with trivial predicates can satisfy this abstract
model; the load-bearing claim is the later theorem that the Haskell registry
constructs only these witnesses from real schema, contract, policy, and host
authority checks. Delta and chain-level preservation theorems over
`registryBoundary` inherit this same abstraction: they preserve admitted
boundaries, but they do not by themselves prove that runtime admission produced
non-trivial registry witnesses.

## Theorem Split

The page defines port boundaries, registry entries, staged executor nodes,
node-level admission, edge-level endpoint admission, graph-level registry
boundary validity, and transport of the boundary across denotational graph
equality.
-/

namespace Cortex.Wire

open Cortex.Graph

/-! ## Registry Model -/

/-- `EffectClass` names the coarse purity/effect category declared by the registry. -/
inductive EffectClass : Type where
  | pure
  | impure
  | hostEffecting
  | modelMediated
  deriving DecidableEq, Repr

/-- `PortBoundary contract` is the registry-declared contract surface for a node. -/
structure PortBoundary (contract : Type) [DecidableEq contract] where
  /-- Contracts accepted by the materialized node's input boundary. -/
  inputs : Finset contract
  /-- Contracts produced by the materialized node's output boundary. -/
  outputs : Finset contract

namespace PortBoundary

/-- `contracts boundary` is the full contract surface declared for a materialized node. -/
def contracts {contract : Type} [DecidableEq contract] (boundary : PortBoundary contract) :
    Finset contract :=
  boundary.inputs ∪ boundary.outputs

end PortBoundary

/-- `RegistryEntry` is the authority record attached to one registered executor. -/
structure RegistryEntry (config contract authority : Type) [DecidableEq contract] where
  /-- Configuration records for this executor must pass its registry schema. -/
  configValid : config → Prop
  /-- The registry can declare or derive the port boundary for this config. -/
  ports : config → PortBoundary contract
  /-- The executor authority has enough port information to become a graph node. -/
  portsDeclaredOrDerivable : config → Prop
  /-- The executor's purity/effect class is explicit registry metadata. -/
  effectClass : EffectClass
  /-- The registry has a validation rule for each declared output contract. -/
  outputValidationKnown : config → Prop
  /-- Host permissions for this executor invocation are explicit. -/
  hostAuthorityExplicit : authority → Prop

/-- `ExecutorRegistry` resolves executor names to registry entries. -/
structure ExecutorRegistry
    (executor config contract authority : Type)
    [DecidableEq contract] where
  /-- Lookup in the closed executor alphabet. `none` means the executor is not registered. -/
  resolve : executor → Option (RegistryEntry config contract authority)
  /-- The registry's closed contract vocabulary. -/
  contractKnown : contract → Prop
  /-- Endpoint compatibility for a source output contract and target input contract. -/
  contractsCompatible : contract → contract → Prop
  /-- Effect classes admitted by the runtime policy represented by this registry. -/
  effectClassKnown : EffectClass → Prop

/-- `StagedExecutorNode` is the pure result of applying `@` to config data. -/
structure StagedExecutorNode (executor config authority : Type) where
  /-- Qualified executor identity from the closed registry alphabet. -/
  executor : executor
  /-- Pure configuration data staged with the executor. -/
  config : config
  /-- Host-authority token selected by the registry or binding layer. -/
  authority : authority

/-! ## Admission Predicates -/

/-- `nodeAdmittedBy registry node` records the registry obligations for one staged node. -/
def nodeAdmittedBy
    {executor config contract authority : Type}
    [DecidableEq contract]
    (registry : ExecutorRegistry executor config contract authority)
    (node : StagedExecutorNode executor config authority) :
    Prop :=
  ∃ entry : RegistryEntry config contract authority,
    registry.resolve node.executor = some entry ∧
    entry.configValid node.config ∧
    entry.portsDeclaredOrDerivable node.config ∧
    (∀ contract,
      contract ∈ (entry.ports node.config).contracts →
        registry.contractKnown contract) ∧
    registry.effectClassKnown entry.effectClass ∧
    entry.outputValidationKnown node.config ∧
    entry.hostAuthorityExplicit node.authority

/-- `edgeAdmittedBy registry source target` records endpoint compatibility for one graph edge. -/
def edgeAdmittedBy
    {executor config contract authority : Type}
    [DecidableEq contract]
    (registry : ExecutorRegistry executor config contract authority)
    (source target : StagedExecutorNode executor config authority) :
    Prop :=
  ∃ sourceEntry targetEntry : RegistryEntry config contract authority,
    registry.resolve source.executor = some sourceEntry ∧
    registry.resolve target.executor = some targetEntry ∧
    ∃ outputContract inputContract : contract,
      outputContract ∈ (sourceEntry.ports source.config).outputs ∧
      inputContract ∈ (targetEntry.ports target.config).inputs ∧
      registry.contractKnown outputContract ∧
      registry.contractKnown inputContract ∧
      registry.contractsCompatible outputContract inputContract

/-- `registryVerticesAdmitted registry g` says every graph vertex is registry-admitted. -/
def registryVerticesAdmitted
    {executor config contract authority : Type}
    [DecidableEq contract]
    [DecidableEq (StagedExecutorNode executor config authority)]
    (registry : ExecutorRegistry executor config contract authority)
    (g : Graph (StagedExecutorNode executor config authority)) :
    Prop :=
  ∀ node,
    node ∈ (denote g).vertices →
      nodeAdmittedBy registry node

/-- `registryEdgesAdmitted registry g` says every graph edge has compatible endpoints. -/
def registryEdgesAdmitted
    {executor config contract authority : Type}
    [DecidableEq contract]
    [DecidableEq (StagedExecutorNode executor config authority)]
    (registry : ExecutorRegistry executor config contract authority)
    (g : Graph (StagedExecutorNode executor config authority)) :
    Prop :=
  ∀ source target,
    (source, target) ∈ (denote g).edges →
      edgeAdmittedBy registry source target

/-- `registryBoundary registry g` is the graph-level Wire registry admission predicate. -/
def registryBoundary
    {executor config contract authority : Type}
    [DecidableEq contract]
    [DecidableEq (StagedExecutorNode executor config authority)]
    (registry : ExecutorRegistry executor config contract authority)
    (g : Graph (StagedExecutorNode executor config authority)) :
    Prop :=
  registryVerticesAdmitted registry g ∧ registryEdgesAdmitted registry g

/-! ## Admission Projections -/

section AdmissionProjections

variable {executor config contract authority : Type}
variable [DecidableEq contract]
variable {registry : ExecutorRegistry executor config contract authority}
variable {node : StagedExecutorNode executor config authority}

/-- `nodeAdmittedBy_executor_exists` extracts the closed-alphabet lookup witness. -/
theorem nodeAdmittedBy_executor_exists
    (hAdmitted : nodeAdmittedBy registry node) :
    ∃ entry : RegistryEntry config contract authority,
      registry.resolve node.executor = some entry := by
  rcases hAdmitted with
    ⟨entry, hResolve, _hConfig, _hPorts, _hContracts, _hEffect, _hOutput, _hHost⟩
  exact ⟨entry, hResolve⟩

/-- `nodeAdmittedBy_configValid` extracts the config-schema obligation. -/
theorem nodeAdmittedBy_configValid
    (hAdmitted : nodeAdmittedBy registry node) :
    ∃ entry : RegistryEntry config contract authority,
      registry.resolve node.executor = some entry ∧ entry.configValid node.config := by
  rcases hAdmitted with
    ⟨entry, hResolve, hConfig, _hPorts, _hContracts, _hEffect, _hOutput, _hHost⟩
  exact ⟨entry, hResolve, hConfig⟩

/-- `nodeAdmittedBy_portsDeclared` extracts the port-boundary obligation. -/
theorem nodeAdmittedBy_portsDeclared
    (hAdmitted : nodeAdmittedBy registry node) :
    ∃ entry : RegistryEntry config contract authority,
      registry.resolve node.executor = some entry ∧
        entry.portsDeclaredOrDerivable node.config := by
  rcases hAdmitted with
    ⟨entry, hResolve, _hConfig, hPorts, _hContracts, _hEffect, _hOutput, _hHost⟩
  exact ⟨entry, hResolve, hPorts⟩

/-- `nodeAdmittedBy_contractsKnown` extracts the contract-vocabulary obligation. -/
theorem nodeAdmittedBy_contractsKnown
    (hAdmitted : nodeAdmittedBy registry node) :
    ∃ entry : RegistryEntry config contract authority,
      registry.resolve node.executor = some entry ∧
        ∀ contract,
          contract ∈ (entry.ports node.config).contracts →
            registry.contractKnown contract := by
  rcases hAdmitted with
    ⟨entry, hResolve, _hConfig, _hPorts, hContracts, _hEffect, _hOutput, _hHost⟩
  exact ⟨entry, hResolve, hContracts⟩

/-- `nodeAdmittedBy_effectClassKnown` extracts the effect-class policy obligation. -/
theorem nodeAdmittedBy_effectClassKnown
    (hAdmitted : nodeAdmittedBy registry node) :
    ∃ entry : RegistryEntry config contract authority,
      registry.resolve node.executor = some entry ∧
        registry.effectClassKnown entry.effectClass := by
  rcases hAdmitted with
    ⟨entry, hResolve, _hConfig, _hPorts, _hContracts, hEffect, _hOutput, _hHost⟩
  exact ⟨entry, hResolve, hEffect⟩

/-- `nodeAdmittedBy_outputValidationKnown` extracts the output-validation obligation. -/
theorem nodeAdmittedBy_outputValidationKnown
    (hAdmitted : nodeAdmittedBy registry node) :
    ∃ entry : RegistryEntry config contract authority,
      registry.resolve node.executor = some entry ∧
        entry.outputValidationKnown node.config := by
  rcases hAdmitted with
    ⟨entry, hResolve, _hConfig, _hPorts, _hContracts, _hEffect, hOutput, _hHost⟩
  exact ⟨entry, hResolve, hOutput⟩

/-- `nodeAdmittedBy_hostAuthorityExplicit` extracts the host-authority obligation. -/
theorem nodeAdmittedBy_hostAuthorityExplicit
    (hAdmitted : nodeAdmittedBy registry node) :
    ∃ entry : RegistryEntry config contract authority,
      registry.resolve node.executor = some entry ∧
        entry.hostAuthorityExplicit node.authority := by
  rcases hAdmitted with
    ⟨entry, hResolve, _hConfig, _hPorts, _hContracts, _hEffect, _hOutput, hHost⟩
  exact ⟨entry, hResolve, hHost⟩

end AdmissionProjections

/-! ## Boundary Projections -/

section BoundaryProjections

variable {executor config contract authority : Type}
variable [DecidableEq contract]
variable [DecidableEq (StagedExecutorNode executor config authority)]
variable {registry : ExecutorRegistry executor config contract authority}
variable {g h : Graph (StagedExecutorNode executor config authority)}

/-- `registryBoundary_vertices` extracts graph-wide vertex admission. -/
theorem registryBoundary_vertices
    (hBoundary : registryBoundary registry g) :
    registryVerticesAdmitted registry g :=
  hBoundary.1

/-- `registryBoundary_edges` extracts graph-wide endpoint compatibility. -/
theorem registryBoundary_edges
    (hBoundary : registryBoundary registry g) :
    registryEdgesAdmitted registry g :=
  hBoundary.2

/-! ## Graph Equality Transport -/

/-- Registry-boundary validity transports across denotational graph equality. -/
theorem registryBoundary_of_graphEq
    (hEq : GraphEq g h)
    (hBoundary : registryBoundary registry g) :
    registryBoundary registry h := by
  have hDenote : denote g = denote h := hEq
  rcases hBoundary with ⟨hVerticesBoundary, hEdgesBoundary⟩
  constructor
  · intro node hNode
    have hVertices : (denote h).vertices = (denote g).vertices := by
      rw [hDenote]
    exact hVerticesBoundary node (by simpa [hVertices] using hNode)
  · intro source target hEdge
    have hEdges : (denote h).edges = (denote g).edges := by
      rw [hDenote]
    exact hEdgesBoundary source target (by simpa [hEdges] using hEdge)

/-- Registry-boundary validity is invariant under denotational graph equality. -/
theorem registryBoundary_graphEq_iff
    (hEq : GraphEq g h) :
    registryBoundary registry g ↔ registryBoundary registry h := by
  constructor
  · exact registryBoundary_of_graphEq hEq
  · exact registryBoundary_of_graphEq hEq.symm

end BoundaryProjections

end Cortex.Wire
