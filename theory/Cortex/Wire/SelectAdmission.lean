import Mathlib.Data.List.Perm.Basic
import Cortex.Wire.ElaborationIR
import Cortex.Wire.Select

/-!
## Overview

Source-level admission for Wire `select(...)` clauses.

## Context

ADR 0033 fixes `select(...)` as a guarded-affine collapse over an exclusive
output sum on the base graph. ADR 0034 narrows the runtime authority of pure
select to actualizing exactly one already-admitted latent arm. The downstream
proof object for that selected arm is `Cortex.Wire.Select.LatentBranchFamily`,
together with `SelectActualize` for the chosen arm.

This module sits one step earlier: it admits the *source* shape of a
`select(...)` clause against the base graph's exclusive output sum boundary.
Admission resolves arm keys, rejects duplicates, unknown source keys, and
uncovered shape arms, and emits a `LatentSelectAdmission` carrier that records
each arm body as *latent* — that is, attached to its admitted arm key without
being overlaid into live topology. Conversion to a `LatentBranchFamily` is a
separate bridge step that requires the caller to supply the per-arm
`SubgraphSpec` together with its disjointness witness; this module does not
synthesize one.

## Theorem Split

The page proves:

* arm-key resolution against an exclusive output sum is decidable, deterministic,
  and total: every admitted arm is matched to exactly one sum-group key, and the
  full sum-group must be covered;
* admission rejects duplicate, unknown, and uncovered arms with explicit
  diagnostics;
* successful admission produces a `LatentSelectAdmission` whose arm-key set is
  an order-insensitive permutation of the sum-group keys, and whose arm bodies
  remain latent;
* successful `admitClause` and `admitClauseAtNode` construction witness
  `LatentSelectAdmission.FromClause`, tying admitted latent bodies back to their
  source arms;
* a bridging constructor lifts a `LatentSelectAdmission` together with a
  caller-supplied `SubgraphSpec` family into a `LatentBranchFamily`.
-/

namespace Cortex.Wire
namespace SelectAdmission

open Cortex.Wire.ElaborationIR

/-! ## Selectable Output Shape -/

/-- `SelectableOutputShape` is the resolved exclusive-output-sum boundary that
source `select(...)` admission consumes.

`OutputShape` keeps authored node egresses in the local declaration carrier.
`SelectableOutputShape` is its select-specific projection: a list of
`(SelectArmKey, PortSignature)` entries describing the exclusive output sum
carried by the base of a `select` clause, together with the uniqueness and
validity witnesses required for arm-key resolution and frontier flattening.

The arm-key list, port-label list, and uniqueness witnesses are exactly the
obligations projected from `OutputShape.LocallyAdmissible.sumGroup`. -/
structure SelectableOutputShape where
  /-- Arms of the exclusive output sum, in source order, paired with the port
  signature each arm exposes when selected. -/
  armPorts : List (SelectArmKey × PortSignature)
  /-- Exclusive output sums have at least two arms; one-arm outputs are `single`. -/
  armsAtLeastTwo : 2 ≤ armPorts.length
  /-- Sum-group arm keys are unique. -/
  armKeysUnique : (armPorts.map Prod.fst).Nodup
  /-- Flattened port labels exposed by sum-group arms are unique. -/
  portLabelsUnique : (armPorts.map (fun entry => entry.snd.label)).Nodup
  /-- Each arm key is locally valid. -/
  armKeysValid : ∀ entry, entry ∈ armPorts → entry.fst.Valid
  /-- Each arm port signature is locally valid. -/
  armPortsValid : ∀ entry, entry ∈ armPorts → entry.snd.Valid
  deriving Repr

namespace SelectableOutputShape

/-- Sum-group arm keys exposed by an output shape. -/
def armKeys (shape : SelectableOutputShape) : List SelectArmKey :=
  shape.armPorts.map Prod.fst

/-- Look up the port signature for an arm key. The entry is unique because
`armKeysUnique` rules out duplicate keys. -/
def portFor? (shape : SelectableOutputShape) (key : SelectArmKey) :
    Option PortSignature :=
  (shape.armPorts.find? (fun entry => entry.fst = key)).map Prod.snd

/-- Membership in the arm-key projection is decidable. -/
instance hasKeyDecidable (shape : SelectableOutputShape) (key : SelectArmKey) :
    Decidable (key ∈ shape.armKeys) :=
  inferInstanceAs (Decidable (key ∈ shape.armPorts.map Prod.fst))

/-- Build a `SelectableOutputShape` from the source data of an exclusive output sum
group. The constructor consumes exactly the admissibility witnesses produced by
`OutputShape.LocallyAdmissible.sumGroup`, so admitted accepted nodes can project
into a select base shape without losing the source-side uniqueness obligations. -/
def ofSumGroupArms
    (arms : List OutputArmDecl)
    (hArmsAtLeastTwo : 2 ≤ arms.length)
    (hArmKeysUnique : (arms.map OutputArmDecl.armKey).Nodup)
    (hPortLabelsUnique : (arms.map (fun arm => arm.port.label)).Nodup)
    (hArmsValid : ∀ arm, arm ∈ arms → arm.Valid) :
    SelectableOutputShape :=
  let armPorts := arms.map (fun arm => (arm.armKey, arm.port))
  { armPorts := armPorts
    armsAtLeastTwo := by
      show 2 ≤ (arms.map (fun arm => (arm.armKey, arm.port))).length
      simpa using hArmsAtLeastTwo
    armKeysUnique := by
      show (arms.map (fun arm => (arm.armKey, arm.port)) |>.map Prod.fst).Nodup
      simpa [List.map_map, Function.comp] using hArmKeysUnique
    portLabelsUnique := by
      show (arms.map (fun arm => (arm.armKey, arm.port))
              |>.map (fun entry => entry.snd.label)).Nodup
      simpa [List.map_map, Function.comp] using hPortLabelsUnique
    armKeysValid := by
      intro entry hEntry
      have hEntry' :
          entry ∈ arms.map (fun arm => (arm.armKey, arm.port)) := hEntry
      rcases List.mem_map.mp hEntry' with ⟨arm, hArmMem, hEq⟩
      subst hEq
      exact (hArmsValid arm hArmMem).left
    armPortsValid := by
      intro entry hEntry
      have hEntry' :
          entry ∈ arms.map (fun arm => (arm.armKey, arm.port)) := hEntry
      rcases List.mem_map.mp hEntry' with ⟨arm, hArmMem, hEq⟩
      subst hEq
      exact (hArmsValid arm hArmMem).right }

