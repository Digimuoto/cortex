import Mathlib.Data.Finset.Basic
import Cortex.Wire.PortLinearity

/-!
## Overview

Proof-facing Wire elaboration IR.

## Context

This module is the first Lean-owned carrier for Wire source after parsing and
source inclusion have already happened. It does not model the text parser,
filesystem includes, runtime executors, or Pulse execution. Those remain
outside the kernel. The purpose here is narrower: name the static objects that
future certified elaboration will consume and separate raw source-shaped input
from accepted proof objects.

Isolated accepted node declarations project mechanically to the
source-linearity layer's open `nodePorts` object. Non-trivial source linearity,
raw graph admission, executor-registry correspondence, and identifier-shape
validation are intentionally later obligations.
-/

namespace Cortex.Wire
namespace ElaborationIR

/-! ## Nominal Identifiers -/

/-!
Nominal identifiers in this carrier preserve namespace separation only. Values
such as `NodeId`, `BindingName`, and `ExecutorRef` do not yet prove non-emptiness,
source identifier grammar, generated-name freshness, or registry membership by
construction. Local accepted carriers below add non-empty name obligations;
full source grammar validation and registry correspondence remain later checks.
-/

/-- Minimal local validity for a nominal source token represented as a `String`.

The executable grammar is stricter (`[A-Za-z_][A-Za-z0-9_]*`). This carrier uses
the smallest proof-side invariant needed to rule out the empty-token countermodel
without pretending to mechanize the parser. Downstream consumers that rely on
full source identifier shape must re-check or carry a stronger grammar witness. -/
def NominalNameValid (name : String) : Prop :=
  name ≠ ""

instance nominalNameValidDecidable (name : String) : Decidable (NominalNameValid name) :=
  inferInstanceAs (Decidable (name ≠ ""))

/-- Nominal contract identifier. -/
structure ContractId where
  /-- Human/source-facing contract name. -/
  name : String
  deriving DecidableEq, Repr

namespace ContractId

/-- Contract identifiers admitted into local accepted frontiers are non-empty. -/
def Valid (contract : ContractId) : Prop :=
  NominalNameValid contract.name

instance validDecidable (contract : ContractId) : Decidable contract.Valid :=
  inferInstanceAs (Decidable (NominalNameValid contract.name))

end ContractId

/-- Nominal record-field label. -/
structure FieldLabel where
  /-- Human/source-facing field name. -/
  name : String
  deriving DecidableEq, Repr

namespace FieldLabel

/-- Field labels admitted into local accepted frontiers are non-empty. -/
def Valid (field : FieldLabel) : Prop :=
  NominalNameValid field.name

instance validDecidable (field : FieldLabel) : Decidable field.Valid :=
  inferInstanceAs (Decidable (NominalNameValid field.name))

end FieldLabel

/-- Nominal node identifier after source inclusion and macro expansion. -/
structure NodeId where
  /-- Source-stable node name. -/
  name : String
  deriving DecidableEq, Repr

namespace NodeId

/-- Accepted node identifiers are non-empty at this local layer. -/
def Valid (node : NodeId) : Prop :=
  NominalNameValid node.name

instance validDecidable (node : NodeId) : Decidable node.Valid :=
  inferInstanceAs (Decidable (NominalNameValid node.name))

end NodeId

/-- Nominal graph or value binding name. -/
structure BindingName where
  /-- Source-stable binding name. -/
  name : String
  deriving DecidableEq, Repr

namespace BindingName

/-- Binding identifiers are non-empty when a future admission layer chooses to enforce them. -/
def Valid (binding : BindingName) : Prop :=
  NominalNameValid binding.name

instance validDecidable (binding : BindingName) : Decidable binding.Valid :=
  inferInstanceAs (Decidable (NominalNameValid binding.name))

end BindingName

/-- Nominal select-arm key as written in source. -/
structure SelectArmKey where
  /-- Source-stable selector variant token. -/
  name : String
  deriving DecidableEq, Repr

namespace SelectArmKey

/-- Select-arm keys are non-empty when a future select admission layer chooses to enforce them. -/
def Valid (key : SelectArmKey) : Prop :=
  NominalNameValid key.name

instance validDecidable (key : SelectArmKey) : Decidable key.Valid :=
  inferInstanceAs (Decidable (NominalNameValid key.name))

end SelectArmKey

/-- Nominal kind name used by `make` and `makeEach` forms. -/
structure KindName where
  /-- Source-stable kind name. -/
  name : String
  deriving DecidableEq, Repr

namespace KindName

/-- Accepted kind identifiers are non-empty at this local layer. -/
def Valid (kind : KindName) : Prop :=
  NominalNameValid kind.name

instance validDecidable (kind : KindName) : Decidable kind.Valid :=
  inferInstanceAs (Decidable (NominalNameValid kind.name))

end KindName

/-- Nominal executor reference. Executor bodies and registry membership remain opaque here. -/
structure ExecutorRef where
  /-- Source-facing executor name. -/
  name : String
  deriving DecidableEq, Repr

namespace ExecutorRef

/-- Executor references admitted into node bodies are non-empty at this local layer. -/
def Valid (executor : ExecutorRef) : Prop :=
  NominalNameValid executor.name

instance validDecidable (executor : ExecutorRef) : Decidable executor.Valid :=
  inferInstanceAs (Decidable (NominalNameValid executor.name))

end ExecutorRef

/-! ## Ports, Contracts, And Static Values -/

/-- One typed port in a Wire node frontier. -/
structure PortSignature where
  /-- Port label as it appears in source. -/
  label : FieldLabel
  /-- Contract expected at this port. -/
  contract : ContractId
  deriving DecidableEq, Repr

namespace PortSignature

/-- Locally accepted port signatures have non-empty labels and contract names. -/
def Valid (port : PortSignature) : Prop :=
  port.label.Valid ∧ port.contract.Valid

end PortSignature

/-- Output-direction port signature wrapper for the source-linearity lift.

Wire allows the same label and contract on opposite frontier directions. The
wrapper keeps output instances type-distinct from input instances when projecting
accepted declarations to `LinearPortGraph`. -/
structure OutputPortSignature where
  /-- Underlying accepted source port signature. -/
  signature : PortSignature
  deriving DecidableEq, Repr

/-- Input-direction port signature wrapper for the source-linearity lift.

This is intentionally separate from `OutputPortSignature`: direction is part of
Wire port identity even when labels and contracts match. -/
structure InputPortSignature where
  /-- Underlying accepted source port signature. -/
  signature : PortSignature
  deriving DecidableEq, Repr

/-- Every port in a finite frontier is locally valid. -/
def PortSignaturesValid (ports : Finset PortSignature) : Prop :=
  ∀ port, port ∈ ports → port.Valid

