import Cortex.Wire.SelectAdmission

/-!
## Overview

The additive-choice reading of `select`, stated as theorems rather than
analogy. Wire's ordinary port discipline is the multiplicative/resource
fragment of a linear composition calculus: no implicit copying, no implicit
discarding, matched endpoints consumed exactly once. This module pins the
additive layer: an exclusive output sum plays the role of linear logic's
`⊕` (the producer's internal choice), and a `select` arm table plays the
role of `&` (the consumer's offer of every continuation, exactly one of
which will be used).

Two structural facts carry that reading, both mechanized here over the
existing select-admission surface:

1. **Offer totality and uniqueness** (the `&`-introduction obligation):
   an admitted arm table offers exactly one continuation per alternative —
   no alternative missing, none duplicated.
2. **Shared context** (additive, not multiplicative, resource treatment):
   every arm is admitted against the same selectable shape; alternatives
   share the surrounding resources rather than splitting them, which is the
   defining difference between `&` and `⊗`.

What this module deliberately does **not** claim: a solution to additive
proof nets. The proof-net additive problem is two problems — executing
choice without copying resources, and *proof identity* (commuting
conversions, superposed slices). Wire addresses the first operationally and
refuses the second by design: provenance requires distinguishing histories
that proof-net theory would identify. The falsifiable upgrade — a
translation of `⊕`/`&` *derivations* into Wire with the principal additive
cut step realized by `selectActualize` — is a named open obligation, not a
result of this module.
-/

namespace Cortex.Wire
namespace SelectAdmission

open Cortex.Wire.ElaborationIR

/-- Linear logic's `⊕` as an interface datum: at least two labeled
alternatives, each carrying the port resource it exposes when chosen. -/
structure AdditiveChoice where
  /-- The labeled alternatives, in source order. -/
  alternatives : List (SelectArmKey × PortSignature)
  /-- A choice offers at least two alternatives. -/
  atLeastTwo : 2 ≤ alternatives.length
  /-- Alternative labels are distinct. -/
  keysUnique : (alternatives.map Prod.fst).Nodup
  /-- Exposed port labels are distinct across alternatives. -/
  portLabelsUnique :
    (alternatives.map fun alternative => alternative.2.label).Nodup
  /-- Alternative labels are locally valid names. -/
  keysValid : ∀ alternative, alternative ∈ alternatives → alternative.1.Valid
  /-- Alternative port signatures are locally valid. -/
  portsValid : ∀ alternative, alternative ∈ alternatives → alternative.2.Valid

namespace AdditiveChoice

/-- A `⊕` interface is exactly an exclusive output sum shape. -/
def toShape (choice : AdditiveChoice) : SelectableOutputShape where
  armPorts := choice.alternatives
  armsAtLeastTwo := choice.atLeastTwo
  armKeysUnique := choice.keysUnique
  portLabelsUnique := choice.portLabelsUnique
  armKeysValid := choice.keysValid
  armPortsValid := choice.portsValid

/-- The translation preserves the alternative labels exactly. -/
theorem toShape_armKeys (choice : AdditiveChoice) :
    choice.toShape.armKeys = choice.alternatives.map Prod.fst :=
  rfl

end AdditiveChoice

/-- The `&`-introduction obligation, discharged by select admission: an
admitted arm table offers exactly one continuation per `⊕` alternative, in
the alternatives' order — no alternative missing, none duplicated. -/
theorem withRule_offers_every_alternative
    {base body : Type}
    (choice : AdditiveChoice)
    (clause : SelectExpr base body)
    {admission : LatentSelectAdmission body}
    (hAdmit : admitClause choice.toShape clause = Except.ok admission) :
    admission.entries.map Prod.fst = choice.alternatives.map Prod.fst :=
  admitClause_entries_keys_eq_shape choice.toShape clause hAdmit

/-- Offered continuations are pairwise distinct by alternative label: the
admitted table is one-to-one onto the choice's alternatives. -/
theorem withRule_offers_nodup
    {base body : Type}
    (choice : AdditiveChoice)
    (clause : SelectExpr base body)
    {admission : LatentSelectAdmission body}
    (hAdmit : admitClause choice.toShape clause = Except.ok admission) :
    (admission.entries.map Prod.fst).Nodup := by
  rw [withRule_offers_every_alternative choice clause hAdmit]
  exact choice.keysUnique

end SelectAdmission
end Cortex.Wire
