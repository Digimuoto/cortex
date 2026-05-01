import Cortex.Wire.Registry
import Cortex.Wire.Pure

/-!
## Overview

Proof-facing model of ADR 0039's Wire node boundary normal form.

## Context

ADR 0039 decomposes an admitted Wire node into four proof obligations:
ingress adaptation, local body execution, egress adaptation, and edge
compatibility. Existing Track 3 proofs already establish much of this for
CorePure output equations and registry-admitted edges, but the theorem
surface did not name the normal-form phases directly.

This module adds that explicit boundary vocabulary. It remains a proof model:
registered executor bodies are represented by caller-supplied certificates,
while CorePure nodes get concrete ingress/body/egress theorems from the
existing evaluator and admission lemmas.

## Theorem Split

The generic `NodeBoundaryNormalForm` carrier records the three intra-node
phase soundness obligations. `EdgeSound` records the inter-node obligation
that a producer output boundary satisfies a consumer input boundary. The
CorePure section instantiates the phase theorems against `PureNode`; the
registry section exposes edge compatibility from `edgeAdmittedBy`.
-/

namespace Cortex.Wire

open Cortex.Graph

namespace NodeBoundary

/-! ## Generic Boundary Model -/

/-- A named port environment: a port either exposes a value or is absent. -/
abbrev PortEnv (name value : Type) :=
  name → Option value

/-- A port environment exposes exactly the declared finite port set. -/
def ExposesExactly
    {name value : Type}
    [DecidableEq name]
    (env : PortEnv name value)
    (ports : Finset name) : Prop :=
  ∀ name, name ∈ ports ↔ ∃ value, env name = some value

/-- Every exposed port value satisfies its declared contract predicate. -/
def SatisfiesContracts
    {name value : Type}
    [DecidableEq name]
    (contractOk : name → value → Prop)
    (ports : Finset name)
    (env : PortEnv name value) : Prop :=
  ∀ name value, env name = some value → name ∈ ports ∧ contractOk name value

/-- Ingress soundness: valid input environments prepare valid body arguments. -/
def IngressSound
    {inputEnv bodyArg error : Type}
    (ingress : inputEnv → Except error bodyArg)
    (validInput : inputEnv → Prop)
    (validBodyArg : bodyArg → Prop) : Prop :=
  ∀ inputEnv bodyArg,
    validInput inputEnv →
      ingress inputEnv = Except.ok bodyArg →
        validBodyArg bodyArg

/-- Body soundness: valid body arguments produce valid body results on success. -/
def BodySound
    {bodyArg bodyResult error : Type}
    (body : bodyArg → Except error bodyResult)
    (validBodyArg : bodyArg → Prop)
    (validBodyResult : bodyResult → Prop) : Prop :=
  ∀ bodyArg bodyResult,
    validBodyArg bodyArg →
      body bodyArg = Except.ok bodyResult →
        validBodyResult bodyResult

/-- Egress soundness: valid body results expose valid output environments on success. -/
def EgressSound
    {bodyResult outputEnv error : Type}
    (egress : bodyResult → Except error outputEnv)
    (validBodyResult : bodyResult → Prop)
    (validOutput : outputEnv → Prop) : Prop :=
  ∀ bodyResult outputEnv,
    validBodyResult bodyResult →
      egress bodyResult = Except.ok outputEnv →
        validOutput outputEnv

/-- ADR 0039 node normal-form carrier. -/
structure NodeBoundaryNormalForm
    (inputEnv bodyArg bodyResult outputEnv error : Type) where
  /-- Boundary adapter from input-port environment to local body argument. -/
  ingress : inputEnv → Except error bodyArg
  /-- Local node body. -/
  body : bodyArg → Except error bodyResult
  /-- Boundary adapter from body result to output-port environment. -/
  egress : bodyResult → Except error outputEnv
  /-- Input-port environments admitted for this node. -/
  validInput : inputEnv → Prop
  /-- Body arguments accepted by the local body. -/
  validBodyArg : bodyArg → Prop
  /-- Body results accepted by egress. -/
  validBodyResult : bodyResult → Prop
  /-- Output-port environments exposed to graph edges. -/
  validOutput : outputEnv → Prop
  /-- Ingress preserves the input-to-body boundary contract. -/
  ingress_preserves : IngressSound ingress validInput validBodyArg
  /-- The body preserves its local contract on success. -/
  body_preserves : BodySound body validBodyArg validBodyResult
  /-- Egress preserves the body-to-output boundary contract. -/
  egress_preserves : EgressSound egress validBodyResult validOutput