/-- Every port in a source-order frontier list is locally valid. -/
def PortSignatureListValid (ports : List PortSignature) : Prop :=
  ∀ port, port ∈ ports → port.Valid

/-- Source-order frontier lists have no repeated labels before `Finset` canonicalization. -/
def PortLabelListUnique (ports : List PortSignature) : Prop :=
  (ports.map PortSignature.label).Nodup

/-- Accepted frontier ports must be unique by source label, not only by full signature. -/
def PortLabelsUnique (ports : Finset PortSignature) : Prop :=
  ∀ ⦃left right : PortSignature⦄,
    left ∈ ports → right ∈ ports → left.label = right.label → left = right

/-- A valid source-order frontier list remains valid after `Finset` canonicalization. -/
theorem portSignatureListValid_toFinset
    {ports : List PortSignature}
    (hValid : PortSignatureListValid ports) :
    PortSignaturesValid ports.toFinset := by
  intro port hPort
  exact hValid port (List.mem_toFinset.mp hPort)

/-- Source-order label uniqueness means same-label members are the same port. -/
theorem portLabelListUnique_mem_eq
    {ports : List PortSignature}
    (hUnique : PortLabelListUnique ports)
    {left right : PortSignature}
    (hLeft : left ∈ ports)
    (hRight : right ∈ ports)
    (hLabel : left.label = right.label) :
    left = right := by
  induction ports generalizing left right with
  | nil =>
      cases hLeft
  | cons head tail ih =>
      simp only [PortLabelListUnique, List.map_cons, List.nodup_cons] at hUnique
      rcases hUnique with ⟨hHeadFresh, hTailUnique⟩
      simp only [List.mem_cons] at hLeft hRight
      rcases hLeft with hLeftHead | hLeftTail
      · rcases hRight with hRightHead | hRightTail
        · rw [hLeftHead, hRightHead]
        · rw [hLeftHead] at hLabel
          have hRightLabel : right.label ∈ tail.map PortSignature.label :=
            List.mem_map_of_mem (f := PortSignature.label) hRightTail
          rw [← hLabel] at hRightLabel
          exact False.elim (hHeadFresh hRightLabel)
      · rcases hRight with hRightHead | hRightTail
        · rw [hRightHead] at hLabel
          have hLeftLabel : left.label ∈ tail.map PortSignature.label :=
            List.mem_map_of_mem (f := PortSignature.label) hLeftTail
          rw [hLabel] at hLeftLabel
          exact False.elim (hHeadFresh hLeftLabel)
        · exact ih hTailUnique hLeftTail hRightTail hLabel

/-- Source-order label uniqueness remains label uniqueness after `Finset` canonicalization. -/
theorem portLabelListUnique_toFinset
    {ports : List PortSignature}
    (hUnique : PortLabelListUnique ports) :
    PortLabelsUnique ports.toFinset := by
  intro left right hLeft hRight hLabel
  exact
    portLabelListUnique_mem_eq hUnique
      (List.mem_toFinset.mp hLeft)
      (List.mem_toFinset.mp hRight)
      hLabel

/-- A singleton frontier is label-unique. -/
theorem singleton_portLabelsUnique (port : PortSignature) :
    PortLabelsUnique ({port} : Finset PortSignature) := by
  intro left right hLeft hRight _hLabel
  have hLeftEq : left = port := Finset.mem_singleton.mp hLeft
  have hRightEq : right = port := Finset.mem_singleton.mp hRight
  rw [hLeftEq, hRightEq]

/-- A singleton frontier is valid when its only port is valid. -/
theorem singleton_portSignaturesValid
    {port : PortSignature}
    (hPort : port.Valid) :
    PortSignaturesValid ({port} : Finset PortSignature) := by
  intro candidate hCandidate
  have hEq : candidate = port := Finset.mem_singleton.mp hCandidate
  rw [hEq]
  exact hPort

/-- One field in a nominal record contract. -/
structure RecordFieldDecl where
  /-- Record field label. -/
  field : FieldLabel
  /-- Contract carried by that field. -/
  contract : ContractId
  deriving DecidableEq, Repr

namespace RecordFieldDecl

/-- Locally accepted record fields have non-empty labels and contract names. -/
def Valid (field : RecordFieldDecl) : Prop :=
  field.field.Valid ∧ field.contract.Valid

end RecordFieldDecl

/-- Every field in a source-order record declaration is locally valid. -/
def RecordFieldListValid (fields : List RecordFieldDecl) : Prop :=
  ∀ field, field ∈ fields → field.Valid

/-- Record declarations have no repeated field labels before admission. -/
def RecordFieldLabelsUnique (fields : List RecordFieldDecl) : Prop :=
  (fields.map RecordFieldDecl.field).Nodup

/-- Nominal record contract shape after imports and source includes are resolved. -/
structure RecordContractDecl where
  /-- Contract identifier for the record. -/
  contract : ContractId
  /-- Declared fields. Raw declarations keep list shape so duplicate labels can be diagnosed. -/
  fields : List RecordFieldDecl
  deriving DecidableEq, Repr

namespace RecordContractDecl

/-- Local admission witness for a nominal record contract declaration. -/
structure LocallyAdmissible (decl : RecordContractDecl) : Prop where
  /-- The contract identifier is non-empty at the local carrier layer. -/
  contractValid : decl.contract.Valid
  /-- Every record field has locally valid label and contract names. -/
  fieldsValid : RecordFieldListValid decl.fields
  /-- Source-order record fields are unique by label. -/
  fieldLabelsUnique : RecordFieldLabelsUnique decl.fields

end RecordContractDecl

/-- Accepted nominal record contract declaration after local field-shape admission. -/
structure AcceptedRecordContractDecl where
  /-- Accepted contract identifier. -/
  contract : ContractId
  /-- Accepted contract identifiers are non-empty at this local layer. -/
  contractValid : contract.Valid
  /-- Accepted record fields in source order. -/
  fields : List RecordFieldDecl
  /-- Accepted record fields have locally valid labels and contract names. -/
  fieldsValid : RecordFieldListValid fields
  /-- Accepted record fields are unique by source label. -/
  fieldLabelsUnique : RecordFieldLabelsUnique fields
  deriving DecidableEq

namespace RecordContractDecl