/-- Extract the two-or-more arm-count obligation carried by a sum-group witness. -/
private theorem armsAtLeastTwo_of_sumGroup_admissible
    {arms : List OutputArmDecl}
    (h : ElaborationIR.OutputShape.LocallyAdmissible
          (ElaborationIR.OutputShape.sumGroup arms)) :
    2 ≤ arms.length := by
  cases h with
  | sumGroup hAtLeastTwo _hValid _hKeyNodup _hLabelNodup => exact hAtLeastTwo

/-- Extract the arm-key uniqueness obligation carried by a sum-group
admissibility witness. -/
private theorem armKeysUnique_of_sumGroup_admissible
    {arms : List OutputArmDecl}
    (h : ElaborationIR.OutputShape.LocallyAdmissible
          (ElaborationIR.OutputShape.sumGroup arms)) :
    (arms.map OutputArmDecl.armKey).Nodup := by
  cases h with
  | sumGroup _hAtLeastTwo _hValid hKeyNodup _hLabelNodup => exact hKeyNodup

/-- Extract the port-label uniqueness obligation carried by a sum-group
admissibility witness. -/
private theorem portLabelsUnique_of_sumGroup_admissible
    {arms : List OutputArmDecl}
    (h : ElaborationIR.OutputShape.LocallyAdmissible
          (ElaborationIR.OutputShape.sumGroup arms)) :
    (arms.map (fun arm => arm.port.label)).Nodup := by
  cases h with
  | sumGroup _hAtLeastTwo _hValid _hKeyNodup hLabelNodup => exact hLabelNodup

/-- Extract per-arm validity from a sum-group admissibility witness. -/
private theorem armsValid_of_sumGroup_admissible
    {arms : List OutputArmDecl}
    (h : ElaborationIR.OutputShape.LocallyAdmissible
          (ElaborationIR.OutputShape.sumGroup arms)) :
    ∀ arm, arm ∈ arms → arm.Valid := by
  cases h with
  | sumGroup _hAtLeastTwo hValid _hKeyNodup _hLabelNodup => exact hValid

/-- Extract per-arm port validity from a sum-group admissibility witness. -/
private theorem armPortsValid_of_sumGroup_admissible
    {arms : List OutputArmDecl}
    (h : ElaborationIR.OutputShape.LocallyAdmissible
          (ElaborationIR.OutputShape.sumGroup arms)) :
    ∀ arm, arm ∈ arms → arm.port.Valid := by
  cases h with
  | sumGroup _hAtLeastTwo hValid _hKeyNodup _hLabelNodup =>
      intro arm hArmMem
      exact (hValid arm hArmMem).right

/-- Project an authored `OutputShape` into a `SelectableOutputShape`. Returns
`none` when the shape is a single non-sum output: select admission must surface
`SelectAdmissionError.nonExclusiveBase` for that case. -/
def ofOutputShape? :
    (shape : ElaborationIR.OutputShape) → shape.LocallyAdmissible →
      Option SelectableOutputShape
  | ElaborationIR.OutputShape.single _, _ => none
  | ElaborationIR.OutputShape.sumGroup arms, h =>
      some
        (ofSumGroupArms arms
          (armsAtLeastTwo_of_sumGroup_admissible h)
          (armKeysUnique_of_sumGroup_admissible h)
          (portLabelsUnique_of_sumGroup_admissible h)
          (armsValid_of_sumGroup_admissible h))

/-- Project an `AcceptedNodeDecl` whose authored output frontier is exactly one
exclusive output sum group into a `SelectableOutputShape`. Any other frontier
shape (no outputs, multiple shapes, or a single non-sum output) yields `none`,
which select admission must report as `SelectAdmissionError.nonExclusiveBase`. -/
def ofAcceptedNode? (decl : AcceptedNodeDecl) :
    Option SelectableOutputShape :=
  match h : decl.outputs with
  | [] => none
  | [shape] =>
      have hMem : shape ∈ decl.outputs :=
        h.symm ▸ List.mem_singleton.mpr rfl
      ofOutputShape? shape (decl.outputShapesAdmissible shape hMem)
  | _ :: _ :: _ => none

/-- Sum-group projection produces an arm count equal to the source arm count. -/
theorem ofSumGroupArms_armPorts_length
    (arms : List OutputArmDecl)
    (hArmsAtLeastTwo : 2 ≤ arms.length)
    (hArmKeysUnique : (arms.map OutputArmDecl.armKey).Nodup)
    (hPortLabelsUnique : (arms.map (fun arm => arm.port.label)).Nodup)
    (hArmsValid : ∀ arm, arm ∈ arms → arm.Valid) :
    (ofSumGroupArms
      arms
      hArmsAtLeastTwo
      hArmKeysUnique
      hPortLabelsUnique
      hArmsValid).armPorts.length =
      arms.length := by
  simp [ofSumGroupArms]

end SelectableOutputShape

/-! ## Source Select Clause -/

/-- One source arm of a `select(...)` clause, parameterized over the latent body
type so this carrier is reusable across slices that supply different downstream
objects (raw `GraphExpr`, `SubgraphSpec node`, `LinearPortObject`, …). -/
structure SelectArm (body : Type) where
  /-- Source-stable arm key written by the author. -/
  key : SelectArmKey
  /-- Latent body for this arm, kept opaque at this admission layer. -/
  body : body
  deriving Repr

/-- Source `select(...)` clause carrier. The base is an opaque graph or
graph-expression value; the integrator will refine it to the slice 1 base
carrier. The arm-list shape mirrors the existing `GraphExpr.select`
constructor in `ElaborationIR`. -/
structure SelectExpr (base : Type) (body : Type) where
  /-- Base graph exposing the exclusive output sum. -/
  base : base
  /-- Arms in source order. -/
  arms : List (SelectArm body)
  deriving Repr

namespace SelectExpr

/-- Project the arm key list from a source `select` clause. -/
def armKeys {base body : Type} (clause : SelectExpr base body) :
    List SelectArmKey :=
  clause.arms.map SelectArm.key

end SelectExpr

/-! ## Diagnostics -/