/-- Generic ADR 0039 ingress theorem surface. -/
theorem ingress_sound
    {inputEnv bodyArg bodyResult outputEnv error : Type}
    (form : NodeBoundaryNormalForm inputEnv bodyArg bodyResult outputEnv error) :
    IngressSound form.ingress form.validInput form.validBodyArg :=
  form.ingress_preserves

/-- Generic ADR 0039 body theorem surface. -/
theorem body_sound
    {inputEnv bodyArg bodyResult outputEnv error : Type}
    (form : NodeBoundaryNormalForm inputEnv bodyArg bodyResult outputEnv error) :
    BodySound form.body form.validBodyArg form.validBodyResult :=
  form.body_preserves

/-- Generic ADR 0039 egress theorem surface. -/
theorem egress_sound
    {inputEnv bodyArg bodyResult outputEnv error : Type}
    (form : NodeBoundaryNormalForm inputEnv bodyArg bodyResult outputEnv error) :
    EgressSound form.egress form.validBodyResult form.validOutput :=
  form.egress_preserves

/-- Edge soundness: a producer output boundary satisfies a consumer input obligation. -/
def EdgeSound
    {producerOutput consumerInput : Type}
    (producerValid : producerOutput → Prop)
    (consumerSatisfied : consumerInput → Prop)
    (edgeSatisfies : producerOutput → consumerInput → Prop) : Prop :=
  ∀ producerOutput consumerInput,
    producerValid producerOutput →
      edgeSatisfies producerOutput consumerInput →
        consumerSatisfied consumerInput

/-- Generic ADR 0039 edge theorem surface. -/
theorem edge_sound
    {producerOutput consumerInput : Type}
    {producerValid : producerOutput → Prop}
    {consumerSatisfied : consumerInput → Prop}
    {edgeSatisfies : producerOutput → consumerInput → Prop}
    (hEdge : EdgeSound producerValid consumerSatisfied edgeSatisfies) :
    ∀ producerOutput consumerInput,
      producerValid producerOutput →
        edgeSatisfies producerOutput consumerInput →
          consumerSatisfied consumerInput :=
  hEdge

/-! ## Registered Executor Body Boundary -/

/-- Registered executor bodies are represented by explicit certificates at this layer.

Wire can prove that the body is the only place authority enters the node. It cannot prove
arbitrary host code correct without a registry, certificate, or host-binding theorem supplied by
the caller. -/
structure RegisteredBodyCertificate
    (bodyArg bodyResult error : Type)
    (body : bodyArg → Except error bodyResult)
    (validBodyArg : bodyArg → Prop)
    (validBodyResult : bodyResult → Prop) : Prop where
  /-- Certified registered bodies preserve their local contract on successful return. -/
  body_preserves : BodySound body validBodyArg validBodyResult

/-- Registered executor `body_sound` is exactly the supplied certificate. -/
theorem registered_body_sound
    {bodyArg bodyResult error : Type}
    {body : bodyArg → Except error bodyResult}
    {validBodyArg : bodyArg → Prop}
    {validBodyResult : bodyResult → Prop}
    (certificate :
      RegisteredBodyCertificate bodyArg bodyResult error body validBodyArg validBodyResult) :
    BodySound body validBodyArg validBodyResult :=
  certificate.body_preserves

/-! ## CorePure Normal Form -/

namespace CorePure

abbrev Env :=
  _root_.Cortex.Wire.CorePure.Env

abbrev EvalError :=
  _root_.Cortex.Wire.CorePure.EvalError