/-- Locally admitted raw record contracts become accepted record contract declarations. -/
def toAccepted
    (decl : RecordContractDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    AcceptedRecordContractDecl :=
  { contract := decl.contract
    contractValid := hAdmissible.contractValid
    fields := decl.fields
    fieldsValid := hAdmissible.fieldsValid
    fieldLabelsUnique := hAdmissible.fieldLabelsUnique }

end RecordContractDecl

namespace RecordContractDecl

/-- Raw record-field contracts are declared by the surrounding raw module shell. -/
def FieldContractsClosed
    (decl : RecordContractDecl)
    (contracts : List RecordContractDecl) :
    Prop :=
  ∀ field, field ∈ decl.fields → field.contract ∈ contracts.map RecordContractDecl.contract

end RecordContractDecl

/-- Accepted record-field contracts are declared by the surrounding accepted module shell. -/
def AcceptedRecordFieldContractsClosed
    (decl : AcceptedRecordContractDecl)
    (contracts : List AcceptedRecordContractDecl) :
    Prop :=
  ∀ field, field ∈ decl.fields → field.contract ∈ contracts.map AcceptedRecordContractDecl.contract

/-- Static value fragment visible to Lean elaboration after source inclusion.

This is deliberately a shape language. It is not an evaluator for Wire, and it
does not read files. By the time a value reaches this carrier, any
`include_str`/`include_dir`-style source inclusion has already been resolved by
the external front end.

This layer intentionally does not provide decidable equality for static values.
Downstream modules that need equality over resolved values should first supply a
structural instance for this recursive carrier, then derive equality for the
larger IR types built from it. -/
inductive StaticValue where
  | string (value : String)
  | bool (value : Bool)
  | nat (value : Nat)
  | list (values : List StaticValue)
  /-- Record-shaped static value. Field-label uniqueness is intentionally not
  enforced at this raw value layer; future value admission must add it before
  projecting fields by name. -/
  | record (fields : List (FieldLabel × StaticValue))
  deriving Repr

/-! ## Node And Kind Declarations -/

/-- Boundary class for a node body.

Only the authority/effect boundary is represented. CorePure expressions,
executor payloads, runtime code, and executor-registry witnesses remain opaque
to this IR. -/
inductive NodeBodyBoundary where
  | corePure
  | executor (ref : ExecutorRef)
  | generatedPhantom
  deriving DecidableEq, Repr

namespace NodeBodyBoundary

/-- Local body-boundary validity checks only nominal executor spelling.

Registry membership and executor schema validation are represented separately so
this carrier can stay independent of the full registry model. -/
def LocalValid : NodeBodyBoundary → Prop
  | corePure => True
  | executor ref => ref.Valid
  | generatedPhantom => True

instance localValidDecidable (body : NodeBodyBoundary) : Decidable body.LocalValid :=
  match body with
  | corePure => isTrue trivial
  | executor ref => inferInstanceAs (Decidable ref.Valid)
  | generatedPhantom => isTrue trivial

end NodeBodyBoundary

/-! ### Kind Parameters -/

/-- Parameter class accepted by reusable Wire kind templates. -/
inductive KindParamClass where
  | portLabel
  | contract
  | value
  | configuredExecutor
  deriving DecidableEq, Repr

/-- One formal parameter on a reusable kind template.

The class mirrors the Wire grammar's `PortLabel`, `Contract`, `Value`, and
`ConfiguredExecutor` parameter categories. -/
structure KindParamDecl where
  /-- Parameter binding name inside the kind template. -/
  name : BindingName
  /-- Static class of value accepted at this parameter. -/
  paramClass : KindParamClass
  deriving DecidableEq, Repr

namespace KindParamDecl

/-- Locally accepted kind parameters have non-empty binding names. -/
def Valid (param : KindParamDecl) : Prop :=
  param.name.Valid

instance validDecidable (param : KindParamDecl) : Decidable param.Valid :=
  inferInstanceAs (Decidable param.name.Valid)

end KindParamDecl

/-- Every kind parameter in a source-order list is locally valid. -/
def KindParamListValid (params : List KindParamDecl) : Prop :=
  ∀ param, param ∈ params → param.Valid

/-- Kind parameter names are unique before admission. -/
def KindParamNamesUnique (params : List KindParamDecl) : Prop :=
  (params.map KindParamDecl.name).Nodup

/-- Raw node declaration after parsing/source inclusion but before admission.

Lists preserve source multiplicity so future admission can report duplicate
ports instead of losing them through `Finset` normalization. -/
structure RawNodeDecl where
  /-- Declared node name. -/
  node : NodeId
  /-- Input frontier in source order. -/
  inputs : List PortSignature
  /-- Output frontier in source order. -/
  outputs : List PortSignature
  /-- Opaque body/effect boundary. -/
  body : NodeBodyBoundary
  deriving DecidableEq, Repr

namespace RawNodeDecl

/-- Local admission witness for a raw node declaration.

This is still not graph admission: it covers only local name validity, port
validity, port-label uniqueness, and executor-reference spelling. -/
structure LocallyAdmissible (decl : RawNodeDecl) : Prop where
  /-- The node identifier is non-empty at the local carrier layer. -/
  nodeValid : decl.node.Valid
  /-- Every input port has locally valid label and contract names. -/
  inputPortsValid : PortSignatureListValid decl.inputs
  /-- Every output port has locally valid label and contract names. -/
  outputPortsValid : PortSignatureListValid decl.outputs
  /-- Source-order inputs are unique by label. -/
  inputLabelsUnique : PortLabelListUnique decl.inputs
  /-- Source-order outputs are unique by label. -/
  outputLabelsUnique : PortLabelListUnique decl.outputs
  /-- The body boundary is locally valid. -/
  bodyLocalValid : decl.body.LocalValid

end RawNodeDecl

/-- Accepted node declaration after local port-shape admission.

Accepted nodes use finite sets for canonical frontier membership and carry
explicit label-uniqueness proofs so equal labels with different contracts cannot
enter the accepted layer. -/
structure AcceptedNodeDecl where
  /-- Accepted node name. -/
  node : NodeId
  /-- Accepted node names are non-empty at this local layer. -/
  nodeValid : node.Valid
  /-- Accepted input frontier. -/
  inputs : Finset PortSignature
  /-- Accepted output frontier. -/
  outputs : Finset PortSignature
  /-- Accepted inputs have locally valid labels and contracts. -/
  inputPortsValid : PortSignaturesValid inputs
  /-- Accepted outputs have locally valid labels and contracts. -/
  outputPortsValid : PortSignaturesValid outputs
  /-- Accepted inputs are unique by source label. -/
  inputLabelsUnique : PortLabelsUnique inputs
  /-- Accepted outputs are unique by source label. -/
  outputLabelsUnique : PortLabelsUnique outputs
  /-- Opaque body/effect boundary. -/
  body : NodeBodyBoundary
  /-- Accepted body boundaries have locally valid executor references. -/
  bodyLocalValid : body.LocalValid
  deriving DecidableEq

namespace AcceptedNodeDecl

/-- Singleton node domain for an accepted source node. -/
def nodeSet (decl : AcceptedNodeDecl) : Finset NodeId :=
  {decl.node}

/-- Output source-port instances exposed by an accepted node. -/
def outputInstances
    (decl : AcceptedNodeDecl) :
    Finset (SourcePortInstance NodeId OutputPortSignature) :=
  decl.outputs.image (fun port => { node := decl.node, port := { signature := port } })

/-- Input source-port instances exposed by an accepted node. -/
def inputInstances
    (decl : AcceptedNodeDecl) :
    Finset (SourcePortInstance NodeId InputPortSignature) :=
  decl.inputs.image (fun port => { node := decl.node, port := { signature := port } })

/-- Mechanical projection lemma required by `LinearPortObject.nodePorts`.

At singleton-node level this is just the `Finset.image` fact that every produced
source-port instance was tagged with `decl.node`. The non-trivial domain-membership
invariant lives at future multi-node module composition. -/
theorem outputInstance_node_mem
    (decl : AcceptedNodeDecl)
    (output : SourcePortInstance NodeId OutputPortSignature)
    (hOutput : output ∈ decl.outputInstances) :
    output.node ∈ decl.nodeSet := by
  rcases Finset.mem_image.mp hOutput with ⟨_port, _hPort, hEq⟩
  subst hEq
  change decl.node ∈ ({decl.node} : Finset NodeId)
  exact Finset.mem_singleton.mpr rfl

/-- Mechanical projection lemma required by `LinearPortObject.nodePorts`.

At singleton-node level this is just the `Finset.image` fact that every produced
source-port instance was tagged with `decl.node`. The non-trivial domain-membership
invariant lives at future multi-node module composition. -/
theorem inputInstance_node_mem
    (decl : AcceptedNodeDecl)
    (input : SourcePortInstance NodeId InputPortSignature)
    (hInput : input ∈ decl.inputInstances) :
    input.node ∈ decl.nodeSet := by
  rcases Finset.mem_image.mp hInput with ⟨_port, _hPort, hEq⟩
  subst hEq
  change decl.node ∈ ({decl.node} : Finset NodeId)
  exact Finset.mem_singleton.mpr rfl

/-- Isolated accepted nodes lift to open source-linear port objects.

This lift has no internal port edges: every frontier endpoint remains open.
Composition and contraction are the later places where source linearity becomes
load-bearing. -/
def toLinearPortObject
    (decl : AcceptedNodeDecl) :
    LinearPortGraph.LinearPortObject NodeId OutputPortSignature InputPortSignature :=
  LinearPortGraph.LinearPortObject.nodePorts
    decl.nodeSet
    decl.outputInstances
    decl.inputInstances
    decl.outputInstance_node_mem
    decl.inputInstance_node_mem

end AcceptedNodeDecl

namespace RawNodeDecl

/-- Locally admitted raw nodes become accepted node declarations. -/
def toAccepted
    (decl : RawNodeDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    AcceptedNodeDecl :=
  { node := decl.node
    nodeValid := hAdmissible.nodeValid
    inputs := decl.inputs.toFinset
    outputs := decl.outputs.toFinset
    inputPortsValid := portSignatureListValid_toFinset hAdmissible.inputPortsValid
    outputPortsValid := portSignatureListValid_toFinset hAdmissible.outputPortsValid
    inputLabelsUnique := portLabelListUnique_toFinset hAdmissible.inputLabelsUnique
    outputLabelsUnique := portLabelListUnique_toFinset hAdmissible.outputLabelsUnique
    body := decl.body
    bodyLocalValid := hAdmissible.bodyLocalValid }

/-- Locally admitted raw nodes have an open source-linear lift. -/
theorem toAccepted_toLinearPortObject_portLinear
    (decl : RawNodeDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    ((decl.toAccepted hAdmissible).toLinearPortObject).graph.PortLinear :=
  (decl.toAccepted hAdmissible).toLinearPortObject.linear

end RawNodeDecl

/-- Raw kind declaration. Its body remains a source-template object, not a live graph. -/
structure RawKindDecl where
  /-- Kind name. -/
  kind : KindName
  /-- Formal parameters accepted by this reusable kind template. -/
  params : List KindParamDecl
  /-- Template input frontier. -/
  inputs : List PortSignature
  /-- Template output frontier. -/
  outputs : List PortSignature
  /-- Opaque body/effect boundary for nodes produced from this kind. -/
  body : NodeBodyBoundary
  deriving DecidableEq, Repr

namespace RawKindDecl

/-- Local admission witness for a raw kind declaration. -/
structure LocallyAdmissible (decl : RawKindDecl) : Prop where
  /-- The kind identifier is non-empty at the local carrier layer. -/
  kindValid : decl.kind.Valid
  /-- Every template parameter has a locally valid binding name. -/
  paramsValid : KindParamListValid decl.params
  /-- Source-order template parameters are unique by binding name. -/
  paramNamesUnique : KindParamNamesUnique decl.params
  /-- Every template input port has locally valid label and contract names. -/
  inputPortsValid : PortSignatureListValid decl.inputs
  /-- Every template output port has locally valid label and contract names. -/
  outputPortsValid : PortSignatureListValid decl.outputs
  /-- Source-order template inputs are unique by label. -/
  inputLabelsUnique : PortLabelListUnique decl.inputs
  /-- Source-order template outputs are unique by label. -/
  outputLabelsUnique : PortLabelListUnique decl.outputs
  /-- The kind body boundary is locally valid. -/
  bodyLocalValid : decl.body.LocalValid

end RawKindDecl

/-- Accepted kind declaration after local template admission.

The template frontier mirrors accepted node frontiers: membership is canonicalized
with finite sets, and label uniqueness remains an explicit accepted-layer
obligation. -/
structure AcceptedKindDecl where
  /-- Kind name. -/
  kind : KindName
  /-- Accepted kind names are non-empty at this local layer. -/
  kindValid : kind.Valid
  /-- Accepted formal parameters. -/
  params : List KindParamDecl
  /-- Accepted parameters have locally valid binding names. -/
  paramsValid : KindParamListValid params
  /-- Accepted parameters are unique by binding name. -/
  paramNamesUnique : KindParamNamesUnique params
  /-- Accepted template input frontier. -/
  inputs : Finset PortSignature
  /-- Accepted template output frontier. -/
  outputs : Finset PortSignature
  /-- Accepted template inputs have locally valid labels and contracts. -/
  inputPortsValid : PortSignaturesValid inputs
  /-- Accepted template outputs have locally valid labels and contracts. -/
  outputPortsValid : PortSignaturesValid outputs
  /-- Accepted template inputs are unique by source label. -/
  inputLabelsUnique : PortLabelsUnique inputs
  /-- Accepted template outputs are unique by source label. -/
  outputLabelsUnique : PortLabelsUnique outputs
  /-- Opaque body/effect boundary for nodes produced from this kind. -/
  body : NodeBodyBoundary
  /-- Accepted kind body boundaries have locally valid executor references. -/
  bodyLocalValid : body.LocalValid
  deriving DecidableEq

namespace RawKindDecl

/-- Locally admitted raw kinds become accepted kind declarations. -/
def toAccepted
    (decl : RawKindDecl)
    (hAdmissible : decl.LocallyAdmissible) :
    AcceptedKindDecl :=
  { kind := decl.kind
    kindValid := hAdmissible.kindValid
    params := decl.params
    paramsValid := hAdmissible.paramsValid
    paramNamesUnique := hAdmissible.paramNamesUnique
    inputs := decl.inputs.toFinset
    outputs := decl.outputs.toFinset
    inputPortsValid := portSignatureListValid_toFinset hAdmissible.inputPortsValid
    outputPortsValid := portSignatureListValid_toFinset hAdmissible.outputPortsValid
    inputLabelsUnique := portLabelListUnique_toFinset hAdmissible.inputLabelsUnique
    outputLabelsUnique := portLabelListUnique_toFinset hAdmissible.outputLabelsUnique
    body := decl.body
    bodyLocalValid := hAdmissible.bodyLocalValid }

end RawKindDecl

/-! ## Graph Expressions -/

/-- Shape-level graph expression after source inclusion.

This is still syntax: `connect`, `star`, `make`, and `makeEach` are not accepted
operations until future admission constructs the corresponding certificates.
`empty` is the algebra identity for synthesized graph shapes such as zero-count
expansion, not a user-authored Wire token. Because this expression language can
contain `StaticValue`, it stays on the printable-only side of the equality
boundary for now. -/
inductive GraphExpr where
  | empty
  | node (node : NodeId)
  | binding (binding : BindingName)
  | overlay (left right : GraphExpr)
  | connect (left right : GraphExpr)
  | star (left right : GraphExpr)
  | select (base : GraphExpr) (arms : List (SelectArmKey × GraphExpr))
  | make (binding : BindingName) (count : Nat) (kind : KindName)
  | makeEach (binding : BindingName) (kind : KindName) (items : List StaticValue)
  deriving Repr

/-- Graph binding expression before certified topology admission.

The same carrier is used in raw and accepted module shells because this module
does not yet provide a graph-admission certificate. Future certified elaboration
may wrap this shape in a proof-bearing accepted graph binding. -/
structure GraphBinding where
  /-- Binding name. -/
  name : BindingName
  /-- Bound graph expression. -/
  expr : GraphExpr
  deriving Repr

namespace GraphBinding

/-- Local graph-binding validity checks only the binding name. -/
def LocalValid (binding : GraphBinding) : Prop :=
  binding.name.Valid

end GraphBinding

/-! ## Local Closure Predicates -/

namespace RawNodeDecl

/-- Raw node port contracts are declared by the surrounding raw module shell. -/
def ContractsClosed
    (decl : RawNodeDecl)
    (contracts : List RecordContractDecl) :
    Prop :=
  (∀ port, port ∈ decl.inputs → port.contract ∈ contracts.map RecordContractDecl.contract) ∧
    ∀ port, port ∈ decl.outputs → port.contract ∈ contracts.map RecordContractDecl.contract

end RawNodeDecl

namespace AcceptedNodeDecl

/-- Accepted node port contracts are declared by the surrounding accepted module shell. -/
def ContractsClosed
    (decl : AcceptedNodeDecl)
    (contracts : List AcceptedRecordContractDecl) :
    Prop :=
  (∀ port, port ∈ decl.inputs → port.contract ∈ contracts.map AcceptedRecordContractDecl.contract) ∧
    ∀ port,
      port ∈ decl.outputs → port.contract ∈ contracts.map AcceptedRecordContractDecl.contract

end AcceptedNodeDecl

namespace RawKindDecl

/-- Raw kind template port contracts are declared by the surrounding raw module shell. -/
def ContractsClosed
    (decl : RawKindDecl)
    (contracts : List RecordContractDecl) :
    Prop :=
  (∀ port, port ∈ decl.inputs → port.contract ∈ contracts.map RecordContractDecl.contract) ∧
    ∀ port, port ∈ decl.outputs → port.contract ∈ contracts.map RecordContractDecl.contract

end RawKindDecl

namespace AcceptedKindDecl

/-- Accepted kind template port contracts are declared by the surrounding accepted module shell. -/
def ContractsClosed
    (decl : AcceptedKindDecl)
    (contracts : List AcceptedRecordContractDecl) :
    Prop :=
  (∀ port, port ∈ decl.inputs → port.contract ∈ contracts.map AcceptedRecordContractDecl.contract) ∧
    ∀ port,
      port ∈ decl.outputs → port.contract ∈ contracts.map AcceptedRecordContractDecl.contract

end AcceptedKindDecl

namespace GraphExpr

/-- Raw graph expressions reference only raw nodes, kinds, and graph bindings in the module shell.

This is a local closure predicate only. It does not reject graph cycles, repeated
linear resource references, invalid select coverage, or deterministic boundary
matching failures. -/
inductive RawRefsClosed
    (nodes : List RawNodeDecl)
    (kinds : List RawKindDecl)
    (graphs : List GraphBinding) :
    GraphExpr → Prop where
  | empty :
      RawRefsClosed nodes kinds graphs GraphExpr.empty
  | node {target : NodeId} :
      target ∈ nodes.map RawNodeDecl.node →
      RawRefsClosed nodes kinds graphs (GraphExpr.node target)
  | binding {target : BindingName} :
      target ∈ graphs.map GraphBinding.name →
      RawRefsClosed nodes kinds graphs (GraphExpr.binding target)
  | overlay {left right : GraphExpr} :
      RawRefsClosed nodes kinds graphs left →
      RawRefsClosed nodes kinds graphs right →
      RawRefsClosed nodes kinds graphs (GraphExpr.overlay left right)
  | connect {left right : GraphExpr} :
      RawRefsClosed nodes kinds graphs left →
      RawRefsClosed nodes kinds graphs right →
      RawRefsClosed nodes kinds graphs (GraphExpr.connect left right)
  | star {left right : GraphExpr} :
      RawRefsClosed nodes kinds graphs left →
      RawRefsClosed nodes kinds graphs right →
      RawRefsClosed nodes kinds graphs (GraphExpr.star left right)
  | select {base : GraphExpr} {arms : List (SelectArmKey × GraphExpr)} :
      RawRefsClosed nodes kinds graphs base →
      (∀ arm, arm ∈ arms → arm.fst.Valid) →
      (∀ arm, arm ∈ arms → RawRefsClosed nodes kinds graphs arm.snd) →
      RawRefsClosed nodes kinds graphs (GraphExpr.select base arms)
  | make {binding : BindingName} {count : Nat} {kind : KindName} :
      kind ∈ kinds.map RawKindDecl.kind →
      RawRefsClosed nodes kinds graphs (GraphExpr.make binding count kind)
  | makeEach {binding : BindingName} {kind : KindName} {items : List StaticValue} :
      kind ∈ kinds.map RawKindDecl.kind →
      RawRefsClosed nodes kinds graphs (GraphExpr.makeEach binding kind items)

/-- Accepted graph expressions reference only accepted nodes, kinds, and graph bindings.

This still is not graph admission: successful `=>`, `*`, `select(...)`, `make`,
and `makeEach` elaboration must later produce the corresponding proof objects. -/
inductive AcceptedRefsClosed
    (nodes : List AcceptedNodeDecl)
    (kinds : List AcceptedKindDecl)
    (graphs : List GraphBinding) :
    GraphExpr → Prop where
  | empty :
      AcceptedRefsClosed nodes kinds graphs GraphExpr.empty
  | node {target : NodeId} :
      target ∈ nodes.map AcceptedNodeDecl.node →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.node target)
  | binding {target : BindingName} :
      target ∈ graphs.map GraphBinding.name →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.binding target)
  | overlay {left right : GraphExpr} :
      AcceptedRefsClosed nodes kinds graphs left →
      AcceptedRefsClosed nodes kinds graphs right →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.overlay left right)
  | connect {left right : GraphExpr} :
      AcceptedRefsClosed nodes kinds graphs left →
      AcceptedRefsClosed nodes kinds graphs right →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.connect left right)
  | star {left right : GraphExpr} :
      AcceptedRefsClosed nodes kinds graphs left →
      AcceptedRefsClosed nodes kinds graphs right →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.star left right)
  | select {base : GraphExpr} {arms : List (SelectArmKey × GraphExpr)} :
      AcceptedRefsClosed nodes kinds graphs base →
      (∀ arm, arm ∈ arms → arm.fst.Valid) →
      (∀ arm, arm ∈ arms → AcceptedRefsClosed nodes kinds graphs arm.snd) →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.select base arms)
  | make {binding : BindingName} {count : Nat} {kind : KindName} :
      kind ∈ kinds.map AcceptedKindDecl.kind →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.make binding count kind)
  | makeEach {binding : BindingName} {kind : KindName} {items : List StaticValue} :
      kind ∈ kinds.map AcceptedKindDecl.kind →
      AcceptedRefsClosed nodes kinds graphs (GraphExpr.makeEach binding kind items)

