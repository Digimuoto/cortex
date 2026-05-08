import Cortex.Wire.ElaborationIR

/-!
## Overview

Certified graph elaboration for primitive Wire `GraphExpr` shapes.

## Context

`Cortex.Wire.ElaborationIR` introduces `GraphExpr` as the post-source-include
syntax tree and `AdmittedModuleShell` as the surrounding accepted module shell.
Slice 2 of the Wire compiler track admits the primitive subset
(`empty`, `node`, `binding`, `overlay`, `connect`) into certified graph objects
carrying source linearity.

The certified carrier in this file packages a `LinearPortGraph.LinearPortObject`
with two finite-set ledgers: the source-node identities used by the admitted
expression and the graph-binding references resolved while admitting it. The
node ledger mirrors the underlying object's node domain through an explicit
forgetful-lowering field; the binding-reference ledger is the load-bearing
slice-2 invariant, since a graph binding admits to a frontier with empty node
domain when its right-hand side is admitted only as a referenced binding.

`Admits` is an inductive predicate on `(GraphExpr, CertifiedGraph)` rather
than an `Option`-returning elaborator. Slice 2 only certifies the primitive
subset, so non-primitive constructors do not yet have admission cases here;
`star`, `select`, `make`, and `makeEach` remain explicit obligations elsewhere.
For `connect`, the predicate stays relational: callers supply a
`BoundaryMatchTrace`, and trace-order confluence for equal determined pair sets
is a later strengthening theorem rather than a uniqueness property claimed by
this slice. The `determined` field encodes Wire's ADR 0047 policy that
ambiguous boundary matches are rejected by non-existence of an admissible trace;
if an executable runtime ever chooses a tie-breaker instead, it must provide a
different correspondence theorem rather than reusing this carrier unchanged.

## Theorem Split

The page defines `CertifiedGraph`, the disjoint-overlay witness `Disjoint`,
the singleton-match helper `SingletonMatch`, the bulk boundary-trace carrier
`BoundaryMatchTrace`, primitive constructors `empty`, `nodeOf`, `bindingOf`,
`overlayOf`, `connectOf`, the inductive `Admits` predicate, the disjoint-ledger
projection theorems `admits_overlay_usedNodes_disjoint` and
`admits_overlay_usedRefs_disjoint`, the binding-leaf self-overlay rejection
corollary `admits_overlay_self_binding_false`, the singleton boundary-match determinism theorem
`singletonMatch_unique`, and the forgetful lowering theorems for `overlay` and
`connect`.

`connectOf` consumes a certified `BulkContract` trace plus the trace's bundled
`determined` witness that it contains exactly the compatible exposed boundary pairs.
ADR 0047's raw deterministic boundary-matching algorithm is still an admission
obligation, and trace-order confluence remains a correspondence obligation; the
source-linearity carrier no longer narrows `=>` to one selected pair or accepts
arbitrary contraction chains as admitted source. This exact-pair-set witness is
also where ambiguous frontiers fail: if two compatible pairs compete for the
same exposed endpoint, no `BulkContract` trace can contain exactly all compatible
pairs while preserving port linearity.
-/

namespace Cortex.Wire
namespace ElaborationIR

open LinearPortGraph

/-! ## Certified Graph Carrier -/

/-- A `CertifiedGraph` packages the source-linear port object admitted from a
`GraphExpr` together with the finite-set ledgers slice-2 admission needs:

- `usedNodes` is the set of source node identities consumed by the admitted
  expression. It mirrors the underlying object's node domain through
  `usedNodes_eq`, so callers can talk about node-level disjointness without
  unfolding `LinearPortObject`.
- `usedRefs` is the set of graph-binding references admitted as `binding`
  leaves. It is tracked separately from `usedNodes` because slice 2 admits a
  binding leaf without unfolding its right-hand side, and admission must still
  reject repeated use of the same binding leaf even when the resolved subgraph
  has empty node domain.

