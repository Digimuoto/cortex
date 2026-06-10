import Cortex.Wire.GraphElaboration

/-!
## Overview

Frontier typing judgment for the primitive graph-expression subset: the
declarative form of the keyed-frontier rules (T-Empty, T-Node, T-Overlay,
T-Connect), stated over node-qualified port-instance frontiers, together with
the correspondence theorem from the mechanized admission relation.

`FrontierTyped mod expr outputs inputs` mirrors the manuscript's judgment
`Γ ⊢ e ▷ ⟨N; E; Φ⁻; Φ⁺⟩` restricted to its frontier components: overlay is
disjoint union, and connect removes exactly the matched compatible pairs from
the union frontier, with the match set pinned extensionally (T-Connect's
matching premise). `frontierTyped_of_admits` proves every admitted certified
graph is frontier-typed at exactly its exposed boundary: the typing derivation
the paper presents is realized by the admission relation's carrier, closing
the typing-judgment-to-carrier correspondence for the primitive subset. The
trace-side bookkeeping is `BulkContract.contractedOutputs/contractedInputs`
with their exposure-evolution lemmas: contraction erases exactly the
contracted endpoints from the exposed frontier.
-/

namespace Cortex.Wire
namespace LinearPortGraph

variable {node outputPort inputPort : Type}
variable [DecidableEq node]
variable [DecidableEq outputPort]
variable [DecidableEq inputPort]

/-- Output instances contracted by a certified trace. -/
def BulkContract.contractedOutputs :
    {start finish : LinearPortGraph node outputPort inputPort} →
      BulkContract start finish →
        Finset (SourcePortInstance node outputPort)
  | _, _, BulkContract.done _graph => ∅
  | _, _, BulkContract.step _graph output _input _hOutput _hInput tail =>
      insert output (BulkContract.contractedOutputs tail)

/-- Input instances contracted by a certified trace. -/
def BulkContract.contractedInputs :
    {start finish : LinearPortGraph node outputPort inputPort} →
      BulkContract start finish →
        Finset (SourcePortInstance node inputPort)
  | _, _, BulkContract.done _graph => ∅
  | _, _, BulkContract.step _graph _output input _hOutput _hInput tail =>
      insert input (BulkContract.contractedInputs tail)

/-- A contracted output is exactly an output some trace pair contains.

Stated over the elaboration-IR instantiation because the pair predicate
(`BulkContractContainsPair`) is defined there. -/
theorem BulkContract.mem_contractedOutputs
    {start finish :
      LinearPortGraph ElaborationIR.NodeId
        ElaborationIR.OutputPortSignature ElaborationIR.InputPortSignature}
    (hBulk : BulkContract start finish)
    (output : SourcePortInstance ElaborationIR.NodeId ElaborationIR.OutputPortSignature) :
    output ∈ hBulk.contractedOutputs ↔
      ∃ input, ElaborationIR.CertifiedGraph.BulkContractContainsPair hBulk output input := by
  induction hBulk with
  | done graph =>
      simp [BulkContract.contractedOutputs, ElaborationIR.CertifiedGraph.BulkContractContainsPair]
  | step graph stepOutput stepInput hOutput hInput tail ih =>
      simp only [BulkContract.contractedOutputs,
        ElaborationIR.CertifiedGraph.BulkContractContainsPair, Finset.mem_insert, ih]
      constructor
      · rintro (rfl | ⟨input, hPair⟩)
        · exact ⟨stepInput, Or.inl ⟨rfl, rfl⟩⟩
        · exact ⟨input, Or.inr hPair⟩
      · rintro ⟨input, ⟨rfl, rfl⟩ | hPair⟩
        · exact Or.inl rfl
        · exact Or.inr ⟨input, hPair⟩

/-- A contracted input is exactly an input some trace pair contains.

Stated over the elaboration-IR instantiation because the pair predicate
(`BulkContractContainsPair`) is defined there. -/
theorem BulkContract.mem_contractedInputs
    {start finish :
      LinearPortGraph ElaborationIR.NodeId
        ElaborationIR.OutputPortSignature ElaborationIR.InputPortSignature}
    (hBulk : BulkContract start finish)
    (input : SourcePortInstance ElaborationIR.NodeId ElaborationIR.InputPortSignature) :
    input ∈ hBulk.contractedInputs ↔
      ∃ output, ElaborationIR.CertifiedGraph.BulkContractContainsPair hBulk output input := by
  induction hBulk with
  | done graph =>
      simp [BulkContract.contractedInputs, ElaborationIR.CertifiedGraph.BulkContractContainsPair]
  | step graph stepOutput stepInput hOutput hInput tail ih =>
      simp only [BulkContract.contractedInputs,
        ElaborationIR.CertifiedGraph.BulkContractContainsPair, Finset.mem_insert, ih]
      constructor
      · rintro (rfl | ⟨output, hPair⟩)
        · exact ⟨stepOutput, Or.inl ⟨rfl, rfl⟩⟩
        · exact ⟨output, Or.inr hPair⟩
      · rintro ⟨output, ⟨rfl, rfl⟩ | hPair⟩
        · exact Or.inl rfl
        · exact Or.inr ⟨output, hPair⟩