/-- Static admission diagnostics emitted while resolving a source `select(...)`
clause against an exclusive output sum boundary. -/
inductive SelectAdmissionError where
  /-- Two source arms wrote the same arm key. -/
  | duplicateSelectArmKey (key : SelectArmKey)
  /-- A source arm key does not resolve to any sum-group label or unique contract fallback. -/
  | unknownSourceKey (key : SelectArmKey)
  /-- A sum-group entry has no source arm and total coverage is required. -/
  | uncoveredShapeArm (key : SelectArmKey)
  /-- Contract-based fallback found multiple candidate keys for one arm. -/
  | ambiguousContractFallback (contract : ContractId) (candidates : List SelectArmKey)
  /-- The base graph does not expose an exclusive output sum at this position. -/
  | nonExclusiveBase
  deriving DecidableEq, Repr

/-! ## Latent Admission Carrier -/

/-- `LatentSelectAdmission` is the proof-side carrier produced by successful
source admission of a `select(...)` clause.

Each admitted entry pairs a sum-group arm key with the source arm body that was
matched against it. The bodies are *latent*: this carrier intentionally does not
overlay the bodies into live topology. The downstream `SelectActualize` model
materializes one body when the runtime selector picks an arm.

This carrier is parameterized over the body type so callers can attach
`SubgraphSpec`, `GraphExpr`, or any other latent payload without coupling
admission to a single proof carrier.

By itself the record enforces key coverage up to permutation, not source order
or body provenance: a hand-built value can pair the right keys with arbitrary
bodies. Consumers that need runtime/source correspondence should require
`LatentSelectAdmission.FromClause` for the concrete source clause. -/
structure LatentSelectAdmission (body : Type) where
  /-- The output shape the source clause was admitted against. -/
  shape : SelectableOutputShape
  /-- Per-arm-key admitted entries, one for each sum-group key. -/
  entries : List (SelectArmKey × body)
  /-- Admission emitted exactly the sum-group arm keys, up to ordering. -/
  entries_keys_perm : (entries.map Prod.fst).Perm shape.armKeys
  deriving Repr

namespace LatentSelectAdmission

/-- The admitted arm-key list is a permutation of the sum-group key list. -/
theorem keys_perm_shape_keys
    {body : Type}
    (admission : LatentSelectAdmission body) :
    (admission.entries.map Prod.fst).Perm admission.shape.armKeys :=
  admission.entries_keys_perm

/-- The admitted arm-key set equals the sum-group key set. -/
theorem keys_eq_shape_keys
    {body : Type}
    (admission : LatentSelectAdmission body) :
    (admission.entries.map Prod.fst).toFinset = admission.shape.armKeys.toFinset := by
  ext key
  simpa using admission.entries_keys_perm.mem_iff (a := key)

/-- Admission produces one entry per sum-group arm key. -/
theorem length_eq_armPorts
    {body : Type}
    (admission : LatentSelectAdmission body) :
    admission.entries.length = admission.shape.armPorts.length := by
  calc
    admission.entries.length = (admission.entries.map Prod.fst).length := by
      simp
    _ = admission.shape.armKeys.length := by
      exact admission.entries_keys_perm.length_eq
    _ = admission.shape.armPorts.length := by
      simp [SelectableOutputShape.armKeys]

/-- Admitted arm keys are unique. -/
theorem keys_nodup
    {body : Type}
    (admission : LatentSelectAdmission body) :
    (admission.entries.map Prod.fst).Nodup := by
  exact admission.entries_keys_perm.nodup_iff.mpr admission.shape.armKeysUnique

end LatentSelectAdmission

/-! ## Source Admission -/

/-- Reject a `select(...)` source arm list that contains a duplicate key. -/
def detectDuplicateArm
    (keys : List SelectArmKey) :
    Except SelectAdmissionError Unit :=
  keys.foldl
    (fun (acc : Except SelectAdmissionError (List SelectArmKey)) (key : SelectArmKey) =>
      acc.bind (fun seen =>
        if key ∈ seen then
          Except.error (SelectAdmissionError.duplicateSelectArmKey key)
        else
          Except.ok (key :: seen)))
    (Except.ok []) |>.map (fun _ => ())

/-- Look up an arm body in the source arm list by key. The list-shaped lookup
preserves source-order diagnostics if the same key appears twice. -/
def findArmBody?
    {body : Type}
    (arms : List (SelectArm body))
    (key : SelectArmKey) :
    Option body :=
  (arms.find? (fun arm => arm.key = key)).map SelectArm.body

/-- Candidate label keys whose variant contract matches a contract fallback key. -/
def contractFallbackCandidates
    (shape : SelectableOutputShape)
    (contract : ContractId) :
    List SelectArmKey :=
  (shape.armPorts.filter (fun entry => entry.snd.contract = contract)).map Prod.fst

/-- Resolve a source arm key to the canonical variant label key.

Executable Wire resolves labels first. If no label matches, the same token is
interpreted as a contract-name fallback and accepted only when that contract
appears on exactly one variant. The fallback returns the canonical label key,
not the `ContractId`; faithfulness therefore depends on the one-variant
contract match checked here, while ordinary label resolution remains keyed by
the source-visible arm label. -/
def resolveArmKey
    (shape : SelectableOutputShape)
    (key : SelectArmKey) :
    Except SelectAdmissionError SelectArmKey :=
  if key ∈ shape.armKeys then
    Except.ok key
  else
    let contract : ContractId := ⟨key.name⟩
    match contractFallbackCandidates shape contract with
    | [] => Except.error (SelectAdmissionError.unknownSourceKey key)
    | [candidate] => Except.ok candidate
    | first :: second :: rest =>
        Except.error
          (SelectAdmissionError.ambiguousContractFallback contract (first :: second :: rest))

/-- Resolve one source arm to the canonical label key it targets. -/
def resolveArm
    {body : Type}
    (shape : SelectableOutputShape)
    (arm : SelectArm body) :
    Except SelectAdmissionError (SelectArm body) :=
  (resolveArmKey shape arm.key).map
    (fun key => { key := key, body := arm.body })

/-- Resolve all source arms in source order. -/
def resolveArms
    {body : Type}
    (shape : SelectableOutputShape) :
    List (SelectArm body) → Except SelectAdmissionError (List (SelectArm body))
  | [] => Except.ok []
  | arm :: rest =>
      (resolveArm shape arm).bind (fun resolved =>
        (resolveArms shape rest).map (fun resolvedRest => resolved :: resolvedRest))