end GraphExpr

/-! ## Diagnostics And Modules -/

/-- Static elaboration diagnostics for the future Wire admission path.

Diagnostics that quote static values or graph expressions inherit the same
equality boundary: this module keeps them printable, but does not expose
decidable equality until a structural `StaticValue` equality exists. These
constructors seed the future admission vocabulary; the list will grow with the
admission functions that produce `ElabResult`. -/
inductive ElabDiagnostic where
  | duplicateNode (target : NodeId)
  | duplicateKind (target : KindName)
  | duplicateInputPort (owner : NodeId) (port : FieldLabel)
  | duplicateOutputPort (owner : NodeId) (port : FieldLabel)
  | duplicateRecordField (owner : ContractId) (field : FieldLabel)
  | unknownNode (target : NodeId)
  | unknownBinding (target : BindingName)
  | unknownKind (target : KindName)
  | repeatedGraphReference (target : BindingName)
  | ambiguousBoundaryMatch (contract : ContractId) (candidates : List PortSignature)
  | missingBoundaryMatch (contract : ContractId)
  | invalidMakeCount (binding : BindingName)
  | invalidMakeEachItem (binding : BindingName) (value : StaticValue)
  | invalidStarShape (left right : GraphExpr)
  | unsupported (message : String)
  deriving Repr