The accepted module is bundled as a parameter so the certificate carries the
shell that names the legal binding references and accepted node declarations. -/
structure CertifiedGraph (mod : AdmittedModuleShell) where
  /-- Source-linear port object admitted from the elaborated `GraphExpr`. -/
  object : LinearPortObject NodeId OutputPortSignature InputPortSignature
  /-- Finite ledger of source node identities consumed by the admitted graph. -/
  usedNodes : Finset NodeId
  /-- Finite ledger of graph-binding references resolved during admission.

  The canonical constructors and `Admits` cases maintain this ledger. Hand-built
  `CertifiedGraph` literals must supply the same invariant themselves until a
  later completeness theorem relates `usedRefs` back to syntactic binding leaves. -/
  usedRefs : Finset BindingName
  /-- The forgetful node-domain lowering recovers `usedNodes` from the object. -/
  usedNodes_eq : object.graph.nodes = usedNodes

namespace CertifiedGraph

variable {mod : AdmittedModuleShell}

/-! ## Primitive Constructors -/

/-- A certified bulk contraction trace preserves the source-node domain.

Each contraction consumes exposed endpoints and inserts a port edge; it never
creates or removes graph nodes. `CertifiedGraph.connectOf` uses this to keep
its explicit `usedNodes` ledger synchronized with the contracted object. -/
theorem bulkContract_nodes_eq
    {start finish : LinearPortGraph NodeId OutputPortSignature InputPortSignature}
    (hBulk : BulkContract start finish) :
    finish.nodes = start.nodes := by
  induction hBulk with
  | done _graph =>
      rfl
  | step graph output input hOutputExposed hInputExposed tail ih =>
      rw [ih]
      rfl

/-- Empty source-linear object shared by empty graphs and unresolved binding leaves. -/
private def emptyObject :
    LinearPortObject NodeId OutputPortSignature InputPortSignature :=
  LinearPortObject.nodePorts
    (∅ : Finset NodeId)
    (∅ : Finset (SourcePortInstance NodeId OutputPortSignature))
    (∅ : Finset (SourcePortInstance NodeId InputPortSignature))
    (by intro _ hMem; cases hMem)
    (by intro _ hMem; cases hMem)

/-- The empty certified graph: zero nodes, zero references, no edges.

This is the unit of `overlay` in the certified algebra. The underlying object
is `nodePorts ∅ ∅ ∅`, which is source-linear because every endpoint domain is
empty and therefore vacuously open. -/
def empty : CertifiedGraph mod where
  object := emptyObject
  usedNodes := ∅
  usedRefs := ∅
  usedNodes_eq := rfl

/-- Lift one accepted node declaration into a certified graph.

`AcceptedNodeDecl.toLinearPortObject` produces a source-linear object whose
node domain is the singleton `{decl.node}`. The certified ledger records that
singleton as `usedNodes` and keeps `usedRefs` empty because no binding is
involved. -/
def nodeOf (decl : AcceptedNodeDecl) : CertifiedGraph mod where
  object := decl.toLinearPortObject
  usedNodes := decl.nodeSet
  usedRefs := ∅
  usedNodes_eq := rfl

/-- Lift a graph-binding reference into a certified graph.

Slice 2 admits a binding leaf without unfolding its right-hand side: the
underlying object has empty node domain, but `usedRefs` records the binding
name. The load-bearing invariant is that admission of
`overlay (binding ref) (binding ref)` is rejected through `usedRefs`
disjointness even though `usedNodes` is empty on both sides.

Narrowed in this first sketch: the resolved subgraph is represented by the
empty linear-port object. The full theorem of admission-by-binding is
deferred to a later slice that admits the binding's right-hand side and
threads its `usedNodes` and `usedRefs`. -/
def bindingOf (binding : BindingName) : CertifiedGraph mod where
  object := emptyObject
  usedNodes := ∅
  usedRefs := {binding}
  usedNodes_eq := rfl

/-- Disjoint-domain certificate for two certified graphs.

The node-level component is the source-port-graph `DomainDisjoint`, which is
what `LinearPortObject.overlay` requires for source-linearity preservation.
The reference-level component is the slice-2 invariant that the same
graph-binding reference is not consumed twice. -/
structure Disjoint (lhs rhs : CertifiedGraph mod) : Prop where
  /-- Node identities, source port instances, and exposed endpoints are
  disjoint at the source linear-port-graph level. -/
  domain : DomainDisjoint lhs.object.graph rhs.object.graph
  /-- The graph-binding references admitted by `lhs` and `rhs` are disjoint. -/
  refs :
    ∀ binding,
      binding ∈ lhs.usedRefs →
        binding ∈ rhs.usedRefs →
          False