abbrev Name :=
  _root_.Cortex.Wire.CorePure.Name

abbrev Value :=
  _root_.Cortex.Wire.CorePure.Value

abbrev PureNode :=
  _root_.Cortex.Wire.CorePure.PureNode

abbrev StaticContext :=
  _root_.Cortex.Wire.CorePure.StaticContext

/-- CorePure input validity includes static-environment matching and output-contract evidence. -/
def InputValid
    (ctx : StaticContext)
    (node : PureNode)
    (contractOk : Name → Value → Prop)
    (entryEnv : Env) : Prop :=
  _root_.Cortex.Wire.CorePure.EnvMatchesStatic entryEnv ctx ∧
    ∀ outerEnv localEnv,
      _root_.Cortex.Wire.CorePure.evalBindings entryEnv node.bindings =
          Except.ok outerEnv →
        _root_.Cortex.Wire.CorePure.evalWhereEnv outerEnv node.whereExpr =
            Except.ok localEnv →
          _root_.Cortex.Wire.CorePure.OutputExpressionsSatisfyContracts
            contractOk
            localEnv
            node.outputs

/-- CorePure body arguments are prepared local environments plus output-contract evidence. -/
def BodyArgValid
    (ctx : StaticContext)
    (node : PureNode)
    (contractOk : Name → Value → Prop)
    (localEnv : Env) : Prop :=
  (∃ whereFields,
    node.whereFields ctx = some whereFields ∧
      _root_.Cortex.Wire.CorePure.EnvMatchesStatic
        localEnv
        (_root_.Cortex.Wire.CorePure.StaticContext.hideFields whereFields ctx)) ∧
    _root_.Cortex.Wire.CorePure.OutputExpressionsSatisfyContracts
      contractOk
      localEnv
      node.outputs

/-- The raw CorePure body result keeps the prepared environment next to the lookup it produced. -/
structure BodyResult (node : PureNode) where
  /-- Prepared local environment used to evaluate the output equations. -/
  localEnv : Env
  /-- Raw output lookup before the egress phase exposes it to graph edges. -/
  lookup : Name → Option Value

/-- A CorePure body result exposes all declared output ports and retains contract evidence. -/
def BodyResultValid
    (node : PureNode)
    (contractOk : Name → Value → Prop)
    (result : BodyResult node) : Prop :=
  ExposesExactly result.lookup node.outputPorts ∧
    _root_.Cortex.Wire.CorePure.evalOutputEquations result.localEnv node.outputs =
        Except.ok result.lookup ∧
      _root_.Cortex.Wire.CorePure.OutputExpressionsSatisfyContracts
        contractOk
        result.localEnv
        node.outputs

/-- A CorePure egress output is exactly the declared output-port environment with contracts. -/
def OutputValid
    (node : PureNode)
    (contractOk : Name → Value → Prop)
    (lookup : Name → Option Value) : Prop :=
  ExposesExactly lookup node.outputPorts ∧
    SatisfiesContracts contractOk node.outputPorts lookup

/-- CorePure ingress evaluates top-level bindings and opens the optional `where` record. -/
def ingress (entryEnv : Env)
    (node : PureNode) :
    Except EvalError Env :=
  match _root_.Cortex.Wire.CorePure.evalBindings entryEnv node.bindings with
  | Except.error err => Except.error err
  | Except.ok outerEnv =>
      _root_.Cortex.Wire.CorePure.evalWhereEnv outerEnv node.whereExpr

/-- CorePure body evaluation runs output equations in the prepared local environment. -/
def body (localEnv : Env)
    (node : PureNode) :
    Except EvalError (BodyResult node) :=
  match _root_.Cortex.Wire.CorePure.evalOutputEquations localEnv node.outputs with
  | Except.error err => Except.error err
  | Except.ok lookup =>
      Except.ok
        { localEnv := localEnv
          lookup := lookup }

/-- CorePure egress exposes the raw lookup produced by the body phase. -/
def egress {node : PureNode}
    (result : BodyResult node) :
    Except EvalError (Name → Option Value) :=
  Except.ok result.lookup