/-- Result of static elaboration/admission. -/
abbrev ElabResult (α : Type) : Type :=
  Except (List ElabDiagnostic) α

/-- Raw source module after parsing and source inclusion.

The raw module keeps graph bindings as syntax, so it remains on the printable
side of the equality boundary until `GraphExpr` gains structural equality. -/
structure RawModule where
  /-- Raw record contracts. -/
  contracts : List RecordContractDecl
  /-- Raw kind templates. -/
  kinds : List RawKindDecl
  /-- Raw node declarations. -/
  nodes : List RawNodeDecl
  /-- Raw graph bindings. -/
  graphs : List GraphBinding
  deriving Repr

namespace RawModule

/-- Local admission witness for a raw module shell.

This gathers declaration-local admission, per-namespace uniqueness, and reference
closure. It still does not construct certified graph artifacts, prove graph
linearity, bind executors against a registry, reject graph cycles, or elaborate
generated operators. -/
structure LocallyAdmissible (decl : RawModule) : Prop where
  /-- Every raw record contract is locally admissible. -/
  contractsAdmissible :
    ∀ contract, contract ∈ decl.contracts → contract.LocallyAdmissible
  /-- Every raw kind template is locally admissible. -/
  kindsAdmissible :
    ∀ kind, kind ∈ decl.kinds → kind.LocallyAdmissible
  /-- Every raw node declaration is locally admissible. -/
  nodesAdmissible :
    ∀ node, node ∈ decl.nodes → node.LocallyAdmissible
  /-- Every raw graph binding has a locally valid binding name. -/
  graphsValid :
    ∀ graph, graph ∈ decl.graphs → graph.LocalValid
  /-- Raw contract declarations are unique by contract identifier. -/
  contractsUnique : (decl.contracts.map RecordContractDecl.contract).Nodup
  /-- Raw kind declarations are unique by kind name. -/
  kindsUnique : (decl.kinds.map RawKindDecl.kind).Nodup
  /-- Raw node declarations are unique by node name. -/
  nodesUnique : (decl.nodes.map RawNodeDecl.node).Nodup
  /-- Raw graph bindings are unique by binding name. -/
  graphsUnique : (decl.graphs.map GraphBinding.name).Nodup
  /-- Raw record-field contracts refer to declared contracts. -/
  recordFieldContractsClosed :
    ∀ contract, contract ∈ decl.contracts → contract.FieldContractsClosed decl.contracts
  /-- Raw node port contracts refer to declared contracts. -/
  nodeContractsClosed :
    ∀ node, node ∈ decl.nodes → node.ContractsClosed decl.contracts
  /-- Raw kind port contracts refer to declared contracts. -/
  kindContractsClosed :
    ∀ kind, kind ∈ decl.kinds → kind.ContractsClosed decl.contracts
  /-- Raw graph expressions reference declared nodes, kinds, and graph bindings. -/
  graphRefsClosed :
    ∀ graph, graph ∈ decl.graphs → graph.expr.RawRefsClosed decl.nodes decl.kinds decl.graphs