/-- Disjoint overlay of two certified graphs.

The underlying object is the certified linear-port-object overlay; the ledgers
are `Finset` unions. The forgetful node-domain field follows from the existing
`LinearPortObject.overlay` definition together with the per-side
`usedNodes_eq` projections. -/
def overlayOf
    (lhs rhs : CertifiedGraph mod)
    (hDisjoint : Disjoint lhs rhs) :
    CertifiedGraph mod where
  object := LinearPortObject.overlay lhs.object rhs.object hDisjoint.domain
  usedNodes := lhs.usedNodes ∪ rhs.usedNodes
  usedRefs := lhs.usedRefs ∪ rhs.usedRefs
  usedNodes_eq := by
    show lhs.object.graph.nodes ∪ rhs.object.graph.nodes =
        lhs.usedNodes ∪ rhs.usedNodes
    rw [lhs.usedNodes_eq, rhs.usedNodes_eq]

/-- Boundary match record for a singleton `connect` helper.

The public `connectOf` consumes `BoundaryMatchTrace`; this helper remains useful
for one-pair examples and local uniqueness lemmas. The record bundles the chosen
output and input source-port instances together with proof that they are exposed
on the respective sides and that their underlying source-port signatures agree. -/
structure SingletonMatch
    (lhs rhs : CertifiedGraph mod) where
  /-- Output instance contracted on `lhs`. -/
  output : SourcePortInstance NodeId OutputPortSignature
  /-- Input instance contracted on `rhs`. -/
  input : SourcePortInstance NodeId InputPortSignature
  /-- The output is currently exposed on `lhs`. -/
  outputExposed : output ∈ lhs.object.graph.exposedOutputs
  /-- The input is currently exposed on `rhs`. -/
  inputExposed : input ∈ rhs.object.graph.exposedInputs
  /-- Source labels and contracts agree across the matched pair. -/
  signature_match : output.port.signature = input.port.signature

/-- Port pair recorded by a certified bulk contraction trace.

The recursive predicate forgets trace order and exposes only which output/input
pairs the trace contracted. This lets admission state the ADR 0047 obligation as
an exact set-of-pairs property while keeping `BulkContract`'s induction-friendly
ordered representation. -/
def BulkContractContainsPair :
    {start finish : LinearPortGraph NodeId OutputPortSignature InputPortSignature} →
      BulkContract start finish →
        SourcePortInstance NodeId OutputPortSignature →
          SourcePortInstance NodeId InputPortSignature →
            Prop
  | _, _, BulkContract.done _graph, _output, _input => False
  | _, _, BulkContract.step _graph output input _hOutputExposed _hInputExposed tail,
      candidateOutput, candidateInput =>
      (candidateOutput = output ∧ candidateInput = input) ∨
        BulkContractContainsPair tail candidateOutput candidateInput

/-- Boundary-compatible pair in the original `lhs => rhs` frontier.

Wire boundary matching consumes exposed outputs from the left graph and exposed
inputs from the right graph whose source port signatures agree. Ambiguity
rejection and deterministic ordering are obligations of the executable matcher
that produces the trace; this predicate is the proof-side shape of the accepted
pair set. -/
def CompatiblePair
    (lhs rhs : CertifiedGraph mod)
    (output : SourcePortInstance NodeId OutputPortSignature)
    (input : SourcePortInstance NodeId InputPortSignature) :
    Prop :=
  output ∈ lhs.object.graph.exposedOutputs ∧
    input ∈ rhs.object.graph.exposedInputs ∧
      output.port.signature = input.port.signature

/-- Certified boundary trace for one `connect` expression.

The trace starts at the disjoint overlay of the left and right certified objects
and ends at the graph produced by all selected boundary contractions. The raw
matching algorithm must prove that the trace contains exactly the ADR
0047-compatible frontier pairs; this carrier includes that exactness witness and
handles preservation once the trace is supplied. -/
structure BoundaryMatchTrace
    (lhs rhs : CertifiedGraph mod)
    (hDisjoint : Disjoint lhs rhs) where
  /-- Final source graph after all certified contractions in the trace. -/
  finish : LinearPortGraph NodeId OutputPortSignature InputPortSignature
  /-- Certified bulk contraction from the disjoint overlay to `finish`. -/
  bulk :
    BulkContract
      (LinearPortObject.overlay lhs.object rhs.object hDisjoint.domain).graph
      finish
  /-- The trace contracts exactly the compatible exposed boundary pairs. -/
  determined :
    ∀ output input,
      BulkContractContainsPair bulk output input ↔ CompatiblePair lhs rhs output input