/-- Successful CorePure output evaluation exposes exactly the declared output ports. -/
theorem corePure_output_exposesExactly
    {ctx : StaticContext}
    {localEnv : Env}
    {node : PureNode}
    {lookup : Name → Option Value}
    (hNode : _root_.Cortex.Wire.CorePure.PureNodeAdmitted ctx node)
    (hOutputEval :
      _root_.Cortex.Wire.CorePure.evalOutputEquations localEnv node.outputs =
        Except.ok lookup) :
    ExposesExactly lookup node.outputPorts := by
  intro name
  constructor
  · intro hPort
    have hOutputKey : name ∈ node.outputKeys := by
      rw [hNode.outputs_match]
      exact hPort
    have hKeySet :
        name ∈ _root_.Cortex.Wire.CorePure.outputEquationKeySet node.outputs := by
      simpa [_root_.Cortex.Wire.CorePure.PureNode.outputKeys] using hOutputKey
    exact
      _root_.Cortex.Wire.CorePure.evalOutputEquations_keys_present
        hOutputEval
        hKeySet
  · intro hExists
    rcases hExists with ⟨value, hLookup⟩
    have hMember :
        name ∈ _root_.Cortex.Wire.CorePure.outputEquationKeySet node.outputs :=
      _root_.Cortex.Wire.CorePure.evalOutputEquations_keys_subset
        hOutputEval
        hLookup
    have hOutputKey : name ∈ node.outputKeys := by
      simpa [_root_.Cortex.Wire.CorePure.PureNode.outputKeys] using hMember
    simpa [hNode.outputs_match] using hOutputKey

/-- CorePure ingress discharges the generic `IngressSound` obligation. -/
theorem corePure_ingress_sound
    {ctx : StaticContext}
    {node : PureNode}
    {contractOk : Name → Value → Prop}
    (hNode : _root_.Cortex.Wire.CorePure.PureNodeAdmitted ctx node)
    : IngressSound
        (fun entryEnv => ingress entryEnv node)
        (InputValid ctx node contractOk)
        (BodyArgValid ctx node contractOk) := by
  intro entryEnv localEnv hInput hIngress
  cases hBindings : _root_.Cortex.Wire.CorePure.evalBindings entryEnv node.bindings with
  | error err =>
      simp [ingress, hBindings] at hIngress
  | ok outerEnv =>
      cases hWhere :
          _root_.Cortex.Wire.CorePure.evalWhereEnv outerEnv node.whereExpr with
      | error err =>
          simp [ingress, hBindings, hWhere] at hIngress
      | ok preparedEnv =>
          simp [ingress, hBindings, hWhere] at hIngress
          cases hIngress
          have hLocalMatch :
              ∃ whereFields,
                node.whereFields ctx = some whereFields ∧
                  _root_.Cortex.Wire.CorePure.EnvMatchesStatic
                    localEnv
                    (_root_.Cortex.Wire.CorePure.StaticContext.hideFields
                      whereFields
                      ctx) :=
            _root_.Cortex.Wire.CorePure.pureNode_evalWhereEnv_localEnv_match
              hNode
              hInput.1
              hBindings
              hWhere
          exact
            ⟨ hLocalMatch,
              hInput.2 outerEnv localEnv hBindings hWhere ⟩

/-- CorePure body discharges the generic `BodySound` obligation. -/
theorem corePure_body_sound
    {ctx : StaticContext}
    {node : PureNode}
    {contractOk : Name → Value → Prop}
    (hNode : _root_.Cortex.Wire.CorePure.PureNodeAdmitted ctx node)
    : BodySound
        (fun localEnv => body localEnv node)
        (BodyArgValid ctx node contractOk)
        (BodyResultValid node contractOk) := by
  intro localEnv result hArg hBody
  cases hOutput :
      _root_.Cortex.Wire.CorePure.evalOutputEquations localEnv node.outputs with
  | error err =>
      simp [body, hOutput] at hBody
  | ok lookup =>
      simp [body, hOutput] at hBody
      cases hBody
      exact
        ⟨ corePure_output_exposesExactly hNode hOutput,
          hOutput,
          hArg.2 ⟩