/-- Collected admitted entries with their key-list equality bundled. -/
private structure CollectedEntries (body : Type) (keys : List SelectArmKey) where
  /-- Entries collected in the exact key order. -/
  entries : List (SelectArmKey × body)
  /-- Collected entry keys equal the requested key list. -/
  entries_keys_exact : entries.map Prod.fst = keys

/-- Build admitted entries for a concrete key list from already-resolved source arms. -/
private def collectEntriesFrom
    {body : Type}
    (armPorts : List (SelectArmKey × PortSignature))
    (arms : List (SelectArm body)) :
    Except SelectAdmissionError (CollectedEntries body (armPorts.map Prod.fst)) :=
  match armPorts with
  | [] =>
      Except.ok
        { entries := []
          entries_keys_exact := rfl }
  | armPort :: rest =>
      match findArmBody? arms armPort.fst with
      | none => Except.error (SelectAdmissionError.uncoveredShapeArm armPort.fst)
      | some bodyValue =>
          match collectEntriesFrom rest arms with
          | Except.error error => Except.error error
          | Except.ok collected =>
              Except.ok
                { entries := (armPort.fst, bodyValue) :: collected.entries
                  entries_keys_exact := by
                    simp only [List.map_cons]
                    rw [collected.entries_keys_exact] }

/-- Build admitted entries for an output shape from already-resolved source arms.
Returns an error if any sum-group key is missing in the source arm list. -/
private def collectEntries
    {body : Type}
    (shape : SelectableOutputShape)
    (arms : List (SelectArm body)) :
    Except SelectAdmissionError (CollectedEntries body shape.armKeys) :=
  collectEntriesFrom shape.armPorts arms

/-- Forget the private ordered collection proof into the public latent carrier. -/
private def collectedEntriesAdmission
    {body : Type}
    (shape : SelectableOutputShape)
    (collected : CollectedEntries body shape.armKeys) :
    LatentSelectAdmission body :=
  { shape := shape
    entries := collected.entries
    entries_keys_perm := by
      rw [collected.entries_keys_exact] }

/-- Admit a source `select(...)` clause against an exclusive output sum.

The integrator obtains `shape` by projecting slice 1's `OutputShape`. The
admission first resolves source arms to canonical variant labels: labels win,
and unique contract names are accepted as fallback keys. It then rejects
duplicate canonical arms and sum-group keys without a matching source arm. On
success, this constructor emits entries in shape order, while the public
`LatentSelectAdmission` carrier only requires order-insensitive key coverage.
The matched arm body remains latent. -/
def admitClause
    {base body : Type}
    (shape : SelectableOutputShape)
    (clause : SelectExpr base body) :
    Except SelectAdmissionError (LatentSelectAdmission body) :=
  (resolveArms shape clause.arms).bind (fun resolvedArms =>
    detectDuplicateArm (resolvedArms.map SelectArm.key) |>.bind (fun _ =>
      (collectEntries shape resolvedArms).map (fun collected =>
        collectedEntriesAdmission shape collected)))

/-- The executable `admitClause` constructor emits entries in shape-key order.

The public `LatentSelectAdmission` carrier only requires permutation-level key
coverage so hand-built witnesses are not order-coupled. This theorem exposes the
stronger fact for values that specifically came from `admitClause`. -/
theorem admitClause_entries_keys_eq_shape
    {base body : Type}
    (shape : SelectableOutputShape)
    (clause : SelectExpr base body)
    {admission : LatentSelectAdmission body}
    (hAdmit : admitClause shape clause = Except.ok admission) :
    admission.entries.map Prod.fst = shape.armKeys := by
  unfold admitClause at hAdmit
  cases hResolved : resolveArms shape clause.arms with
  | error err =>
      rw [hResolved] at hAdmit
      change Except.error err = Except.ok admission at hAdmit
      cases hAdmit
  | ok resolvedArms =>
      rw [hResolved] at hAdmit
      change
        (detectDuplicateArm (resolvedArms.map SelectArm.key)).bind
          (fun _ =>
            (collectEntries shape resolvedArms).map
              (fun collected => collectedEntriesAdmission shape collected)) =
          Except.ok admission at hAdmit
      cases hDuplicate : detectDuplicateArm (resolvedArms.map SelectArm.key) with
      | error err =>
          rw [hDuplicate] at hAdmit
          change Except.error err = Except.ok admission at hAdmit
          cases hAdmit
      | ok _unit =>
          rw [hDuplicate] at hAdmit
          change
            (collectEntries shape resolvedArms).map
              (fun collected => collectedEntriesAdmission shape collected) =
            Except.ok admission at hAdmit
          cases hCollected : collectEntries shape resolvedArms with
          | error err =>
              rw [hCollected] at hAdmit
              change Except.error err = Except.ok admission at hAdmit
              cases hAdmit
          | ok collected =>
              rw [hCollected] at hAdmit
              change Except.ok (collectedEntriesAdmission shape collected) =
                Except.ok admission at hAdmit
              cases hAdmit
              exact collected.entries_keys_exact

/-- Successful arm-body lookup returns a source arm with the requested key and body. -/
private theorem findArmBody?_some
    {body : Type}
    {arms : List (SelectArm body)}
    {key : SelectArmKey}
    {bodyValue : body}
    (hFind : findArmBody? arms key = some bodyValue) :
    ∃ arm, arm ∈ arms ∧ arm.key = key ∧ arm.body = bodyValue := by
  induction arms with
  | nil =>
      unfold findArmBody? at hFind
      simp at hFind
  | cons head tail ih =>
      unfold findArmBody? at hFind
      simp only [List.find?_cons] at hFind
      by_cases hKey : head.key = key
      · simp [hKey] at hFind
        cases hFind
        exact ⟨head, by simp, hKey, rfl⟩
      · simp [hKey] at hFind
        rcases hFind with ⟨arm, hFindTail, hArmBody⟩
        have hFindTailMapped : findArmBody? tail key = some bodyValue := by
          unfold findArmBody?
          rw [hFindTail]
          simp [hArmBody]
        rcases ih hFindTailMapped with ⟨arm, hArm, hArmKey, hArmBody⟩
        exact ⟨arm, List.mem_cons_of_mem head hArm, hArmKey, hArmBody⟩