namespace BoundaryMatchTrace

/-- Node-domain preservation for the final graph of a boundary trace. -/
theorem finish_nodes_eq
    {lhs rhs : CertifiedGraph mod}
    {hDisjoint : Disjoint lhs rhs}
    (trace : BoundaryMatchTrace lhs rhs hDisjoint) :
    trace.finish.nodes =
      (LinearPortObject.overlay lhs.object rhs.object hDisjoint.domain).graph.nodes :=
  bulkContract_nodes_eq trace.bulk

end BoundaryMatchTrace

/-- Disjoint bulk-`connect` of two certified graphs.

The implementation overlays `lhs` and `rhs` on the source linear-port object
side and then follows a certified `BulkContract` trace over the overlay. This
models ADR 0047's simultaneous boundary contraction as the existing ordered
trace carrier from `PortLinearity`; trace order is preservation bookkeeping, not
source syntax.

Raw deterministic matching, ambiguity rejection, and compatibility checking are
the obligations that construct `matched` and prove `matched.determined`. Once
supplied, source linearity follows by induction over the trace. This constructor
does not claim that two equivalent determined traces are definitionally equal;
`Admits` remains a relation until a bulk-trace confluence theorem is added. -/
def connectOf
    (lhs rhs : CertifiedGraph mod)
    (hDisjoint : Disjoint lhs rhs)
    (matched : BoundaryMatchTrace lhs rhs hDisjoint) :
    CertifiedGraph mod :=
  let combined : LinearPortObject NodeId OutputPortSignature InputPortSignature :=
    LinearPortObject.overlay lhs.object rhs.object hDisjoint.domain
  { object :=
      { graph := matched.finish
        linear :=
          bulkContract_preserves_portLinear
            matched.bulk
            combined.linear }
    usedNodes := lhs.usedNodes ∪ rhs.usedNodes
    usedRefs := lhs.usedRefs ∪ rhs.usedRefs
    usedNodes_eq := by
      rw [matched.finish_nodes_eq]
      show lhs.object.graph.nodes ∪ rhs.object.graph.nodes =
          lhs.usedNodes ∪ rhs.usedNodes
      rw [lhs.usedNodes_eq, rhs.usedNodes_eq] }

/-! ## Singleton Match Determinism -/

/-- Singleton boundary-match determinism for an admitted `connect`.

For a candidate output instance currently exposed on `lhs`, every input
instance exposed on `rhs` and sharing its source-port signature must coincide
with the matched record's chosen input. The proof follows from the source
`PortLabelsUnique` invariant: outputs on the lhs frontier and inputs on the
rhs frontier carry direction-distinct wrappers, so an exposed input that
shares the matched signature can only be the matched input itself.

The theorem is stated for one matched output and a candidate on the same rhs
node. Exposure of the candidate input belongs to the matching algorithm that
selects candidates; this local uniqueness proof only needs node equality and
source-port-signature equality. Full-frontier matching supplies a
`BoundaryMatchTrace`; this lemma is still useful for the per-node/per-pair
uniqueness obligation that builds that trace. -/
theorem singletonMatch_unique
    {lhs rhs : CertifiedGraph mod}
    (matched : SingletonMatch lhs rhs)
    (candidate : SourcePortInstance NodeId InputPortSignature)
    (hCandidateSignature : matched.output.port.signature = candidate.port.signature)
    (hCandidateNode : candidate.node = matched.input.node) :
    candidate = matched.input := by
  -- The matched and candidate inputs agree on every component:
  -- node by hypothesis, and port wrapper because both wrap the matched
  -- output's source-port signature, and `InputPortSignature` is a one-field
  -- structure around `PortSignature`.
  have hPortSignatureEq :
      candidate.port.signature = matched.input.port.signature := by
    rw [← hCandidateSignature, matched.signature_match]
  have hPortEq : candidate.port = matched.input.port := by
    cases hCandPort : candidate.port with
    | mk candidateSignature =>
      cases hMatchedPort : matched.input.port with
      | mk matchedSignature =>
        rw [hCandPort, hMatchedPort] at hPortSignatureEq
        exact congrArg InputPortSignature.mk hPortSignatureEq
  cases hCand : candidate with
  | mk candidateNode candidatePort =>
    cases hMatched : matched.input with
    | mk matchedNode matchedPort =>
      rw [hCand, hMatched] at hCandidateNode hPortEq
      exact congrArg₂ SourcePortInstance.mk hCandidateNode hPortEq