end RawModule

namespace RawModule

/-- Accepted contract list projected from locally admissible raw contracts. -/
def acceptedContracts
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    List AcceptedRecordContractDecl :=
  decl.contracts.attach.map
    (fun contract =>
      contract.val.toAccepted
        (hAdmissible.contractsAdmissible contract.val contract.property))

/-- Accepted kind list projected from locally admissible raw kind templates. -/
def acceptedKinds
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    List AcceptedKindDecl :=
  decl.kinds.attach.map
    (fun kind =>
      kind.val.toAccepted
        (hAdmissible.kindsAdmissible kind.val kind.property))

/-- Accepted node list projected from locally admissible raw node declarations. -/
def acceptedNodes
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    List AcceptedNodeDecl :=
  decl.nodes.attach.map
    (fun node =>
      node.val.toAccepted
        (hAdmissible.nodesAdmissible node.val node.property))

/-- Projecting accepted contracts preserves the raw contract-name list. -/
theorem acceptedContracts_contracts
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    (decl.acceptedContracts hAdmissible).map AcceptedRecordContractDecl.contract =
      decl.contracts.map RecordContractDecl.contract := by
  simp [acceptedContracts, RecordContractDecl.toAccepted]

/-- Projecting accepted kinds preserves the raw kind-name list. -/
theorem acceptedKinds_kinds
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    (decl.acceptedKinds hAdmissible).map AcceptedKindDecl.kind =
      decl.kinds.map RawKindDecl.kind := by
  simp [acceptedKinds, RawKindDecl.toAccepted]