/-- Successful single-arm resolution preserves body provenance and records the canonical key. -/
private theorem resolveArm_ok_source
    {body : Type}
    {shape : SelectableOutputShape}
    {arm resolved : SelectArm body}
    (hResolve : resolveArm shape arm = Except.ok resolved) :
    arm.body = resolved.body ∧
      resolveArmKey shape arm.key = Except.ok resolved.key := by
  unfold resolveArm at hResolve
  cases hKey : resolveArmKey shape arm.key with
  | error err =>
      rw [hKey] at hResolve
      change Except.error err = Except.ok resolved at hResolve
      cases hResolve
  | ok canonicalKey =>
      rw [hKey] at hResolve
      change Except.ok { key := canonicalKey, body := arm.body } =
        Except.ok resolved at hResolve
      cases hResolve
      exact ⟨rfl, by simp⟩

/-- Successful source-arm resolution keeps every resolved arm tied to a source arm. -/
private theorem resolveArms_mem_source
    {body : Type}
    {shape : SelectableOutputShape}
    {arms resolvedArms : List (SelectArm body)}
    (hResolved : resolveArms shape arms = Except.ok resolvedArms)
    {resolved : SelectArm body}
    (hMem : resolved ∈ resolvedArms) :
    ∃ arm, arm ∈ arms ∧
      arm.body = resolved.body ∧
        resolveArmKey shape arm.key = Except.ok resolved.key := by
  induction arms generalizing resolvedArms with
  | nil =>
      unfold resolveArms at hResolved
      cases hResolved
      cases hMem
  | cons head tail ih =>
      unfold resolveArms at hResolved
      cases hHead : resolveArm shape head with
      | error err =>
          rw [hHead] at hResolved
          change Except.error err = Except.ok resolvedArms at hResolved
          cases hResolved
      | ok resolvedHead =>
          rw [hHead] at hResolved
          change
            (resolveArms shape tail).map
              (fun resolvedRest => resolvedHead :: resolvedRest) =
            Except.ok resolvedArms at hResolved
          cases hTail : resolveArms shape tail with
          | error err =>
              rw [hTail] at hResolved
              change Except.error err = Except.ok resolvedArms at hResolved
              cases hResolved
          | ok resolvedTail =>
              rw [hTail] at hResolved
              change Except.ok (resolvedHead :: resolvedTail) =
                Except.ok resolvedArms at hResolved
              cases hResolved
              simp only [List.mem_cons] at hMem
              rcases hMem with hHeadMem | hTailMem
              · subst hHeadMem
                have hSource := resolveArm_ok_source hHead
                exact
                  ⟨ head
                  , by simp
                  , hSource.left
                  , hSource.right
                  ⟩
              · rcases ih hTail hTailMem with
                  ⟨arm, hArm, hBody, hResolvedKey⟩
                exact
                  ⟨ arm
                  , List.mem_cons_of_mem head hArm
                  , hBody
                  , hResolvedKey
                  ⟩

/-- Collected entries are sourced from the already-resolved source arm list. -/
private theorem collectEntriesFrom_mem_resolved
    {body : Type}
    {armPorts : List (SelectArmKey × PortSignature)}
    {arms : List (SelectArm body)}
    {collected : CollectedEntries body (armPorts.map Prod.fst)}
    (hCollected : collectEntriesFrom armPorts arms = Except.ok collected)
    {entry : SelectArmKey × body}
    (hEntry : entry ∈ collected.entries) :
    ∃ arm, arm ∈ arms ∧ arm.key = entry.fst ∧ arm.body = entry.snd := by
  induction armPorts with
  | nil =>
      unfold collectEntriesFrom at hCollected
      change Except.ok { entries := [], entries_keys_exact := rfl } =
        Except.ok collected at hCollected
      cases hCollected
      cases hEntry
  | cons armPort rest ih =>
      unfold collectEntriesFrom at hCollected
      cases hFind : findArmBody? arms armPort.fst with
      | none =>
          rw [hFind] at hCollected
          change Except.error (SelectAdmissionError.uncoveredShapeArm armPort.fst) =
            Except.ok collected at hCollected
          cases hCollected
      | some bodyValue =>
          rw [hFind] at hCollected
          cases hRest : collectEntriesFrom rest arms with
          | error err =>
              rw [hRest] at hCollected
              change Except.error err = Except.ok collected at hCollected
              cases hCollected
          | ok collectedRest =>
              rw [hRest] at hCollected
              change
                Except.ok
                  { entries := (armPort.fst, bodyValue) :: collectedRest.entries
                    entries_keys_exact := _ } =
                Except.ok collected at hCollected
              cases hCollected
              simp only [List.mem_cons] at hEntry
              rcases hEntry with hHead | hTail
              · cases hHead
                rcases findArmBody?_some hFind with
                  ⟨arm, hArm, hArmKey, hArmBody⟩
                exact ⟨arm, hArm, hArmKey, hArmBody⟩
              · exact ih hRest hTail

/-- Admit a source `select(...)` clause whose base is an `AcceptedNodeDecl`,
projecting the exclusive output sum from the node's authored `OutputShape`.

This is the certified entry point: it ties admission to the actual base graph
boundary instead of consuming an unrelated `SelectableOutputShape`. The
projection through `SelectableOutputShape.ofAcceptedNode?` returns `none` for
any node whose authored output frontier is not exactly one exclusive output
sum group; that case yields `SelectAdmissionError.nonExclusiveBase` rather
than admitting against an unrelated shape. -/
def admitClauseAtNode
    {body : Type}
    (clause : SelectExpr AcceptedNodeDecl body) :
    Except SelectAdmissionError (LatentSelectAdmission body) :=
  match SelectableOutputShape.ofAcceptedNode? clause.base with
  | none => Except.error SelectAdmissionError.nonExclusiveBase
  | some shape => admitClause shape clause

/-- A non-exclusive node base is rejected by `admitClauseAtNode`. -/
theorem admitClauseAtNode_nonExclusive
    {body : Type}
    (clause : SelectExpr AcceptedNodeDecl body)
    (hShape : SelectableOutputShape.ofAcceptedNode? clause.base = none) :
    admitClauseAtNode clause =
      Except.error SelectAdmissionError.nonExclusiveBase := by
  unfold admitClauseAtNode
  rw [hShape]

namespace LatentSelectAdmission

/-- Body-provenance predicate for an admitted select clause.