/-- Certified contraction erases exactly the contracted outputs from the
exposed output frontier. -/
theorem BulkContract.finish_exposedOutputs
    {start finish : LinearPortGraph node outputPort inputPort}
    (hBulk : BulkContract start finish) :
    finish.exposedOutputs = start.exposedOutputs \ hBulk.contractedOutputs := by
  induction hBulk with
  | done graph =>
      simp [BulkContract.contractedOutputs]
  | step graph output input hOutput hInput tail ih =>
      rw [ih]
      ext candidate
      simp only [Finset.mem_sdiff, BulkContract.contractedOutputs, Finset.mem_insert,
        contract, Finset.mem_erase]
      tauto

/-- Certified contraction erases exactly the contracted inputs from the
exposed input frontier. -/
theorem BulkContract.finish_exposedInputs
    {start finish : LinearPortGraph node outputPort inputPort}
    (hBulk : BulkContract start finish) :
    finish.exposedInputs = start.exposedInputs \ hBulk.contractedInputs := by
  induction hBulk with
  | done graph =>
      simp [BulkContract.contractedInputs]
  | step graph output input hOutput hInput tail ih =>
      rw [ih]
      ext candidate
      simp only [Finset.mem_sdiff, BulkContract.contractedInputs, Finset.mem_insert,
        contract, Finset.mem_erase]
      tauto

end LinearPortGraph

namespace ElaborationIR

open Cortex.Wire.LinearPortGraph

/-- Frontier typing judgment for the primitive subset: the declarative
keyed-frontier rules over node-qualified port-instance frontiers.

The connect rule's `matched` premise is T-Connect's matching condition stated
extensionally: the match set is exactly the compatible pairs of the operand
frontiers. Linearity side conditions (operand disjointness) are carried by the
admission relation this judgment corresponds to; the judgment itself only
fixes how frontiers compose. -/
inductive FrontierTyped (mod : AdmittedModuleShell) :
    GraphExpr →
      Finset (SourcePortInstance NodeId OutputPortSignature) →
        Finset (SourcePortInstance NodeId InputPortSignature) →
          Prop where
  | empty :
      FrontierTyped mod GraphExpr.empty ∅ ∅
  | node
      {target : NodeId}
      (decl : AcceptedNodeDecl)
      (hDecl : decl ∈ mod.nodes)
      (hName : decl.node = target) :
      FrontierTyped mod (GraphExpr.node target)
        decl.toLinearPortObject.graph.exposedOutputs
        decl.toLinearPortObject.graph.exposedInputs
  | binding
      {target : BindingName}
      (hRef : target ∈ mod.graphs.map GraphBinding.name) :
      FrontierTyped mod (GraphExpr.binding target) ∅ ∅
  | overlay
      {leftExpr rightExpr : GraphExpr}
      {leftOutputs rightOutputs : Finset (SourcePortInstance NodeId OutputPortSignature)}
      {leftInputs rightInputs : Finset (SourcePortInstance NodeId InputPortSignature)}
      (hLeft : FrontierTyped mod leftExpr leftOutputs leftInputs)
      (hRight : FrontierTyped mod rightExpr rightOutputs rightInputs) :
      FrontierTyped mod (GraphExpr.overlay leftExpr rightExpr)
        (leftOutputs ∪ rightOutputs)
        (leftInputs ∪ rightInputs)
  | connect
      {leftExpr rightExpr : GraphExpr}
      {leftOutputs rightOutputs : Finset (SourcePortInstance NodeId OutputPortSignature)}
      {leftInputs rightInputs : Finset (SourcePortInstance NodeId InputPortSignature)}
      (matched :
        Finset
          (SourcePortInstance NodeId OutputPortSignature ×
            SourcePortInstance NodeId InputPortSignature))
      (hLeft : FrontierTyped mod leftExpr leftOutputs leftInputs)
      (hRight : FrontierTyped mod rightExpr rightOutputs rightInputs)
      (hMatched :
        ∀ output input,
          (output, input) ∈ matched ↔
            output ∈ leftOutputs ∧
              input ∈ rightInputs ∧
                output.port.signature = input.port.signature) :
      FrontierTyped mod (GraphExpr.connect leftExpr rightExpr)
        ((leftOutputs ∪ rightOutputs) \ matched.image Prod.fst)
        ((leftInputs ∪ rightInputs) \ matched.image Prod.snd)