/-- Projecting accepted nodes preserves the raw node-name list. -/
theorem acceptedNodes_nodes
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    (decl.acceptedNodes hAdmissible).map AcceptedNodeDecl.node =
      decl.nodes.map RawNodeDecl.node := by
  simp [acceptedNodes, RawNodeDecl.toAccepted]

/-- Raw graph reference closure transfers across local raw-to-accepted declaration projection. -/
theorem rawRefsClosed_toAccepted
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible)
    {expr : GraphExpr}
    (hClosed : expr.RawRefsClosed decl.nodes decl.kinds decl.graphs) :
    expr.AcceptedRefsClosed
      (decl.acceptedNodes hAdmissible)
      (decl.acceptedKinds hAdmissible)
      decl.graphs := by
  induction hClosed with
  | empty =>
      exact GraphExpr.AcceptedRefsClosed.empty
  | node hNode =>
      exact
        GraphExpr.AcceptedRefsClosed.node
          (by
            rw [acceptedNodes_nodes]
            exact hNode)
  | binding hBinding =>
      exact GraphExpr.AcceptedRefsClosed.binding hBinding
  | overlay _hLeft _hRight ihLeft ihRight =>
      exact GraphExpr.AcceptedRefsClosed.overlay ihLeft ihRight
  | connect _hLeft _hRight ihLeft ihRight =>
      exact GraphExpr.AcceptedRefsClosed.connect ihLeft ihRight
  | star _hLeft _hRight ihLeft ihRight =>
      exact GraphExpr.AcceptedRefsClosed.star ihLeft ihRight
  | select _hBase hArmKeys _hArms ihBase ihArms =>
      exact GraphExpr.AcceptedRefsClosed.select ihBase hArmKeys ihArms
  | make hKind =>
      exact
        GraphExpr.AcceptedRefsClosed.make
          (by
            rw [acceptedKinds_kinds]
            exact hKind)
  | makeEach hKind =>
      exact
        GraphExpr.AcceptedRefsClosed.makeEach
          (by
            rw [acceptedKinds_kinds]
            exact hKind)

end RawModule

/-- Accepted module shell.

Kinds and nodes here have reached their accepted carriers. Graph bindings remain
plain expression carriers: the actual certificates connecting graph expressions
to `LinearPortObject`, `MakeWitness`, `PhantomAdapterWitness`, and `BulkContract`
are intentionally left to later proof modules. Accepted modules also do not
expose decidable equality until graph expressions do.

The uniqueness fields are per represented namespace. Full Wire source-scope
collision checks across contracts, nodes, graph/value lets, imports, executors,
and future kinds belong to module admission rather than this local carrier. -/
structure AcceptedModule where
  /-- Accepted record contracts. -/
  contracts : List AcceptedRecordContractDecl
  /-- Accepted record contract identifiers are unique inside the module shell. -/
  contractsUnique : (contracts.map AcceptedRecordContractDecl.contract).Nodup
  /-- Accepted kind templates. -/
  kinds : List AcceptedKindDecl
  /-- Accepted kind names are unique inside the module shell. -/
  kindsUnique : (kinds.map AcceptedKindDecl.kind).Nodup
  /-- Accepted node declarations. -/
  nodes : List AcceptedNodeDecl
  /-- Accepted node names are unique inside the module shell. -/
  nodesUnique : (nodes.map AcceptedNodeDecl.node).Nodup
  /-- Graph bindings awaiting future certified topology admission. -/
  graphs : List GraphBinding
  /-- Graph binding names are unique inside the module shell. -/
  graphsUnique : (graphs.map GraphBinding.name).Nodup
  /-- Accepted graph bindings have locally valid binding names. -/
  graphsValid :
    ∀ graph, graph ∈ graphs → graph.LocalValid
  /-- Accepted record-field contracts refer to declared accepted contracts. -/
  recordFieldContractsClosed :
    ∀ contract, contract ∈ contracts → AcceptedRecordFieldContractsClosed contract contracts
  /-- Accepted node port contracts refer to declared accepted contracts. -/
  nodeContractsClosed :
    ∀ node, node ∈ nodes → node.ContractsClosed contracts
  /-- Accepted kind port contracts refer to declared accepted contracts. -/
  kindContractsClosed :
    ∀ kind, kind ∈ kinds → kind.ContractsClosed contracts
  /-- Accepted graph expressions reference declared nodes, kinds, and graph bindings. -/
  graphRefsClosed :
    ∀ graph, graph ∈ graphs → graph.expr.AcceptedRefsClosed nodes kinds graphs

namespace RawModule

/-- Locally admissible raw module shells project to accepted module shells.