/-- CorePure egress discharges the generic `EgressSound` obligation. -/
theorem corePure_egress_sound
    {node : PureNode}
    {contractOk : Name → Value → Prop}
    : EgressSound
        (fun result : BodyResult node => egress result)
        (BodyResultValid node contractOk)
        (OutputValid node contractOk) := by
  intro result lookup hResult hEgress
  simp [egress] at hEgress
  cases hEgress
  constructor
  · exact hResult.1
  · intro name value hLookup
    constructor
    · exact (hResult.1 name).2 ⟨value, hLookup⟩
    · exact
        _root_.Cortex.Wire.CorePure.evalOutputEquations_values_satisfy_outputContracts
          hResult.2.1
          hResult.2.2
          name
          value
          hLookup

/-- CorePure instantiates the generic ADR 0039 node-boundary normal form. -/
def corePureBoundary
    (ctx : StaticContext)
    (node : PureNode)
    (contractOk : Name → Value → Prop)
    (hNode : _root_.Cortex.Wire.CorePure.PureNodeAdmitted ctx node) :
    NodeBoundaryNormalForm
      Env
      Env
      (BodyResult node)
      (Name → Option Value)
      EvalError :=
  { ingress := fun entryEnv => ingress entryEnv node
    body := fun localEnv => body localEnv node
    egress := fun result => egress result
    validInput := InputValid ctx node contractOk
    validBodyArg := BodyArgValid ctx node contractOk
    validBodyResult := BodyResultValid node contractOk
    validOutput := OutputValid node contractOk
    ingress_preserves := corePure_ingress_sound hNode
    body_preserves := corePure_body_sound hNode
    egress_preserves := corePure_egress_sound }

/-- The existing full CorePure evaluator factors through ingress, body, and egress. -/
theorem corePure_evalOutputs_eq_egress_after_body_after_ingress
    (entryEnv : Env)
    (node : PureNode) :
    node.evalOutputs entryEnv =
      match ingress entryEnv node with
      | Except.error err => Except.error err
      | Except.ok localEnv =>
          match body localEnv node with
          | Except.error err => Except.error err
          | Except.ok result => egress result := by
  cases hBindings : _root_.Cortex.Wire.CorePure.evalBindings entryEnv node.bindings with
  | error err =>
      simp [
        _root_.Cortex.Wire.CorePure.PureNode.evalOutputs,
        ingress,
        hBindings
      ]
  | ok outerEnv =>
      cases hWhere :
          _root_.Cortex.Wire.CorePure.evalWhereEnv outerEnv node.whereExpr with
      | error err =>
          simp [
            _root_.Cortex.Wire.CorePure.PureNode.evalOutputs,
            ingress,
            hBindings,
            hWhere
          ]
      | ok localEnv =>
          cases hOutput :
              _root_.Cortex.Wire.CorePure.evalOutputEquations
                localEnv
                node.outputs with
          | error err =>
              simp [
                _root_.Cortex.Wire.CorePure.PureNode.evalOutputs,
                ingress,
                body,
                hBindings,
                hWhere,
                hOutput
              ]
          | ok lookup =>
              simp [
                _root_.Cortex.Wire.CorePure.PureNode.evalOutputs,
                ingress,
                body,
                egress,
                hBindings,
                hWhere,
                hOutput
              ]

end CorePure

/-! ## Registry Edge Soundness -/

/-- Registry producer outputs are valid exactly when their contracts are known. -/
def RegistryProducerValid
    {executor config contract authority : Type}
    [DecidableEq contract]
    (registry : ExecutorRegistry executor config contract authority)
    (outputContract : contract) : Prop :=
  registry.contractKnown outputContract

/-- Registry consumer inputs are satisfied exactly when their contracts are known. -/
def RegistryConsumerSatisfied
    {executor config contract authority : Type}
    [DecidableEq contract]
    (registry : ExecutorRegistry executor config contract authority)
    (inputContract : contract) : Prop :=
  registry.contractKnown inputContract