end CertifiedGraph

/-! ## Admission Predicate -/

/-- `Admits mod expr graph` records that `expr` admits to `graph` against the
accepted module shell `mod`.

Slice 2 covers only the primitive subset: `empty`, `node`, `binding`,
`overlay`, and `connect`. Non-primitive constructors are intentionally omitted
because their certified shapes are obligations for later slices. The
overlay/connect cases require explicit `Disjoint` witnesses; the connect case
also requires a `BoundaryMatchTrace`, whose bundled `determined` witness pins
down the certified bulk contraction chosen by boundary matching. This predicate
does not assert uniqueness of the admitted certificate; deterministic compiler
admission and bulk-trace confluence are separate correspondence obligations. -/
inductive Admits :
    (mod : AdmittedModuleShell) →
      GraphExpr →
        CertifiedGraph mod →
          Prop where
  | empty
      (mod : AdmittedModuleShell) :
      Admits mod GraphExpr.empty (CertifiedGraph.empty (mod := mod))
  | node
      {mod : AdmittedModuleShell}
      {target : NodeId}
      (decl : AcceptedNodeDecl)
      (hDecl : decl ∈ mod.nodes)
      (hName : decl.node = target) :
      Admits mod (GraphExpr.node target) (CertifiedGraph.nodeOf (mod := mod) decl)
  /-- Admit an unresolved graph-binding leaf as a placeholder object.

  Slice 2 records the binding reference in `usedRefs` but does not unfold the
  binding's right-hand side, so the object has an empty node domain. Recursive
  binding admission is a later obligation. -/
  | binding
      {mod : AdmittedModuleShell}
      {target : BindingName}
      (hRef : target ∈ mod.graphs.map GraphBinding.name) :
      Admits mod
        (GraphExpr.binding target)
        (CertifiedGraph.bindingOf (mod := mod) target)
  | overlay
      {mod : AdmittedModuleShell}
      {leftExpr rightExpr : GraphExpr}
      {leftGraph rightGraph : CertifiedGraph mod}
      (hLeft : Admits mod leftExpr leftGraph)
      (hRight : Admits mod rightExpr rightGraph)
      (hDisjoint : CertifiedGraph.Disjoint leftGraph rightGraph) :
      Admits mod
        (GraphExpr.overlay leftExpr rightExpr)
        (CertifiedGraph.overlayOf leftGraph rightGraph hDisjoint)
  | connect
      {mod : AdmittedModuleShell}
      {leftExpr rightExpr : GraphExpr}
      {leftGraph rightGraph : CertifiedGraph mod}
      (hLeft : Admits mod leftExpr leftGraph)
      (hRight : Admits mod rightExpr rightGraph)
      (hDisjoint : CertifiedGraph.Disjoint leftGraph rightGraph)
      (matched : CertifiedGraph.BoundaryMatchTrace leftGraph rightGraph hDisjoint) :
      Admits mod
        (GraphExpr.connect leftExpr rightExpr)
        (CertifiedGraph.connectOf leftGraph rightGraph hDisjoint matched)

/-! ## Disjoint-Ledger Projections -/

namespace CertifiedGraph

variable {mod : AdmittedModuleShell}

/-- Admitted overlays carry disjoint binding-reference ledgers.

This is the slice-2 load-bearing invariant: it does not depend on the node
domain of either subgraph, so it survives the case where a binding leaf has
empty `usedNodes`. -/
theorem admits_overlay_usedRefs_disjoint
    {leftExpr rightExpr : GraphExpr}
    {leftGraph rightGraph : CertifiedGraph mod}
    {hDisjoint : Disjoint leftGraph rightGraph}
    (_hAdmits :
      Admits mod
        (GraphExpr.overlay leftExpr rightExpr)
        (overlayOf leftGraph rightGraph hDisjoint)) :
    ∀ binding,
      binding ∈ leftGraph.usedRefs →
        binding ∈ rightGraph.usedRefs →
          False :=
  hDisjoint.refs