`LatentSelectAdmission` intentionally stays a reusable key-set carrier. This
predicate is the named obligation for slices that need to prove each latent body
came from a source arm, and that the source arm resolves to the admitted
canonical key. -/
def FromClause
    {base body : Type}
    (admission : LatentSelectAdmission body)
    (clause : SelectExpr base body) :
    Prop :=
  ∀ entry,
    entry ∈ admission.entries →
      ∃ arm,
        arm ∈ clause.arms ∧
          arm.body = entry.snd ∧
            resolveArmKey admission.shape arm.key = Except.ok entry.fst

end LatentSelectAdmission

/-- Successful `admitClause` construction witnesses source-arm body provenance. -/
theorem admitClause_fromClause
    {base body : Type}
    (shape : SelectableOutputShape)
    (clause : SelectExpr base body)
    {admission : LatentSelectAdmission body}
    (hAdmit : admitClause shape clause = Except.ok admission) :
    admission.FromClause clause := by
  unfold admitClause at hAdmit
  cases hResolved : resolveArms shape clause.arms with
  | error err =>
      rw [hResolved] at hAdmit
      change Except.error err = Except.ok admission at hAdmit
      cases hAdmit
  | ok resolvedArms =>
      rw [hResolved] at hAdmit
      change
        (detectDuplicateArm (resolvedArms.map SelectArm.key)).bind
          (fun _ =>
            (collectEntries shape resolvedArms).map
              (fun collected => collectedEntriesAdmission shape collected)) =
          Except.ok admission at hAdmit
      cases hDuplicate : detectDuplicateArm (resolvedArms.map SelectArm.key) with
      | error err =>
          rw [hDuplicate] at hAdmit
          change Except.error err = Except.ok admission at hAdmit
          cases hAdmit
      | ok _unit =>
          rw [hDuplicate] at hAdmit
          change
            (collectEntries shape resolvedArms).map
              (fun collected => collectedEntriesAdmission shape collected) =
            Except.ok admission at hAdmit
          cases hCollected : collectEntries shape resolvedArms with
          | error err =>
              rw [hCollected] at hAdmit
              change Except.error err = Except.ok admission at hAdmit
              cases hAdmit
          | ok collected =>
              rw [hCollected] at hAdmit
              change Except.ok (collectedEntriesAdmission shape collected) =
                Except.ok admission at hAdmit
              cases hAdmit
              intro entry hEntry
              rcases collectEntriesFrom_mem_resolved hCollected hEntry with
                ⟨resolvedArm, hResolvedArm, hResolvedKey, hResolvedBody⟩
              rcases resolveArms_mem_source hResolved hResolvedArm with
                ⟨sourceArm, hSourceArm, hSourceBody, hSourceKey⟩
              exact
                ⟨ sourceArm
                , hSourceArm
                , by rw [hSourceBody, hResolvedBody]
                , by rw [← hResolvedKey]; exact hSourceKey
                ⟩

/-- Successful node-based `select(...)` admission witnesses source-arm body provenance. -/
theorem admitClauseAtNode_fromClause
    {body : Type}
    (clause : SelectExpr AcceptedNodeDecl body)
    {admission : LatentSelectAdmission body}
    (hAdmit : admitClauseAtNode clause = Except.ok admission) :
    admission.FromClause clause := by
  unfold admitClauseAtNode at hAdmit
  cases hShape : SelectableOutputShape.ofAcceptedNode? clause.base with
  | none =>
      rw [hShape] at hAdmit
      change Except.error SelectAdmissionError.nonExclusiveBase =
        Except.ok admission at hAdmit
      cases hAdmit
  | some shape =>
      rw [hShape] at hAdmit
      exact admitClause_fromClause shape clause hAdmit

/-! ## Bridge Into `LatentBranchFamily` -/

/-- A caller-supplied per-arm `SubgraphSpec` family bundled with the
disjointness and validity obligations required by `LatentBranchFamily`.

This is the minimal evidence the integrator must discharge to lift a
`LatentSelectAdmission (SubgraphSpec node)` into the downstream branch family.
The bridge is intentionally not derivable inside this admission layer:
fragment validity and pairwise node disjointness depend on lower planner
machinery that is outside the source-admission scope. The owner obligation keeps
the retained rewrite anchor out of every latent fragment body before the runtime
namespacing policy qualifies those body-local nodes. -/
structure FragmentEvidence
    {node : Type}
    [DecidableEq node]
    (admission : LatentSelectAdmission (Cortex.Wire.SubgraphSpec node))
    (owner : node) : Prop where
  /-- Every entry's body is a valid inserted subgraph. -/
  fragmentsValid :
    ∀ entry, entry ∈ admission.entries → entry.snd.Valid
  /-- The retained select owner is not one of the latent fragment's local nodes. -/
  ownerNotInFragments :
    ∀ entry,
      entry ∈ admission.entries →
        owner ∉ (Cortex.Graph.denote entry.snd.topology).vertices
  /-- Distinct admitted entries expose disjoint compiler-qualified fragment
  nodes. -/
  fragmentsPairwiseDisjoint :
    ∀ left right,
      left ∈ admission.entries →
        right ∈ admission.entries →
          left.fst ≠ right.fst →
            ∀ nodeId,
              nodeId ∈ (Cortex.Graph.denote left.snd.topology).vertices →
                nodeId ∈ (Cortex.Graph.denote right.snd.topology).vertices →
                  False

/-- Local lookup lemma used by the bridge: for a duplicate-free key list,
membership uniquely determines `List.find?` over the equality predicate.

Mathlib currently has general `find?` characterizations such as
`List.find?_eq_some_iff_getElem`; under this file's imports there is no keyed
`Nodup` convenience lemma with this exact shape, so we keep the local version. -/
private theorem find_key_eq_some_of_mem_nodup
    {α β : Type}
    [DecidableEq α]
    {entries : List (α × β)}
    (hUnique : (entries.map Prod.fst).Nodup)
    {entry : α × β}
    (hEntry : entry ∈ entries) :
    entries.find? (fun candidate => candidate.fst = entry.fst) = some entry := by
  induction entries with
  | nil => cases hEntry
  | cons head tail ih =>
      simp only [List.map_cons, List.nodup_cons] at hUnique
      obtain ⟨hHeadFresh, hTailUnique⟩ := hUnique
      simp only [List.mem_cons] at hEntry
      rcases hEntry with hHeadEq | hTailMem
      · subst hHeadEq
        simp
      · have hHeadKey : head.fst ≠ entry.fst := by
          intro hEq
          apply hHeadFresh
          rw [hEq]
          exact List.mem_map_of_mem (f := Prod.fst) hTailMem
        have hHeadDecide :
            (decide (head.fst = entry.fst)) = false :=
          decide_eq_false hHeadKey
        simp only [List.find?_cons, hHeadDecide]
        exact ih hTailUnique hTailMem

