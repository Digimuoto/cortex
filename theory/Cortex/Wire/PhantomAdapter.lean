import Cortex.Wire.PortLinearity

/-!
## Overview

Proof-facing phantom adapter construction for Wire's `*` topology operator.

## Context

ADR 0049 defines `a * b` by elaboration to ordinary graph structure:

```text
a => phantom => b
```

Both arrows are ordinary certified bulk contractions from ADR 0047. The phantom
is an ordinary generated source object. Therefore `*` does not need its own
port-linearity preservation theorem; it is a construction in the closed source
linear algebra.
-/

namespace Cortex.Wire
namespace LinearPortGraph

variable {node outputPort inputPort : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]

namespace LinearPortObject

/-- Apply a certified bulk contraction to a linear source object. -/
def bulkContract
    (object : LinearPortObject node outputPort inputPort)
    {finish : LinearPortGraph node outputPort inputPort}
    (hBulk : BulkContract object.graph finish) :
    LinearPortObject node outputPort inputPort where
  graph := finish
  linear := bulkContract_preserves_portLinear hBulk object.linear

end LinearPortObject

/-! ## Phantom Adapter Witness -/

/-- Direction of the generated phantom adapter.

`gather` consumes a multi-input boundary and emits one singular record output.
`scatter` consumes one singular record input and emits a multi-output boundary. -/
inductive PhantomDirection where
  | gather
  | scatter
  deriving DecidableEq, Repr

/-- Shape certificate for the generated record↔ports phantom.

The certificate pins the phantom to one generated node and partitions its boundary into the
multi-side and singular-side ports used by ADR 0049. Contract and record-field compatibility remain
compiler-side facts that construct these exact port sets before producing the witness.

The field shape mirrors ADR 0049's record-form discriminator: direction, one phantom node, boundary
partition, per-direction singularity, and exact source port sets for the generated adapter. -/
structure PhantomRecordShape
    (phantom : LinearPortObject node outputPort inputPort) where
  /-- Direction chosen by the record-form discriminator. -/
  direction : PhantomDirection
  /-- The unique generated phantom node. -/
  phantomNode : node
  /-- Output ports on the multi-side boundary. -/
  multiOutputs : Finset (SourcePortInstance node outputPort)
  /-- Input ports on the multi-side boundary. -/
  multiInputs : Finset (SourcePortInstance node inputPort)
  /-- Singular record output, present exactly in gather mode. -/
  singularOutputs : Finset (SourcePortInstance node outputPort)
  /-- Singular record input, present exactly in scatter mode. -/
  singularInputs : Finset (SourcePortInstance node inputPort)
  /-- The generated phantom object has exactly one node. -/
  nodes_exact : phantom.graph.nodes = {phantomNode}
  /-- Phantom outputs are exactly the declared multi outputs plus singular outputs. -/
  outputs_exact : phantom.graph.outputs = multiOutputs ∪ singularOutputs
  /-- Phantom inputs are exactly the declared multi inputs plus singular inputs. -/
  inputs_exact : phantom.graph.inputs = multiInputs ∪ singularInputs
  /-- Generated phantom starts with every output exposed. -/
  exposedOutputs_exact : phantom.graph.exposedOutputs = phantom.graph.outputs
  /-- Generated phantom starts with every input exposed. -/
  exposedInputs_exact : phantom.graph.exposedInputs = phantom.graph.inputs
  /-- Multi and singular output sets are a partition. -/
  output_partition :
    ∀ output, output ∈ multiOutputs → output ∈ singularOutputs → False
  /-- Multi and singular input sets are a partition. -/
  input_partition :
    ∀ input, input ∈ multiInputs → input ∈ singularInputs → False
  /-- Every declared multi output belongs to the phantom node. -/
  multiOutput_node :
    ∀ output, output ∈ multiOutputs → output.node = phantomNode
  /-- Every declared singular output belongs to the phantom node. -/
  singularOutput_node :
    ∀ output, output ∈ singularOutputs → output.node = phantomNode
  /-- Every declared multi input belongs to the phantom node. -/
  multiInput_node :
    ∀ input, input ∈ multiInputs → input.node = phantomNode
  /-- Every declared singular input belongs to the phantom node. -/
  singularInput_node :
    ∀ input, input ∈ singularInputs → input.node = phantomNode
  /-- Direction-specific singular-side and multi-side shape. -/
  direction_consistent :
    match direction with
    | PhantomDirection.gather =>
        multiOutputs = ∅ ∧ singularInputs = ∅ ∧ singularOutputs.card = 1
    | PhantomDirection.scatter =>
        multiInputs = ∅ ∧ singularOutputs = ∅ ∧ singularInputs.card = 1

/-- `PhantomAdapterWitness` exhibits `*` as an ordinary generated phantom plus two contractions.

The witness starts with a left operand, a generated phantom object, and a right operand. It first
overlays and contracts `left <> phantom`, then overlays the right operand and contracts again. The
bulk-contract fields are where the compiler's record-form discriminator supplies the certified
endpoint matchings. -/
structure PhantomAdapterWitness (node outputPort inputPort : Type)
    [DecidableEq node]
    [DecidableEq outputPort]
    [DecidableEq inputPort] where
  /-- Left operand of `*`. -/
  left : LinearPortObject node outputPort inputPort
  /-- Generated phantom record↔ports adapter. -/
  phantom : LinearPortObject node outputPort inputPort
  /-- Right operand of `*`. -/
  right : LinearPortObject node outputPort inputPort
  /-- Shape certificate tying the generated phantom to ADR 0049's record↔ports adapter boundary. -/
  phantomShape : PhantomRecordShape phantom
  /-- The left operand and phantom use disjoint source domains. -/
  leftPhantomDisjoint : DomainDisjoint left.graph phantom.graph
  /-- Intermediate graph after contracting the left/phantom boundary. -/
  afterLeft : LinearPortGraph node outputPort inputPort
  /-- Certified bulk contraction for the left/phantom boundary. -/
  leftBulk :
    BulkContract (LinearPortGraph.overlay left.graph phantom.graph) afterLeft
  /-- The intermediate graph and right operand use disjoint source domains. -/
  afterLeftRightDisjoint : DomainDisjoint afterLeft right.graph
  /-- Final graph after contracting the phantom/right boundary. -/
  finish : LinearPortGraph node outputPort inputPort
  /-- Certified bulk contraction for the phantom/right boundary. -/
  rightBulk :
    BulkContract (LinearPortGraph.overlay afterLeft right.graph) finish

namespace PhantomAdapterWitness

/-- Elaborate `*` as overlay with a generated phantom followed by two certified contractions. -/
def starInsertion
    (witness : PhantomAdapterWitness node outputPort inputPort) :
    LinearPortObject node outputPort inputPort :=
  let leftPhantom :=
    LinearPortObject.overlay
      witness.left
      witness.phantom
      witness.leftPhantomDisjoint
  let afterLeft :=
    leftPhantom.bulkContract witness.leftBulk
  let withRight :=
    LinearPortObject.overlay
      afterLeft
      witness.right
      witness.afterLeftRightDisjoint
  withRight.bulkContract witness.rightBulk

/-- `*` elaboration returns a source-linear graph. -/
theorem starInsertion_portLinear
    (witness : PhantomAdapterWitness node outputPort inputPort) :
    (witness.starInsertion).graph.PortLinear :=
  witness.starInsertion.linear

end PhantomAdapterWitness
end LinearPortGraph
end Cortex.Wire
