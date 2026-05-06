import Cortex.Wire.PortLinearity

/-!
## Overview

Proof-facing `make(N, K)` construction for the source linear port algebra.

## Context

ADR 0048 makes `make(N, K)` a compile-time elaboration form, not a runtime
operator. This module models the proof-side witness that such elaboration
produces: a finite family of fresh child nodes with open node-port resources.

The linearity content is inherited from `LinearPortObject.nodePorts`. The
interesting `make`-specific obligation is identity discipline: generated nodes
belong to one binding namespace, and distinct binding namespaces give disjoint
source domains for later overlay.
-/

namespace Cortex.Wire
namespace LinearPortGraph

variable {binding node outputPort inputPort : Type}
variable {nodeBinding : node → binding}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]

/-! ## Domain Disjointness From Node Disjointness -/

/-- Node disjointness implies output-endpoint disjointness by endpoint ownership. -/
theorem outputDisjoint_of_nodeDisjoint
    (left right : LinearPortGraph node outputPort inputPort)
    (hNodeDisjoint : NodeDisjoint left right) :
    OutputDisjoint left right := by
  intro output hLeft hRight
  exact
    hNodeDisjoint
      output.node
      (left.output_nodes output hLeft)
      (right.output_nodes output hRight)

/-- Node disjointness implies input-endpoint disjointness by endpoint ownership. -/
theorem inputDisjoint_of_nodeDisjoint
    (left right : LinearPortGraph node outputPort inputPort)
    (hNodeDisjoint : NodeDisjoint left right) :
    InputDisjoint left right := by
  intro input hLeft hRight
  exact
    hNodeDisjoint
      input.node
      (left.input_nodes input hLeft)
      (right.input_nodes input hRight)

/-- Node disjointness is enough to supply the full overlay domain-disjointness certificate. -/
theorem domainDisjoint_of_nodeDisjoint
    (left right : LinearPortGraph node outputPort inputPort)
    (hNodeDisjoint : NodeDisjoint left right) :
    DomainDisjoint left right :=
  ⟨ hNodeDisjoint
  , outputDisjoint_of_nodeDisjoint left right hNodeDisjoint
  , inputDisjoint_of_nodeDisjoint left right hNodeDisjoint
  ⟩

/-! ## Make Witnesses -/

/-- `MakeWitness` is the proof-side identity witness for one `make(N, K)` expansion.

The witness does not model the parser or kind expander. It records the finite source graph produced
by expansion, the binding namespace that owns generated nodes, and the child-node indexing evidence
that ADR 0048 requires from the identity scheme.

The fields split into identity data (`sourceBinding`, `nodes`, `outputs`, `inputs`, and their node
invariants), binding namespace evidence (`nodeBinding_eq`), and indexing data (`count`,
`childNode`, child port families, exactness lemmas, and injectivity). The bijection between
`Fin count` and generated nodes is established by `childNode_mem`, `nodes_exact`, and
`childNode_inj` together. -/
structure MakeWitness (binding node outputPort inputPort : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort]
    (nodeBinding : node → binding) where
  /-- Source binding that names this generated family. -/
  sourceBinding : binding
  /-- Generated source nodes. -/
  nodes : Finset node
  /-- Generated source output ports. -/
  outputs : Finset (SourcePortInstance node outputPort)
  /-- Generated source input ports. -/
  inputs : Finset (SourcePortInstance node inputPort)
  /-- Every generated output belongs to a generated node. -/
  output_nodes : ∀ output, output ∈ outputs → output.node ∈ nodes
  /-- Every generated input belongs to a generated node. -/
  input_nodes : ∀ input, input ∈ inputs → input.node ∈ nodes
  /-- Every generated node belongs to this witness's binding namespace. -/
  nodeBinding_eq : ∀ graphNode, graphNode ∈ nodes → nodeBinding graphNode = sourceBinding
  /-- ADR 0048's `N`: the post-elaboration static expansion count. -/
  count : Nat
  /-- Source-stable child node for each generated index. -/
  childNode : Fin count → node
  /-- Kind-derived output labels instantiated for each generated child. -/
  childOutputPorts : Fin count → Finset outputPort
  /-- Kind-derived input labels instantiated for each generated child. -/
  childInputPorts : Fin count → Finset inputPort
  /-- Each indexed child is present in the generated node set. -/
  childNode_mem : ∀ index, childNode index ∈ nodes
  /-- Every generated node is one of the indexed children. -/
  nodes_exact : ∀ graphNode, graphNode ∈ nodes → ∃ index, childNode index = graphNode
  /-- The generated output port set is exactly the kind-derived ports for each child. -/
  outputs_exact :
    ∀ output,
      output ∈ outputs ↔
        ∃ index port,
          port ∈ childOutputPorts index ∧
            output = { node := childNode index, port := port }
  /-- The generated input port set is exactly the kind-derived ports for each child. -/
  inputs_exact :
    ∀ input,
      input ∈ inputs ↔
        ∃ index port,
          port ∈ childInputPorts index ∧
            input = { node := childNode index, port := port }
  /-- Generated child identities are injective in their index. -/
  childNode_inj : Function.Injective childNode

namespace MakeWitness

/-- The source object produced by a certified `make(N, K)` expansion. -/
def toObject
    (witness : MakeWitness binding node outputPort inputPort nodeBinding) :
    LinearPortObject node outputPort inputPort :=
  LinearPortObject.nodePorts
    witness.nodes
    witness.outputs
    witness.inputs
    witness.output_nodes
    witness.input_nodes

/-- Distinct make bindings have disjoint generated node domains. -/
theorem nodeDisjoint_of_distinctBindings
    (left right : MakeWitness binding node outputPort inputPort nodeBinding)
    (hDistinct : left.sourceBinding ≠ right.sourceBinding) :
    NodeDisjoint left.toObject.graph right.toObject.graph := by
  intro graphNode hLeft hRight
  have hLeftNode : graphNode ∈ left.nodes := by
    simpa [toObject, LinearPortObject.nodePorts, openNodePorts] using hLeft
  have hRightNode : graphNode ∈ right.nodes := by
    simpa [toObject, LinearPortObject.nodePorts, openNodePorts] using hRight
  have hLeftBinding := left.nodeBinding_eq graphNode hLeftNode
  have hRightBinding := right.nodeBinding_eq graphNode hRightNode
  exact hDistinct (hLeftBinding.symm.trans hRightBinding)

/-- Distinct make bindings have disjoint overlay domains. -/
theorem make_disjoint_of_distinctBindings
    (left right : MakeWitness binding node outputPort inputPort nodeBinding)
    (hDistinct : left.sourceBinding ≠ right.sourceBinding) :
    DomainDisjoint left.toObject.graph right.toObject.graph :=
  domainDisjoint_of_nodeDisjoint
    left.toObject.graph
    right.toObject.graph
    (nodeDisjoint_of_distinctBindings left right hDistinct)

end MakeWitness
end LinearPortGraph
end Cortex.Wire