namespace CertifiedGraph

variable {mod : AdmittedModuleShell}

/-- Every admitted certified graph is frontier-typed at exactly its exposed
boundary: the declarative typing rules are realized by the admission
relation's carrier. -/
theorem frontierTyped_of_admits
    {expr : GraphExpr}
    {graph : CertifiedGraph mod}
    (hAdmits : Admits mod expr graph) :
    FrontierTyped mod expr
      graph.object.graph.exposedOutputs
      graph.object.graph.exposedInputs := by
  induction hAdmits with
  | empty =>
      exact FrontierTyped.empty
  | node decl hDecl hName =>
      exact FrontierTyped.node decl hDecl hName
  | binding hRef =>
      exact FrontierTyped.binding hRef
  | overlay hLeft hRight hDisjoint ihLeft ihRight =>
      exact FrontierTyped.overlay ihLeft ihRight
  | connect hLeft hRight hDisjoint matched ihLeft ihRight =>
      rename_i leftGraph rightGraph
      have hOutputs :
          (CertifiedGraph.connectOf leftGraph rightGraph hDisjoint
                matched).object.graph.exposedOutputs =
            (leftGraph.object.graph.exposedOutputs ∪
                rightGraph.object.graph.exposedOutputs) \
              matched.bulk.contractedOutputs :=
        matched.bulk.finish_exposedOutputs
      have hInputs :
          (CertifiedGraph.connectOf leftGraph rightGraph hDisjoint
                matched).object.graph.exposedInputs =
            (leftGraph.object.graph.exposedInputs ∪
                rightGraph.object.graph.exposedInputs) \
              matched.bulk.contractedInputs :=
        matched.bulk.finish_exposedInputs
      rw [hOutputs, hInputs]
      have hPairs :
          ∀ output input,
            BulkContractContainsPair matched.bulk output input ↔
              CompatiblePair leftGraph rightGraph output input :=
        matched.determined
      have hMatchedOutputs :
          matched.bulk.contractedOutputs =
            ((leftGraph.object.graph.exposedOutputs ×ˢ
                  rightGraph.object.graph.exposedInputs).filter
                (fun pair => pair.1.port.signature = pair.2.port.signature)).image
              Prod.fst := by
        ext output
        simp only [matched.bulk.mem_contractedOutputs, Finset.mem_image, Finset.mem_filter,
          Finset.mem_product]
        constructor
        · rintro ⟨input, hPair⟩
          have hCompatible := (hPairs output input).mp hPair
          exact ⟨(output, input), ⟨⟨hCompatible.1, hCompatible.2.1⟩, hCompatible.2.2⟩, rfl⟩
        · rintro ⟨⟨pairOutput, pairInput⟩, ⟨⟨hOut, hIn⟩, hSig⟩, rfl⟩
          exact ⟨pairInput, (hPairs _ pairInput).mpr ⟨hOut, hIn, hSig⟩⟩
      have hMatchedInputs :
          matched.bulk.contractedInputs =
            ((leftGraph.object.graph.exposedOutputs ×ˢ
                  rightGraph.object.graph.exposedInputs).filter
                (fun pair => pair.1.port.signature = pair.2.port.signature)).image
              Prod.snd := by
        ext input
        simp only [matched.bulk.mem_contractedInputs, Finset.mem_image, Finset.mem_filter,
          Finset.mem_product]
        constructor
        · rintro ⟨output, hPair⟩
          have hCompatible := (hPairs output input).mp hPair
          exact ⟨(output, input), ⟨⟨hCompatible.1, hCompatible.2.1⟩, hCompatible.2.2⟩, rfl⟩
        · rintro ⟨⟨pairOutput, pairInput⟩, ⟨⟨hOut, hIn⟩, hSig⟩, rfl⟩
          exact ⟨pairOutput, (hPairs pairOutput _).mpr ⟨hOut, hIn, hSig⟩⟩
      rw [hMatchedOutputs, hMatchedInputs]
      exact
        FrontierTyped.connect
          ((leftGraph.object.graph.exposedOutputs ×ˢ
                rightGraph.object.graph.exposedInputs).filter
              (fun pair => pair.1.port.signature = pair.2.port.signature))
          ihLeft ihRight
          (fun output input => by
            simp [Finset.mem_filter, Finset.mem_product, and_assoc])

end CertifiedGraph

end ElaborationIR
end Cortex.Wire