/-- The registry-derived edge predicate couples target-knownness with compatibility. -/
def registryEdgeSatisfies
    {executor config contract authority : Type}
    [DecidableEq contract]
    (registry : ExecutorRegistry executor config contract authority)
    (outputContract inputContract : contract) : Prop :=
  registry.contractKnown inputContract ∧
    registry.contractsCompatible outputContract inputContract

/-- Registry contract compatibility instantiates ADR 0039's value-level `EdgeSound` rule. -/
theorem registry_contract_edge_sound
    {executor config contract authority : Type}
    [DecidableEq contract]
    (registry : ExecutorRegistry executor config contract authority) :
    EdgeSound
      (RegistryProducerValid registry)
      (RegistryConsumerSatisfied registry)
      (registryEdgeSatisfies registry) := by
  intro _outputContract _inputContract _hOutputKnown hEdgeSatisfies
  exact hEdgeSatisfies.1

/-- Registry-admitted edges expose known compatible endpoint contracts. -/
theorem registry_edge_contracts
    {executor config contract authority : Type}
    [DecidableEq contract]
    {registry : ExecutorRegistry executor config contract authority}
    {source target : StagedExecutorNode executor config authority}
    (hEdge : edgeAdmittedBy registry source target) :
    ∃ outputContract inputContract : contract,
      registry.contractKnown outputContract ∧
        registry.contractKnown inputContract ∧
          registry.contractsCompatible outputContract inputContract := by
  rcases hEdge with
    ⟨ _sourceEntry,
      _targetEntry,
      _hSourceResolve,
      _hTargetResolve,
      outputContract,
      inputContract,
      _hOutput,
      _hInput,
      hOutputKnown,
      hInputKnown,
      hCompatible ⟩
  exact ⟨outputContract, inputContract, hOutputKnown, hInputKnown, hCompatible⟩

/-- Registry-admitted graph edges produce endpoint contracts satisfying `EdgeSound`. -/
theorem registry_edge_sound
    {executor config contract authority : Type}
    [DecidableEq contract]
    {registry : ExecutorRegistry executor config contract authority}
    {source target : StagedExecutorNode executor config authority}
    (hEdge : edgeAdmittedBy registry source target) :
    ∃ outputContract inputContract : contract,
      RegistryProducerValid registry outputContract ∧
        registryEdgeSatisfies registry outputContract inputContract ∧
          RegistryConsumerSatisfied registry inputContract := by
  obtain ⟨ outputContract,
    inputContract,
    hOutputKnown,
    hInputKnown,
    hCompatible ⟩ := registry_edge_contracts hEdge
  have hEdgeRule := registry_contract_edge_sound registry
  have hEdgeSatisfies :
      registryEdgeSatisfies registry outputContract inputContract :=
    ⟨hInputKnown, hCompatible⟩
  exact
    ⟨ outputContract,
      inputContract,
      hOutputKnown,
      hEdgeSatisfies,
      hEdgeRule outputContract inputContract hOutputKnown hEdgeSatisfies ⟩

/-- A registry boundary gives edge soundness for every denoted graph edge. -/
theorem registryBoundary_edge_sound
    {executor config contract authority : Type}
    [DecidableEq contract]
    [DecidableEq (StagedExecutorNode executor config authority)]
    {registry : ExecutorRegistry executor config contract authority}
    {g : Graph (StagedExecutorNode executor config authority)}
    (hBoundary : registryBoundary registry g)
    {source target : StagedExecutorNode executor config authority}
    (hEdge : (source, target) ∈ (denote g).edges) :
    ∃ outputContract inputContract : contract,
      RegistryProducerValid registry outputContract ∧
        registryEdgeSatisfies registry outputContract inputContract ∧
          RegistryConsumerSatisfied registry inputContract :=
  registry_edge_sound (registryBoundary_edges hBoundary source target hEdge)

end NodeBoundary

end Cortex.Wire