This is still not certified graph elaboration. It only transports local
declaration admission, namespace uniqueness, and reference-closure witnesses to
the accepted carrier. -/
def toAccepted
    (decl : RawModule)
    (hAdmissible : decl.LocallyAdmissible) :
    AcceptedModule :=
  { contracts := decl.acceptedContracts hAdmissible
    contractsUnique := by
      rw [acceptedContracts_contracts]
      exact hAdmissible.contractsUnique
    kinds := decl.acceptedKinds hAdmissible
    kindsUnique := by
      rw [acceptedKinds_kinds]
      exact hAdmissible.kindsUnique
    nodes := decl.acceptedNodes hAdmissible
    nodesUnique := by
      rw [acceptedNodes_nodes]
      exact hAdmissible.nodesUnique
    graphs := decl.graphs
    graphsUnique := hAdmissible.graphsUnique
    graphsValid := hAdmissible.graphsValid
    recordFieldContractsClosed := by
      intro contract hContract
      rcases List.mem_map.mp hContract with ⟨rawContract, _hRawContractMem, hEq⟩
      subst hEq
      intro field hField
      have hRawField : field ∈ rawContract.val.fields := by
        simpa [RecordContractDecl.toAccepted] using hField
      have hKnown :
          field.contract ∈ decl.contracts.map RecordContractDecl.contract :=
        hAdmissible.recordFieldContractsClosed
          rawContract.val
          rawContract.property
          field
          hRawField
      rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
      exact hKnown
    nodeContractsClosed := by
      intro node hNode
      rcases List.mem_map.mp hNode with ⟨rawNode, _hRawNodeMem, hEq⟩
      subst hEq
      constructor
      · intro port hPort
        have hRawPort : port ∈ rawNode.val.inputs := by
          simpa [RawNodeDecl.toAccepted] using List.mem_toFinset.mp hPort
        have hKnown :
            port.contract ∈ decl.contracts.map RecordContractDecl.contract :=
          (hAdmissible.nodeContractsClosed rawNode.val rawNode.property).left
            port
            hRawPort
        rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
        exact hKnown
      · intro port hPort
        have hRawPort : port ∈ rawNode.val.outputs := by
          simpa [RawNodeDecl.toAccepted] using List.mem_toFinset.mp hPort
        have hKnown :
            port.contract ∈ decl.contracts.map RecordContractDecl.contract :=
          (hAdmissible.nodeContractsClosed rawNode.val rawNode.property).right
            port
            hRawPort
        rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
        exact hKnown
    kindContractsClosed := by
      intro kind hKind
      rcases List.mem_map.mp hKind with ⟨rawKind, _hRawKindMem, hEq⟩
      subst hEq
      constructor
      · intro port hPort
        have hRawPort : port ∈ rawKind.val.inputs := by
          simpa [RawKindDecl.toAccepted] using List.mem_toFinset.mp hPort
        have hKnown :
            port.contract ∈ decl.contracts.map RecordContractDecl.contract :=
          (hAdmissible.kindContractsClosed rawKind.val rawKind.property).left
            port
            hRawPort
        rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
        exact hKnown
      · intro port hPort
        have hRawPort : port ∈ rawKind.val.outputs := by
          simpa [RawKindDecl.toAccepted] using List.mem_toFinset.mp hPort
        have hKnown :
            port.contract ∈ decl.contracts.map RecordContractDecl.contract :=
          (hAdmissible.kindContractsClosed rawKind.val rawKind.property).right
            port
            hRawPort
        rw [← acceptedContracts_contracts decl hAdmissible] at hKnown
        exact hKnown
    graphRefsClosed := by
      intro graph hGraph
      exact
        rawRefsClosed_toAccepted
          decl
          hAdmissible
          (hAdmissible.graphRefsClosed graph hGraph) }

end RawModule

/-! ## Shape Examples -/

/-- Example contract used by the C-build shape example. -/
def commandSpecContract : ContractId :=
  ⟨"CommandSpec"⟩

/-- Example contract for a compiled object artifact. -/
def objectArtifactContract : ContractId :=
  ⟨"ObjectArtifact"⟩

/-- Example input port carrying a command spec. -/
def specPort : PortSignature :=
  { label := ⟨"spec"⟩, contract := commandSpecContract }

/-- The example command-spec input port is locally valid. -/
theorem specPort_valid : specPort.Valid := by
  constructor <;> decide

/-- Example output port carrying a build artifact. -/
def artifactPort : PortSignature :=
  { label := ⟨"artifact"⟩, contract := objectArtifactContract }

/-- The example artifact output port is locally valid. -/
theorem artifactPort_valid : artifactPort.Valid := by
  constructor <;> decide

/-- Accepted shape of one compile node in the C-build example family. -/
def cBuildCompileNode : AcceptedNodeDecl where
  node := ⟨"compile_metrics"⟩
  nodeValid := by decide
  inputs := {specPort}
  outputs := {artifactPort}
  inputPortsValid := singleton_portSignaturesValid specPort_valid
  outputPortsValid := singleton_portSignaturesValid artifactPort_valid
  inputLabelsUnique := singleton_portLabelsUnique specPort
  outputLabelsUnique := singleton_portLabelsUnique artifactPort
  body := NodeBodyBoundary.executor ⟨"shell"⟩
  bodyLocalValid := by decide

/-- Accepted pass-through shape showing that input and output directions may reuse a label. -/
def cBuildPassThroughNode : AcceptedNodeDecl where
  node := ⟨"pass_spec"⟩
  nodeValid := by decide
  inputs := {specPort}
  outputs := {specPort}
  inputPortsValid := singleton_portSignaturesValid specPort_valid
  outputPortsValid := singleton_portSignaturesValid specPort_valid
  inputLabelsUnique := singleton_portLabelsUnique specPort
  outputLabelsUnique := singleton_portLabelsUnique specPort
  body := NodeBodyBoundary.corePure
  bodyLocalValid := trivial

/-- C-build-shaped graph expression using both `makeEach` and `*`.

This only demonstrates representability of post-source-include syntax. Future
modules must still admit the expression and produce the linear certificates. -/
def cBuildGraphShape : GraphExpr :=
  GraphExpr.connect
    (GraphExpr.makeEach
      ⟨"compile_units"⟩
      ⟨"compile_unit"⟩
      [ StaticValue.string "src/lib/metrics.c"
      , StaticValue.string "src/lib/parse.c"
      , StaticValue.string "src/app/main.c"
      ])
    (GraphExpr.star
      (GraphExpr.node ⟨"archive_lib"⟩)
      (GraphExpr.node ⟨"link_app"⟩))

end ElaborationIR
end Cortex.Wire