namespace LatentSelectAdmission

/-- Empty subgraph spec used as the unreachable fallback in `fragmentLookup`. -/
private def emptyFallback {node : Type} : Cortex.Wire.SubgraphSpec node :=
  { topology := Cortex.Graph.Graph.empty
    definitions := ∅
    entryNodes := ∅
    exitNodes := ∅ }

/-- Per-arm-key subgraph lookup used by the bridge. The fallback case is
unreachable on admitted keys and is unobservable through the
`FragmentEvidence` obligations, which only quote admitted entries. -/
def fragmentLookup
    {node : Type}
    (entries : List (SelectArmKey × Cortex.Wire.SubgraphSpec node))
    (key : SelectArmKey) :
    Cortex.Wire.SubgraphSpec node :=
  match entries.find? (fun entry => entry.fst = key) with
  | some entry => entry.snd
  | none => emptyFallback

/-- The lookup returns the entry's subgraph for an admitted key in a
duplicate-free entry list. -/
theorem fragmentLookup_entry
    {node : Type}
    {entries : List (SelectArmKey × Cortex.Wire.SubgraphSpec node)}
    (hUnique : (entries.map Prod.fst).Nodup)
    {entry : SelectArmKey × Cortex.Wire.SubgraphSpec node}
    (hEntry : entry ∈ entries) :
    fragmentLookup entries entry.fst = entry.snd := by
  show
    (match entries.find? (fun candidate => candidate.fst = entry.fst) with
      | some entry => entry.snd
      | none => emptyFallback) = entry.snd
  rw [find_key_eq_some_of_mem_nodup hUnique hEntry]

variable {node : Type}
variable [DecidableEq node]

omit [DecidableEq node] in
/-- An admitted arm key resolves to its unique entry and fragment lookup result. -/
private theorem fragmentLookup_of_arms_mem
    {admission : LatentSelectAdmission (Cortex.Wire.SubgraphSpec node)}
    {key : SelectArmKey}
    (hKey : key ∈ (admission.entries.map Prod.fst).toFinset) :
    ∃ entry,
      entry ∈ admission.entries ∧
        entry.fst = key ∧
          fragmentLookup admission.entries key = entry.snd := by
  have hKeyMem : key ∈ admission.entries.map Prod.fst :=
    List.mem_toFinset.mp hKey
  rcases List.mem_map.mp hKeyMem with ⟨entry, hEntry, hEqKey⟩
  have hLookup : fragmentLookup admission.entries entry.fst = entry.snd :=
    fragmentLookup_entry admission.keys_nodup hEntry
  refine ⟨entry, hEntry, hEqKey, ?_⟩
  rw [← hEqKey]
  exact hLookup

/-- Convert an admission carrying `SubgraphSpec` arms into the proof-side
`LatentBranchFamily` consumed by `Cortex.Wire.Select`.

The arm-key set is `admission.entries.map Prod.fst |>.toFinset`, which equals
`admission.shape.armKeys.toFinset` by `keys_eq_shape_keys`. The fragment lookup
falls back to the empty `SubgraphSpec` when the arm key is not admitted; this
fallback is unreachable on admitted keys and is unobservable through the
`FragmentEvidence` obligations, which only quote admitted entries. -/
def toLatentBranchFamily
    {admission : LatentSelectAdmission (Cortex.Wire.SubgraphSpec node)}
    (owner : node)
    (hEvidence : FragmentEvidence admission owner) :
    Cortex.Wire.LatentBranchFamily node SelectArmKey :=
  { owner := owner
    arms := (admission.entries.map Prod.fst).toFinset
    fragment := fragmentLookup admission.entries
    fragmentsValid := by
      intro key hKey
      rcases fragmentLookup_of_arms_mem hKey with ⟨entry, hEntry, _hEqKey, hLookup⟩
      rw [hLookup]
      exact hEvidence.fragmentsValid entry hEntry
    fragmentsPairwiseDisjoint := by
      intro leftKey rightKey hLeft hRight hDifferent nodeId hLeftNode hRightNode
      rcases fragmentLookup_of_arms_mem hLeft with
        ⟨leftEntry, hLeftEntry, hLeftEqKey, hLeftLookup⟩
      rcases fragmentLookup_of_arms_mem hRight with
        ⟨rightEntry, hRightEntry, hRightEqKey, hRightLookup⟩
      have hLeftRaw :
          nodeId ∈ (Cortex.Graph.denote leftEntry.snd.topology).vertices := by
        rw [hLeftLookup] at hLeftNode
        exact hLeftNode
      have hRightRaw :
          nodeId ∈ (Cortex.Graph.denote rightEntry.snd.topology).vertices := by
        rw [hRightLookup] at hRightNode
        exact hRightNode
      have hKeysDifferent : leftEntry.fst ≠ rightEntry.fst := by
        rw [hLeftEqKey, hRightEqKey]
        exact hDifferent
      exact
        hEvidence.fragmentsPairwiseDisjoint
          leftEntry
          rightEntry
          hLeftEntry
          hRightEntry
          hKeysDifferent
          nodeId
          hLeftRaw
          hRightRaw }

/-- Fragment evidence pins the retained owner outside every admitted fragment body. -/
theorem owner_not_in_admitted_fragment
    {admission : LatentSelectAdmission (Cortex.Wire.SubgraphSpec node)}
    {owner : node}
    (hEvidence : FragmentEvidence admission owner)
    {entry : SelectArmKey × Cortex.Wire.SubgraphSpec node}
    (hEntry : entry ∈ admission.entries) :
    owner ∉ (Cortex.Graph.denote entry.snd.topology).vertices :=
  hEvidence.ownerNotInFragments entry hEntry

end LatentSelectAdmission

/-! ## Admission Sanity Examples -/

section AdmissionSanity