/-- Admitted overlays carry disjoint node-identity ledgers.

The disjointness witness is the `NodeDisjoint` projection of the source
linear-port-object `DomainDisjoint` requirement; it is transported through
`usedNodes_eq` to the explicit ledger. -/
theorem admits_overlay_usedNodes_disjoint
    {leftExpr rightExpr : GraphExpr}
    {leftGraph rightGraph : CertifiedGraph mod}
    {hDisjoint : Disjoint leftGraph rightGraph}
    (_hAdmits :
      Admits mod
        (GraphExpr.overlay leftExpr rightExpr)
        (overlayOf leftGraph rightGraph hDisjoint)) :
    ∀ identity,
      identity ∈ leftGraph.usedNodes →
        identity ∈ rightGraph.usedNodes →
          False := by
  intro identity hLeft hRight
  have hLeftGraph : identity ∈ leftGraph.object.graph.nodes := by
    rw [leftGraph.usedNodes_eq]
    exact hLeft
  have hRightGraph : identity ∈ rightGraph.object.graph.nodes := by
    rw [rightGraph.usedNodes_eq]
    exact hRight
  exact hDisjoint.domain.left identity hLeftGraph hRightGraph

/-- Binding leaves cannot be overlaid with themselves.

This is the slice-2 corollary the `usedRefs` ledger actually serves: the
`overlay` constructor would need a `Disjoint.refs` witness proving `{binding}`
disjoint from itself. The statement is intentionally scoped to binding leaves.
It is not a universal `a <> a` rejection theorem: vacuous expressions such as
`empty <> empty` remain admissible because both node and binding ledgers are
empty. -/
theorem admits_overlay_self_binding_false
    (binding : BindingName) :
    ¬ ∃ graph : CertifiedGraph mod,
        Admits mod
          (GraphExpr.overlay
            (GraphExpr.binding binding)
            (GraphExpr.binding binding))
          graph := by
  rintro ⟨graph, hAdmits⟩
  cases hAdmits with
  | overlay hLeft hRight hDisjoint =>
      cases hLeft with
      | binding _hLeftRef =>
          cases hRight with
          | binding _hRightRef =>
              exact
                hDisjoint.refs binding
                  (Finset.mem_singleton.mpr rfl)
                  (Finset.mem_singleton.mpr rfl)

/-! ## Forgetful Lowering -/

/-- Forgetful node-domain lowering for an admitted overlay.

Admission of `overlay leftExpr rightExpr` produces a certified graph whose
underlying source linear-port object is exactly `LinearPortObject.overlay`
applied to the per-side certified objects. The two `usedRefs` and `usedNodes`
fields are unions, mirroring the same algebraic shape one layer up.

This is the `overlay` half of the forgetful lowering theorem: admission
commutes with `LinearPortObject.overlay`. -/
theorem admits_overlay_object_eq
    {leftExpr rightExpr : GraphExpr}
    {leftGraph rightGraph : CertifiedGraph mod}
    {hDisjoint : Disjoint leftGraph rightGraph}
    (_hAdmits :
      Admits mod
        (GraphExpr.overlay leftExpr rightExpr)
        (overlayOf leftGraph rightGraph hDisjoint)) :
    (overlayOf leftGraph rightGraph hDisjoint).object =
        LinearPortObject.overlay leftGraph.object rightGraph.object hDisjoint.domain :=
  rfl

/-- Forgetful node-domain lowering for an admitted connect.

Admission of `connect leftExpr rightExpr` produces a certified object whose graph
is the final graph of the supplied boundary trace. -/
theorem admits_connect_object_graph_eq
    {leftExpr rightExpr : GraphExpr}
    {leftGraph rightGraph : CertifiedGraph mod}
    {hDisjoint : Disjoint leftGraph rightGraph}
    {matched : BoundaryMatchTrace leftGraph rightGraph hDisjoint}
    (_hAdmits :
      Admits mod
        (GraphExpr.connect leftExpr rightExpr)
        (connectOf leftGraph rightGraph hDisjoint matched)) :
    (connectOf leftGraph rightGraph hDisjoint matched).object.graph =
      matched.finish :=
  rfl

end CertifiedGraph

end ElaborationIR
end Cortex.Wire