/-- A two-key `SelectableOutputShape` with two declared ports. -/
private def twoArmShape
    (leftKey rightKey : SelectArmKey)
    (leftPort rightPort : PortSignature)
    (hLeftKey : leftKey.Valid)
    (hRightKey : rightKey.Valid)
    (hLeftPort : leftPort.Valid)
    (hRightPort : rightPort.Valid)
    (hKeyDistinct : leftKey ≠ rightKey)
    (hLabelDistinct : leftPort.label ≠ rightPort.label) :
    SelectableOutputShape :=
  { armPorts := [(leftKey, leftPort), (rightKey, rightPort)]
    armsAtLeastTwo := by
      simp
    armKeysUnique := by
      simp [hKeyDistinct]
    portLabelsUnique := by
      simp [hLabelDistinct]
    armKeysValid := by
      intro entry hEntry
      simp only [List.mem_cons, List.not_mem_nil, or_false] at hEntry
      rcases hEntry with hEntry | hEntry
      · rw [hEntry]
        exact hLeftKey
      · rw [hEntry]
        exact hRightKey
    armPortsValid := by
      intro entry hEntry
      simp only [List.mem_cons, List.not_mem_nil, or_false] at hEntry
      rcases hEntry with hEntry | hEntry
      · rw [hEntry]
        exact hLeftPort
      · rw [hEntry]
        exact hRightPort }

private def resolutionValidKey : SelectArmKey := ⟨"valid"⟩
private def resolutionIssueKey : SelectArmKey := ⟨"issue"⟩
private def resolutionResearchKey : SelectArmKey := ⟨"ResearchPlan"⟩
private def resolutionUnknownKey : SelectArmKey := ⟨"Unknown"⟩
private def resolutionResearchContract : ContractId := ⟨"ResearchPlan"⟩
private def resolutionIssueContract : ContractId := ⟨"PlanIssue"⟩
private def resolutionSharedContract : ContractId := ⟨"Shared"⟩

private def resolutionValidPort : PortSignature :=
  { label := ⟨"valid"⟩
    contract := resolutionResearchContract }

private def resolutionIssuePort : PortSignature :=
  { label := ⟨"issue"⟩
    contract := resolutionIssueContract }

private def resolutionShape : SelectableOutputShape :=
  twoArmShape
    resolutionValidKey
    resolutionIssueKey
    resolutionValidPort
    resolutionIssuePort
    (by decide)
    (by decide)
    (by decide)
    (by decide)
    (by decide)
    (by decide)

private def ambiguousLeftPort : PortSignature :=
  { label := ⟨"left"⟩
    contract := resolutionSharedContract }

private def ambiguousRightPort : PortSignature :=
  { label := ⟨"right"⟩
    contract := resolutionSharedContract }

private def ambiguousContractShape : SelectableOutputShape :=
  twoArmShape
    ⟨"left"⟩
    ⟨"right"⟩
    ambiguousLeftPort
    ambiguousRightPort
    (by decide)
    (by decide)
    (by decide)
    (by decide)
    (by decide)
    (by decide)

/-- Exact label keys resolve to themselves. -/
example :
    resolveArmKey resolutionShape resolutionValidKey =
      Except.ok resolutionValidKey := by
  rfl

/-- Unique contract-name fallback resolves to the canonical label key. -/
example :
    resolveArmKey resolutionShape resolutionResearchKey =
      Except.ok resolutionValidKey := by
  rfl

/-- Unknown source keys produce the unresolved-key diagnostic. -/
example :
    resolveArmKey resolutionShape resolutionUnknownKey =
      Except.error (SelectAdmissionError.unknownSourceKey resolutionUnknownKey) := by
  rfl

/-- Non-unique contract-name fallback produces the ambiguity diagnostic. -/
example :
    resolveArmKey ambiguousContractShape ⟨"Shared"⟩ =
      Except.error
        (SelectAdmissionError.ambiguousContractFallback
          resolutionSharedContract
          [⟨"left"⟩, ⟨"right"⟩]) := by
  rfl

private def duplicateCanonicalClause : SelectExpr Unit Unit :=
  { base := ()
    arms :=
      [ { key := resolutionValidKey, body := () }
      , { key := resolutionResearchKey, body := () } ] }

/-- Label and contract fallback targeting the same variant is a duplicate after resolution. -/
example :
    admitClause resolutionShape duplicateCanonicalClause =
      Except.error (SelectAdmissionError.duplicateSelectArmKey resolutionValidKey) := by
  rfl

private def missingCoverageClause : SelectExpr Unit Unit :=
  { base := ()
    arms := [{ key := resolutionValidKey, body := () }] }

/-- Missing source coverage reports the uncovered shape arm. -/
example :
    admitClause resolutionShape missingCoverageClause =
      Except.error (SelectAdmissionError.uncoveredShapeArm resolutionIssueKey) := by
  rfl

variable {node : Type}
variable [DecidableEq node]

/-- Two-arm admissions bridge into a `LatentBranchFamily` with the same two arm keys.

This is the smallest executable-shaped sanity check for the bridge machinery:
one-arm output variants are represented by `OutputShape.single`, not by
`SelectableOutputShape`. -/
private theorem two_arm_admission_bridge_arm_set
    (leftKey rightKey : SelectArmKey)
    (leftPort rightPort : PortSignature)
    (hLeftKey : leftKey.Valid)
    (hRightKey : rightKey.Valid)
    (hLeftPort : leftPort.Valid)
    (hRightPort : rightPort.Valid)
    (hKeyDistinct : leftKey ≠ rightKey)
    (hLabelDistinct : leftPort.label ≠ rightPort.label)
    (leftBody rightBody : Cortex.Wire.SubgraphSpec node)
    (owner : node)
    (admission : LatentSelectAdmission (Cortex.Wire.SubgraphSpec node))
    (_hShape :
      admission.shape =
        twoArmShape
          leftKey
          rightKey
          leftPort
          rightPort
          hLeftKey
          hRightKey
          hLeftPort
          hRightPort
          hKeyDistinct
          hLabelDistinct)
    (hEntries : admission.entries = [(leftKey, leftBody), (rightKey, rightBody)])
    (hEvidence : FragmentEvidence admission owner) :
    (LatentSelectAdmission.toLatentBranchFamily owner hEvidence).arms =
      ({leftKey, rightKey} : Finset SelectArmKey) := by
  show ((admission.entries.map Prod.fst).toFinset : Finset SelectArmKey) =
      ({leftKey, rightKey} : Finset SelectArmKey)
  rw [hEntries]
  simp

end AdmissionSanity

end SelectAdmission
end Cortex.Wire
